// A measurement, not a test: a 48 MiB video and a 200 kbit/s audio track
// played together through the thread-ripper proxy over one shared, capped
// link (40 ms per response), with an 8 s player cache. Each mode prints the
// start time, stalls and their total time, MiB handed to the player and sent
// over the link, CDN requests, copies (a piece end asked for again) and, for
// automatic concurrency, the thread counts it went through.
//
// It needs the network core harness, which works without Flutter:
//   ./tool/test_network_core.ps1 -Dart <dart> -Bench [-BenchArgs <args>]
//
// Arguments, in order; '-' keeps a default:
//   seconds         of playback to measure (20)
//   videoRate       video bytes per second (550000)
//   perConnectionB  node b's bytes per second per connection (none)
//   modes           comma separated, each fixed8, fixed16 or auto, with
//                   +deadline to report playback and register bitrates
//                   (fixed8,fixed8+deadline,auto,auto+deadline)
//   linkRate        bytes per second shared by every connection (1250000)
//   perConnectionA  node a's bytes per second per connection (none)
//
// docs/thread-ripper.md records the runs of 2026-11-28, for example
//   -BenchArgs 30,700000,100000          (a slow node)
//   -BenchArgs 60,1150000,-,auto+deadline (a link short of bandwidth)
// PowerShell splits a bare comma list, so quote several modes:
//   -BenchArgs 30,900000,-,'fixed8,auto'
// Single runs are noisy: compare orders of magnitude.
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:PiliPlus/services/thread_ripper/auto_concurrency.dart';
import 'package:PiliPlus/services/thread_ripper/range_proxy.dart';

class Link {
  Link(this.bytesPerSecond);
  final int bytesPerSecond;
  final _clock = Stopwatch()..start();
  int _freeAt = 0;
  int sent = 0;

  void send(
    HttpResponse response,
    List<int> body,
    List<Timer> timers, {
    int? perConnection,
  }) {
    var gone = false;
    unawaited(
      response.done.then((_) => gone = true, onError: (Object _) => gone = true),
    );
    var at = 0;
    var connectionAt = 0;
    void next() {
      if (gone) return;
      if (at >= body.length) {
        unawaited(response.close().catchError((Object _) {}));
        return;
      }
      final slice = body.sublist(at, min(at + 32768, body.length));
      at += slice.length;
      final now = _clock.elapsedMicroseconds;
      _freeAt = max(now, _freeAt) + slice.length * 1000000 ~/ bytesPerSecond;
      var due = _freeAt;
      if (perConnection != null) {
        connectionAt =
            max(now, connectionAt) + slice.length * 1000000 ~/ perConnection;
        due = max(due, connectionAt);
      }
      timers.add(
        Timer(Duration(microseconds: due - now), () {
          if (gone) return;
          try {
            response.add(slice);
            sent += slice.length;
          } catch (_) {
            gone = true;
            return;
          }
          next();
        }),
      );
    }

    timers.add(Timer(const Duration(milliseconds: 40), next));
  }
}

class Play {
  Play(this.byteRate);
  final double byteRate;
  int received = 0;
  double played = 0;
  bool playing = false;
  bool ended = false;
  int underruns = 0;
  double get ahead => (received - played) / byteRate;
}

Future<void> main(List<String> args) async {
  // seconds videoRate perConnectionB [modes] [linkRate] [perConnectionA]
  final seconds = args.isNotEmpty ? int.parse(args[0]) : 20;
  final videoRate = args.length > 1 ? double.parse(args[1]) : 550000.0;
  // Node b also limits every connection to this many bytes per second.
  int? cap(int i) =>
      args.length > i && args[i] != '-' ? int.parse(args[i]) : null;
  final slowNode = cap(2);
  final modes = args.length > 3 && args[3] != '-'
      ? args[3].split(',')
      : ['fixed8', 'fixed8+deadline', 'auto', 'auto+deadline'];
  final linkRate = cap(4) ?? 1250000;
  final nodeA = cap(5);
  final video = Uint8List.fromList(
    List.generate(48 << 20, (i) => (i * 31) % 251),
  );
  final audio = Uint8List.fromList(
    List.generate(1 << 20, (i) => (i * 17) % 251),
  );
  for (final mode in modes) {
    final deadlines = mode.contains('+deadline');
    final timers = <Timer>[];
    final link = Link(linkRate);
    final requests = <(String, int, int)>[];
    final cdn = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    cdn.listen((request) {
      final source = request.uri.path.startsWith('/a') ? audio : video;
      final (start, end) = RipperRangeProxy.parseRange(
        request.headers.value('range'),
        source.length,
      );
      requests.add((request.uri.path, start, end));
      request.response
        ..statusCode = 206
        ..headers.set('Content-Range', 'bytes $start-$end/${source.length}');
      link.send(
        request.response,
        source.sublist(start, end + 1),
        timers,
        perConnection: request.uri.path.endsWith('-b') ? slowNode : nodeA,
      );
    });
    Uri at(String path) => Uri.parse('http://127.0.0.1:${cdn.port}$path');
    final auto = mode.startsWith('auto') ? RipperAutoConcurrency() : null;
    final proxy = RipperRangeProxy(
      concurrency: mode.startsWith('fixed16') ? 16 : 8,
      autoConcurrency: auto,
      userAgent: 'bench',
    );
    await proxy.start();
    final videoUrl = proxy.registerCandidates(
      [at('/v-a'), at('/v-b')],
      bitrate: deadlines ? (videoRate * 8).round() : null,
    );
    final audioUrl = proxy.registerCandidates(
      [at('/a-a'), at('/a-b')],
      isAudio: true,
      bitrate: deadlines ? 200000 : null,
    );
    final client = HttpClient();
    // 4.4 Mbit/s video and 200 kbit/s audio, as in fork issue #5.
    final plays = [Play(videoRate), Play(25000)];
    final subs = <StreamSubscription<List<int>>>[];
    for (final (i, url) in [videoUrl, audioUrl].indexed) {
      final response = await (await client.getUrl(Uri.parse(url))).close();
      subs.add(
        response.listen(
          (chunk) => plays[i].received += chunk.length,
          onDone: () => plays[i].ended = true,
          onError: (Object _) => plays[i].ended = true,
        ),
      );
    }
    final watch = Stopwatch()..start();
    var last = watch.elapsed;
    var playing = false;
    var stalls = 0;
    var stalledMs = 0;
    Duration? startedAt;
    final threads = <int>[];
    final done = Completer<void>();
    Timer.periodic(const Duration(milliseconds: 50), (ticker) {
      final now = watch.elapsed;
      final dt = (now - last).inMicroseconds / 1000000;
      last = now;
      // mpv plays both tracks together: either running dry stalls both.
      if (playing) {
        for (final p in plays) {
          p.played = min(p.received.toDouble(), p.played + p.byteRate * dt);
        }
        if (plays.any((p) => p.played >= p.received && !p.ended)) {
          playing = false;
          stalls++;
          auto?.stall();
        }
      } else if (plays.every((p) => p.ahead >= 1 || p.ended)) {
        playing = true;
        startedAt ??= now;
      } else if (startedAt != null) {
        stalledMs += (dt * 1000).round();
      }
      for (final (i, p) in plays.indexed) {
        if (p.ahead > 8) {
          if (!subs[i].isPaused) subs[i].pause();
        } else if (subs[i].isPaused) {
          subs[i].resume();
        }
      }
      final ahead = plays.map((p) => p.ahead).reduce(min);
      auto?.buffer(ahead, playing);
      if (deadlines) {
        // Started and stalled alike count as playing; the stall is told.
        proxy.updatePlayback(
          aheadSeconds: ahead,
          rate: 1,
          playing: startedAt != null,
          stalled: startedAt != null && !playing,
        );
      }
      if (auto != null &&
          (threads.isEmpty || threads.last != auto.threads)) {
        threads.add(auto.threads);
      }
      if (now.inSeconds >= seconds) {
        ticker.cancel();
        done.complete();
      }
    });
    await done.future;
    final media = requests.where((r) => r.$2 >= 65536).toList();
    final ends = media.map((r) => '${r.$1[1]}:${r.$3}').toList();
    final copies = ends.length - ends.toSet().length;
    final delivered = plays.fold(0, (n, p) => n + p.received);
    print(
      '$mode: start ${startedAt?.inMilliseconds} ms, stalls $stalls '
      '(${stalledMs} ms), '
      'delivered ${(delivered / 1048576).toStringAsFixed(1)} MiB, '
      'link sent ${(link.sent / 1048576).toStringAsFixed(1)} MiB, '
      'requests ${media.length}, copies $copies'
      '${auto == null ? '' : ', threads $threads'}',
    );
    for (final s in subs) {
      await s.cancel();
    }
    proxy.close();
    client.close(force: true);
    for (final t in timers) {
      t.cancel();
    }
    await cdn.close(force: true);
  }
}

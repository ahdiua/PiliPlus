import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:PiliPlus/services/thread_ripper/auto_concurrency.dart';
import 'package:PiliPlus/services/thread_ripper/cdn_resolver.dart';
import 'package:PiliPlus/services/thread_ripper/range_proxy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('CDN synthesis preserves signed path/query and resets peer ports', () {
    final urls = RipperCdnResolver.candidates([
      'https://peer.szbdyd.com:4483/upgcxcode/video.m4s?sign=a%2Bb&x=1',
    ], overseas: true);
    final synthetic = urls.firstWhere(
      (u) => u.host == RipperCdnResolver.overseasHosts.first,
    );
    expect(synthetic.port, 443);
    expect(synthetic.query, 'sign=a%2Bb&x=1');
    expect(synthetic.path, '/upgcxcode/video.m4s');
    expect(
      RipperCdnResolver.candidates([
        'https://example.com/v.m4s',
      ], overseas: true),
      isEmpty,
    );
  });

  test(
    'Akamai-only representations supply synthetic nodes in both regions',
    () {
      for (final overseas in [true, false]) {
        final urls = RipperCdnResolver.candidates([
          'https://video.akamaized.net/v.m4s?sign=original',
        ], overseas: overseas);
        expect(urls.length, greaterThan(1));
        expect(urls.every((u) => u.query == 'sign=original'), isTrue);
      }
    },
  );

  test('relay addresses are never moved to ordinary nodes (upstream #47)', () {
    const mcdn =
        'https://xy1x2x3x4xy.mcdn.bilivideo.cn:4483/upgcxcode/v.m4s?sign=relay';
    const coso1Relay =
        'https://upos-sz-mirrorcoso1.bilivideo.com/upgcxcode/v.m4s?os=mcdn&sign=relay2';
    const resource =
        'https://cache.mountaintoys.cn/v1/resource/v.m4s?sign=relay';
    const good = '/upgcxcode/v.m4s?sign=good';
    List<String> nodes(List<String> hosts) => [
      for (final host in hosts) 'https://$host$good',
    ];
    // Expected lists come from upstream 2026.11.15.1 representationUrls().
    final cases = <(List<String>, bool, List<String>)>[
      (
        [mcdn, 'https://upos-sz-mirrorali.bilivideo.com$good'],
        true,
        [mcdn, ...nodes(RipperCdnResolver.overseasHosts)],
      ),
      (
        [mcdn, 'https://upos-sz-mirrorali.bilivideo.com$good'],
        false,
        nodes(RipperCdnResolver.mainlandHosts),
      ),
      ([mcdn, coso1Relay], true, [mcdn, coso1Relay]),
      ([mcdn, coso1Relay], false, [coso1Relay, mcdn]),
      (
        [resource, 'https://video.akamaized.net$good'],
        true,
        [
          resource,
          'https://video.akamaized.net$good',
          ...nodes(RipperCdnResolver.overseasHosts),
        ],
      ),
      (
        [resource, 'https://video.akamaized.net$good'],
        false,
        nodes(RipperCdnResolver.mainlandHosts),
      ),
    ];
    for (final (input, overseas, expected) in cases) {
      expect(
        RipperCdnResolver.candidates(
          input,
          overseas: overseas,
        ).map((u) => u.toString()).toList(),
        expected,
        reason: '$input overseas=$overseas',
      );
    }
    expect(
      RipperCdnResolver.isRelay(
        Uri.parse('https://upos-sz-mirrorali.bilivideo.com$good'),
      ),
      isFalse,
    );
    expect(
      RipperCdnResolver.mainlandHosts.last,
      'upos-sz-mirrorcoso1.bilivideo.com',
    );
  });

  test('open, bounded, suffix and invalid downstream ranges', () {
    expect(RipperRangeProxy.parseRange(null, 100), (0, 99));
    expect(RipperRangeProxy.parseRange('bytes=20-', 100), (20, 99));
    expect(RipperRangeProxy.parseRange('bytes=20-999', 100), (20, 99));
    expect(RipperRangeProxy.parseRange('bytes=-10', 100), (90, 99));
    for (final value in [
      'bytes=100-',
      'bytes=20-10',
      'bytes=-0',
      'bytes=1-2,4-5',
      'bytes=-',
    ]) {
      expect(
        () => RipperRangeProxy.parseRange(value, 100),
        throwsFormatException,
      );
    }
  });

  test('empty-response bans distinguish nodes, addresses, and pairs', () {
    final bans = RipperBanList();
    final a = Uri.parse('https://a.bilivideo.com/video.m4s?sign=one');
    final b = a.replace(host: 'b.bilivideo.com');
    bans
      ..failure(a, status: 403)
      ..failure(a, status: 403);
    expect(bans.allows(a), isTrue);
    bans.success(b);
    expect(bans.allows(a), isFalse);
    expect(bans.allows(b), isTrue);
    bans.success(a.replace(query: 'sign=two'));
    expect(bans.allows(a), isFalse);
    expect(bans.allows(a.replace(query: 'sign=two')), isTrue);
    final partial = RipperBanList()
      ..failure(a, received: 10)
      ..failure(a, received: 10);
    expect(partial.allows(a), isTrue);
  });

  test(
    'resolver follows original JavaScript reference traces in both regions',
    () {
      final fixtures = jsonDecode(
        File('test/fixtures/ripper_resolver.json').readAsStringSync(),
      ) as List;
      for (final fixture in fixtures) {
        var now = DateTime.fromMillisecondsSinceEpoch(100000);
        final rep = fixture['representation'];
        final originals = <String>[
          rep['baseUrl'],
          ...List<String>.from(rep['backupUrl']),
        ];
        final overseas = fixture['mode'] == 'overseas';
        // Replay upstream traces with their original pool, even when the app
        // adds CDN candidates. The current pool must retain those addresses.
        final urls = (fixture['urls'] as List)
            .cast<String>()
            .map(Uri.parse)
            .toList();
        expect(
          RipperCdnResolver.candidates(
            originals,
            overseas: overseas,
          ).map((u) => u.toString()),
          containsAll(fixture['urls']),
        );
        final resolver = RipperCdnResolver(
          urls,
          originals: originals.map(Uri.parse).toList(),
          overseas: overseas,
          now: () => now,
        );
        for (final step in fixture['steps']) {
          final args = step['args'] as List;
          List<Uri>? result;
          switch (step['op']) {
            case 'startupCandidates':
              result = resolver.startupCandidates();
            case 'rangeCandidates':
              result = resolver.rangeCandidates();
            case 'rescueCandidates':
              result = resolver.rescueCandidates();
            case 'ordered':
              result = resolver.ordered(args[0]);
            case 'success':
              resolver.success(
                Uri.parse(args[0]),
                args[1],
                const Duration(seconds: 1),
              );
            case 'failure':
              resolver.failure(
                Uri.parse(args[0]),
                status: args[1]['status'],
                received: args[2],
              );
            case 'sample':
              resolver.sample(Uri.parse(args[0]), (args[1] as num).toDouble());
            case 'advance':
              now = now.add(Duration(milliseconds: args[0]));
            case 'speed':
              expect(
                resolver.speed(Uri.parse(args[0])),
                closeTo(step['expected'], 0.01),
              );
          }
          if (result != null) {
            expect(
              result.map((u) => u.toString()).toList(),
              step['expected'],
              reason: '${fixture['mode']} ${step['op']}',
            );
          }
        }
      }
    },
  );

  test('weighted assignments match upstream including sparse exploration', () {
    final fixtures = jsonDecode(
      File('test/fixtures/ripper_assignments.json').readAsStringSync(),
    ) as List;
    final assignments = RipperAssignments();
    for (final fixture in fixtures) {
      final urls = (fixture['urls'] as List)
          .cast<String>()
          .map(Uri.parse)
          .toList();
      final resolver = RipperCdnResolver(urls);
      for (var i = 0; i < urls.length; i++) {
        resolver.recordSuccess(
          urls[i],
          (fixture['speeds'][i] as num).toDouble(),
        );
      }
      for (final step in fixture['steps']) {
        expect(
          assignments
              .assign(urls, resolver, step['count'])
              .map((u) => u.toString())
              .toList(),
          step['expected'],
        );
      }
    }
  });

  test('custom nodes restrict both synthesized URLs and originals', () {
    final urls = RipperCdnResolver.candidates(
      [
        'https://video.akamaized.net/v.m4s?sign=a%2Bb',
      ],
      overseas: true,
      customHosts: [
        'https://UPOS-SZ-MIRRORALI.BILIVIDEO.COM:4483/path',
        'example.com',
      ],
    );
    expect(urls, hasLength(1));
    expect(urls.single.host, 'upos-sz-mirrorali.bilivideo.com');
    expect(urls.single.query, 'sign=a%2Bb');
    expect(urls.single.port, 443);
    expect(RipperCdnResolver.normalizeHost('bilivideo.com.evil.com'), isNull);
    expect(RipperCdnResolver.normalizeHost('127.0.0.1'), isNull);
  });

  test('speed survives signature refresh but expires and tiny tails do not renew it', () {
    var now = DateTime.fromMillisecondsSinceEpoch(100000);
    final url = Uri.parse('https://a.bilivideo.com/v.m4s?sign=old');
    final fresh = url.replace(query: 'sign=new');
    final resolver = RipperCdnResolver([url], now: () => now)
      ..success(url, 100000, const Duration(seconds: 1));
    expect(resolver.speed(fresh), 100000);
    now = now.add(const Duration(seconds: 89));
    resolver.success(fresh, 1024, const Duration(seconds: 1));
    expect(resolver.speed(fresh), 100000);
    now = now.add(const Duration(seconds: 2));
    expect(resolver.speed(fresh), 0);
  });

  late HttpServer cdn;
  late HttpClient client;
  late RipperRangeProxy proxy;
  late Uint8List source;
  late List<String> paths;
  late List<(String, int, int)> requests;
  late Set<int> interruptedEnds;
  late int active;
  late int peak;
  late List<Timer> timers;
  late _Link link;

  setUp(() async {
    source = Uint8List.fromList(List.generate(1100000, (i) => (i * 37) % 251));
    paths = [];
    requests = [];
    interruptedEnds = {};
    timers = [];
    active = peak = 0;
    // 10 Mbit/s with a 40 ms round trip, like the capped route of fork
    // issue #5.
    link = _Link(1250000);
    cdn = await HttpServer.bind(InternetAddress.loopbackIPv4, 0)
      ..listen((request) async {
        paths.add(request.uri.path);
        active++;
        peak = max(peak, active);
        final response = request.response;
        unawaited(
          response.done.then((_) => active--, onError: (Object _) => active--),
        );
        try {
          final range = RipperRangeProxy.parseRange(
            request.headers.value('range'),
            source.length,
          );
          final (start, end) = range;
          requests.add((request.uri.path, start, end));
          if (request.uri.path == '/forbidden' ||
              (request.uri.path == '/expiring' && start >= 400000)) {
            response.statusCode = 403;
            await response.close();
            return;
          }
          if (request.uri.path == '/gone') {
            response.statusCode = 410;
            await response.close();
            return;
          }
          if (request.uri.path == '/ignored') {
            response.statusCode = 200;
            await response.close();
            return;
          }
          response.statusCode = 206;
          final reportedTotal = request.uri.path == '/changed' && start > 0
              ? source.length + 100
              : source.length;
          final reportedStart = request.uri.path == '/wrong'
              ? start + 1
              : start;
          response.headers.set(
            'Content-Range',
            'bytes $reportedStart-$end/$reportedTotal',
          );
          var body = source.sublist(start, end + 1);
          if (request.uri.path.startsWith('/link')) {
            link.send(response, body, timers);
            return;
          }
          if (request.uri.path == '/resume-primary' &&
              start >= 65536 &&
              body.length > 65536) {
            response.add(body.sublist(0, 65536));
            await response.flush();
            timers.add(
              Timer(const Duration(seconds: 3), () {
                try {
                  response.add(body.sublist(65536));
                  unawaited(response.close().catchError((Object _) {}));
                } catch (_) {}
              }),
            );
            return;
          }
          if (request.uri.path.startsWith('/pace')) {
            // The link is the limit: every connection receives at the same
            // steady 160 KiB/s, so pieces take longer than the hedge delay.
            var at = 0;
            void next() {
              try {
                if (at >= body.length) {
                  unawaited(response.close().catchError((Object _) {}));
                  return;
                }
                response.add(body.sublist(at, min(at + 16384, body.length)));
                at += 16384;
                timers.add(Timer(const Duration(milliseconds: 100), next));
              } catch (_) {}
            }

            next();
            return;
          }
          if (request.uri.path == '/trickle' && start >= 65536) {
            // Half of every piece now, the rest after a pause, like a piece
            // sharing a slow link with the others in flight.
            final half = body.length ~/ 2;
            response.add(body.sublist(0, half));
            await response.flush();
            timers.add(
              Timer(const Duration(seconds: 3), () {
                try {
                  response.add(body.sublist(half));
                  unawaited(response.close().catchError((Object _) {}));
                } catch (_) {}
              }),
            );
            return;
          }
          if (request.uri.path == '/resume' &&
              start >= 65536 &&
              body.length > 65536 &&
              interruptedEnds.add(end)) {
            response.add(body.sublist(0, 65536));
            await response.flush();
            // Verified headers, then an interrupted body. The next request must
            // start at the last received byte, even on another CDN.
            await response.close();
            return;
          }
          if (request.uri.path == '/short') {
            body = body.sublist(0, body.length ~/ 2);
          }
          if (request.uri.path == '/large') {
            body = Uint8List.fromList([...body, 0]);
          }
          void send() {
            try {
              response.add(body);
              unawaited(response.close().catchError((Object _) {}));
            } catch (_) {}
          }

          if (request.uri.path == '/primary' && start >= 65536) {
            timers.add(Timer(const Duration(seconds: 10), send));
          } else if ((request.uri.path == '/rescue' ||
                  request.uri.path == '/resume-backup') &&
              start < 65536) {
            timers.add(Timer(const Duration(milliseconds: 500), send));
          } else if (request.uri.path == '/jam' && end > start) {
            timers.add(Timer(const Duration(seconds: 10), send));
          } else if (request.uri.path == '/seek' &&
              start > 0 &&
              start < 900000) {
            timers.add(Timer(const Duration(milliseconds: 200), send));
          } else if (request.uri.path == '/slow') {
            timers.add(Timer(const Duration(seconds: 3), send));
          } else {
            // Different delays force out-of-order completion and real overlap.
            timers.add(Timer(Duration(milliseconds: start % 7 + 10), send));
          }
        } catch (_) {
          try {
            await response.close();
          } catch (_) {}
        }
      });
    client = HttpClient();
    proxy = RipperRangeProxy(concurrency: 4, userAgent: 'test');
    await proxy.start();
  });

  tearDown(() async {
    proxy.close();
    client.close(force: true);
    for (final timer in timers) {
      timer.cancel();
    }
    await cdn.close(force: true);
  });

  Uri endpoint(String path) => Uri.parse('http://127.0.0.1:${cdn.port}$path');
  String register(List<String> paths) =>
      proxy.registerCandidates(paths.map(endpoint).toList());
  Future<(HttpClientResponse, List<int>)> fetch(
    String url, {
    String? range,
    String method = 'GET',
  }) async {
    final req = await client.openUrl(method, Uri.parse(url));
    if (range != null) req.headers.set('range', range);
    final res = await req.close();
    final bytes = await res.fold<List<int>>([], (a, b) => a..addAll(b));
    return (res, bytes);
  }

  // Reads [url] the way mpv plays it at [byteRate] bytes per second: playback
  // starts, and resumes after running dry, with [startSeconds] buffered;
  // reading pauses above [maxSeconds], mpv's cache limit, so the proxy sees
  // backpressure. [onTick] sees the state every 50 ms.
  Future<_Playback> playback(
    String url,
    double byteRate, {
    Duration limit = const Duration(seconds: 20),
    double startSeconds = 1,
    double maxSeconds = 8,
    void Function(_Playback)? onTick,
  }) async {
    final state = _Playback(byteRate);
    final watch = Stopwatch()..start();
    final response = await (await client.getUrl(Uri.parse(url))).close();
    final finished = Completer<void>();
    final subscription = response.listen(
      (chunk) {
        state.bytes.add(chunk);
        state.received += chunk.length;
      },
      onDone: () => state.ended = true,
      onError: (Object _) => state.ended = true,
      cancelOnError: true,
    );
    var last = watch.elapsed;
    Timer.periodic(const Duration(milliseconds: 50), (ticker) {
      final now = watch.elapsed;
      final seconds = (now - last).inMicroseconds / 1000000;
      last = now;
      if (state.playing) {
        state.played = min(
          state.received.toDouble(),
          state.played + byteRate * seconds,
        );
        if (state.played >= state.received && !state.ended) {
          state.playing = false;
          state.underruns++;
        }
      } else if (state.aheadSeconds >= startSeconds ||
          (state.ended && state.received > state.played)) {
        state.playing = true;
        state.startedAt ??= now;
      }
      if (state.aheadSeconds > maxSeconds) {
        if (!subscription.isPaused) subscription.pause();
      } else if (subscription.isPaused) {
        subscription.resume();
      }
      onTick?.call(state);
      if ((state.ended && state.played >= state.received) || now >= limit) {
        ticker.cancel();
        unawaited(subscription.cancel());
        finished.complete();
      }
    });
    await finished.future;
    return state;
  }

  test(
    'parallel chunks arrive in exact file order with shared connection limit',
    () async {
      // Two tracks: a newer request on the same track replaces the older one.
      final results = await Future.wait([
        fetch(register(['/good'])),
        fetch(register(['/good']), range: 'bytes=3-800000'),
      ]);
      expect(results[0].$1.statusCode, 200);
      expect(results[0].$2, source);
      expect(results[1].$1.statusCode, 206);
      expect(results[1].$2, source.sublist(3, 800001));
      expect(peak, greaterThan(1));
      expect(peak, lessThanOrEqualTo(4));
    },
  );

  test('a request from the file start needs no separate probe', () async {
    final result = await fetch(register(['/good']));
    expect(result.$2, source);
    expect(requests.first, ('/good', 0, 65535));
    expect(requests.where((r) => r.$2 == 0 && r.$3 == 0), isEmpty);
  });

  test('a file shorter than the probe is served whole', () async {
    source = Uint8List.fromList(List.generate(1000, (i) => i % 251));
    final url = register(['/good']);
    final whole = await fetch(url);
    expect(whole.$1.statusCode, 200);
    expect(whole.$2, source);
    expect(
      (await fetch(url, range: 'bytes=10-99')).$2,
      source.sublist(10, 100),
    );
  });

  test('HEAD, suffix, open-ended seek and 416 responses', () async {
    final url = register(['/good']);
    final head = await fetch(url, method: 'HEAD');
    expect(head.$1.contentLength, source.length);
    expect(head.$2, isEmpty);
    expect(
      (await fetch(url, range: 'bytes=-19')).$2,
      source.sublist(source.length - 19),
    );
    expect(
      (await fetch(url, range: 'bytes=1099900-')).$2,
      source.sublist(1099900),
    );
    expect((await fetch(url, range: 'bytes=2000000-')).$1.statusCode, 416);
  });

  for (final bad in [
    '/forbidden',
    '/ignored',
    '/wrong',
    '/short',
    '/large',
    '/changed',
  ]) {
    test(
      'rejects $bad and retries another CDN without corrupting bytes',
      () async {
        final result = await fetch(register([bad, '/good']));
        expect(result.$1.statusCode, 200);
        expect(result.$2, source);
        expect(paths, contains(bad));
        expect(paths, contains('/good'));
      },
    );
  }

  test('slow first response is hedged before its first-byte timeout', () async {
    final watch = Stopwatch()..start();
    final result = await fetch(
      register(['/slow', '/good']),
      range: 'bytes=0-100',
    );
    expect(result.$2, source.sublist(0, 101));
    expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
  });

  test(
    'all invalid upstream responses produce 502, never fake media bytes',
    () async {
      final result = await fetch(register(['/wrong']));
      expect(result.$1.statusCode, 502);
      expect(result.$2, isEmpty);
    },
  );

  test('session close cancels active and queued ranges promptly', () async {
    final url = register(['/slow']);
    final pending = fetch(url)
        .then<Object>((value) => value, onError: (Object e) => e);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    proxy.close();
    await pending.timeout(const Duration(seconds: 1));
    final count = paths.length;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(paths.length, count);
  });

  test(
    'unknown paths cannot turn the listener into an arbitrary URL proxy',
    () async {
      final url = Uri.parse(register(['/good']));
      final result = await fetch(
        url.replace(path: '/https://example.com').toString(),
      );
      expect(result.$1.statusCode, 404);
      expect(paths, isEmpty);
    },
  );
  test(
    'a seek disconnect stops old work and new ranges remain usable',
    () async {
      // Several windows long: work that outlived the disconnect would go on
      // to request ranges past the first window.
      source = Uint8List.fromList(
        List.generate(6 * 1024 * 1024, (i) => (i * 37) % 251),
      );
      final url = Uri.parse(register(['/seek']));
      final socket = await Socket.connect(url.host, url.port);
      socket.write('GET ${url.path} HTTP/1.1\r\nHost: ${url.host}\r\n\r\n');
      await socket.flush();
      await socket.first;
      socket.destroy();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final oldCount = paths.length;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(paths.length, oldCount);
      expect(requests.every((r) => r.$2 < 2 * 1024 * 1024), isTrue);
      final next = await fetch(url.toString(), range: 'bytes=900000-900999');
      expect(next.$2, source.sublist(900000, 901000));
    },
  );
  test('a newer request for a track replaces the older one', () async {
    final url = Uri.parse(register(['/seek']));
    final older = await Socket.connect(url.host, url.port);
    older.write('GET ${url.path} HTTP/1.1\r\nHost: ${url.host}\r\n\r\n');
    await older.flush();
    var received = 0;
    final started = Completer<void>();
    final ended = Completer<void>();
    older.listen(
      (data) {
        received += data.length;
        if (!started.isCompleted) started.complete();
      },
      onError: (Object _) {
        if (!ended.isCompleted) ended.complete();
      },
      onDone: () {
        if (!ended.isCompleted) ended.complete();
      },
    );
    await started.future;
    // Like mpv's seek: the new range is requested while the old connection
    // is still open.
    final next = await fetch(url.toString(), range: 'bytes=900000-900999');
    expect(next.$2, source.sublist(900000, 901000));
    await ended.future.timeout(const Duration(seconds: 1));
    expect(received, lessThan(source.length));
    older.destroy();
  });
  test('a track asked again for bytes starts a new session', () async {
    proxy.close();
    final auto = _CountingAuto();
    proxy = RipperRangeProxy(autoConcurrency: auto, userAgent: 'test');
    await proxy.start();
    expect((auto.sessions, auto.threads), (1, 16));
    final video = register(['/good']);
    final audio = register(['/good']);
    await fetch(video, range: 'bytes=0-1023');
    await fetch(audio, range: 'bytes=0-1023');
    await fetch(audio, method: 'HEAD');
    expect(auto.sessions, 1);
    final seek = await fetch(video, range: 'bytes=500000-500999');
    expect(seek.$2, source.sublist(500000, 501000));
    expect(auto.sessions, 2);
  });
  test(
    'eight-thread saturation still leaves a connection for rescue',
    () async {
      source = Uint8List(3 * 1024 * 1024);
      proxy.close();
      var inFlightPeak = 0;
      proxy = RipperRangeProxy(
        concurrency: 8,
        userAgent: 'test',
        onActiveRequestsChanged: (count) =>
            inFlightPeak = max(inFlightPeak, count),
      );
      await proxy.start();
      // Separate tracks each start with an unresponsive primary. Together they
      // fill all ordinary slots; no ordinary connection will finish in 3 s.
      final results = await Future.wait(
        List.generate(
          8,
          (_) =>
              fetch(register(['/primary', '/rescue']), range: 'bytes=0-262143'),
        ),
      ).timeout(const Duration(seconds: 3));
      for (final result in results) {
        expect(result.$1.statusCode, 206);
        expect(result.$2, source.sublist(0, 262144));
      }
      expect(inFlightPeak, lessThanOrEqualTo(8));
      expect(paths, contains('/rescue'));
    },
  );
  test('2 MiB media does not become dozens of tiny round trips', () async {
    source = Uint8List(2 * 1024 * 1024);
    proxy.close();
    proxy = RipperRangeProxy(concurrency: 8, userAgent: 'test');
    await proxy.start();
    final result = await fetch(register(['/good']));
    expect(result.$2, source);
    expect(paths.length, lessThanOrEqualTo(10));
  });

  test('audio is not fetched as 64 KiB round trips', () async {
    source = Uint8List(2 * 1024 * 1024);
    final result = await fetch(
      proxy.registerCandidates([endpoint('/good')], isAudio: true),
    );
    expect(result.$2, source);
    expect(paths.length, lessThanOrEqualTo(10));
  });

  test('a piece reaches the player while it is still arriving', () async {
    final response = await (await client.getUrl(
      Uri.parse(register(['/trickle'])),
    )).close();
    final watch = Stopwatch()..start();
    final bytes = <int>[];
    final early = Completer<Duration>();
    await response.forEach((chunk) {
      bytes.addAll(chunk);
      // The head plus part of the first piece, which completes after 3 s.
      if (bytes.length > 65536 + 100000 && !early.isCompleted) {
        early.complete(watch.elapsed);
      }
    });
    expect(await early.future, lessThan(const Duration(seconds: 2)));
    expect(bytes, source);
  });

  test('pieces arriving at the usual speed get no second copy', () async {
    source = Uint8List.fromList(List.generate(3 << 20, (i) => i % 251));
    proxy.close();
    proxy = RipperRangeProxy(concurrency: 8, userAgent: 'test');
    await proxy.start();
    final result = await fetch(register(['/pace', '/pace-b']));
    expect(result.$2, source);
    // A copy asks for the same piece end as its first copy.
    final ends = requests.where((r) => r.$2 >= 65536).map((r) => r.$3);
    expect(ends.length - ends.toSet().length, lessThanOrEqualTo(3));
  });

  group('playback deadlines', () {
    // A player reporting the same buffer every 100 ms, as the position
    // listener does.
    Timer report(double ahead) =>
        Timer.periodic(const Duration(milliseconds: 100), (_) {
          proxy.updatePlayback(aheadSeconds: ahead, rate: 1, playing: true);
        });
    int copies() {
      final ends = requests.where((r) => r.$2 >= 65536).map((r) => r.$3);
      return ends.length - ends.toSet().length;
    }

    setUp(() async {
      source = Uint8List.fromList(List.generate(3 << 20, (i) => i % 251));
      proxy.close();
      proxy = RipperRangeProxy(concurrency: 8, userAgent: 'test');
      await proxy.start();
    });

    test('pieces on pace for a distant deadline get no copy', () async {
      final url = proxy.registerCandidates(
        [endpoint('/pace'), endpoint('/pace-b')],
        bitrate: 800000,
      );
      final timer = report(30);
      try {
        expect((await fetch(url)).$2, source);
      } finally {
        timer.cancel();
      }
      expect(copies(), 0);
    });

    test('pieces that will miss their deadline get bounded copies', () async {
      // Stalled: every piece is due now, and both nodes run at the usual
      // speed, so only the rescue budget can buy a copy.
      final url = proxy.registerCandidates(
        [endpoint('/pace'), endpoint('/pace-b')],
        bitrate: 8000000,
      );
      final timer = report(0);
      try {
        expect((await fetch(url)).$2, source);
      } finally {
        timer.cancel();
      }
      // Two windows of about 2 MiB, each with one early and one late copy
      // at eight threads.
      expect(copies(), inInclusiveRange(1, 4));
    });

    test('a track without a bitrate keeps the deadline-free rules', () async {
      final timer = report(0);
      try {
        expect((await fetch(register(['/pace', '/pace-b']))).$2, source);
      } finally {
        timer.cancel();
      }
      expect(copies(), lessThanOrEqualTo(3));
    });
  });

  test('a stall keeps pieces due without further reports', () async {
    source = Uint8List.fromList(List.generate(3 << 20, (i) => i % 251));
    proxy.close();
    proxy = RipperRangeProxy(concurrency: 8, userAgent: 'test');
    await proxy.start();
    final url = proxy.registerCandidates(
      [endpoint('/pace'), endpoint('/pace-b')],
      bitrate: 8000000,
    );
    // The position stands still during a stall, so the player reports it
    // once; the pieces stay due without further reports.
    proxy.updatePlayback(
      aheadSeconds: 0,
      rate: 1,
      playing: true,
      stalled: true,
    );
    expect((await fetch(url)).$2, source);
    final ends = requests.where((r) => r.$2 >= 65536).map((r) => r.$3);
    expect(ends.length - ends.toSet().length, inInclusiveRange(1, 4));
  });

  test('queue rank: deadline boosts and aging, none without a deadline', () {
    double rank(int priority, {double? deadline, int waited = 0}) =>
        RipperRangeProxy.queueRank(
          priority,
          deadline: deadline,
          now: 10000,
          queuedAt: 10000 - waited,
        );
    expect(rank(55), 55);
    expect(rank(55, waited: 9000), 55);
    expect(rank(55, deadline: 20000), 55);
    expect(rank(55, deadline: 11500), 61);
    expect(rank(55, deadline: 10500), 64);
    expect(rank(55, deadline: 9000), 67);
    // 20 for every 0.9 s: a piece queued 0.9 s ago catches up with a newer
    // one 20 above it.
    expect(rank(35, deadline: 20000, waited: 900), rank(55, deadline: 20000));
  });

  test(
    'interrupted verified pieces resume without dropping or repeating bytes',
    () async {
      proxy.close();
      proxy = RipperRangeProxy(concurrency: 8, userAgent: 'test');
      await proxy.start();
      final result = await fetch(register(['/resume']));
      expect(result.$2, source);
      final pieces = requests.where((r) => r.$2 >= 65536).toList();
      expect(
        pieces.any(
          (a) => pieces.any((b) => a.$3 == b.$3 && b.$2 == a.$2 + 65536),
        ),
        isTrue,
      );
    },
  );

  group('refused URLs', () {
    late int refused;
    setUp(() async {
      proxy.close();
      refused = 0;
      proxy = RipperRangeProxy(
        concurrency: 4,
        userAgent: 'test',
        onRefused: () => refused++,
      );
      await proxy.start();
    });

    test('a track every node refuses is reported', () async {
      final result = await fetch(register(['/forbidden', '/gone']));
      expect(result.$1.statusCode, 502);
      expect(refused, 1);
    });

    test('other failures and a single refusing node are not', () async {
      expect((await fetch(register(['/wrong']))).$1.statusCode, 502);
      expect((await fetch(register(['/forbidden', '/good']))).$2, source);
      expect(refused, 0);
    });

    test('refusals are reported before the request gives up', () async {
      // mpv cancels a request by reconnecting after 5 s without data, while
      // trying every node in turn can take longer.
      unawaited(
        fetch(
          register(['/forbidden', '/gone', '/jam']),
        ).then((_) {}, onError: (Object _) {}),
      );
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(refused, 1);
    });

    test('refusals after the headers are reported too', () async {
      // The deadline passes while the track streams: the head is served, the
      // pieces after it are refused, and the response is cut short.
      await expectLater(
        fetch(register(['/expiring'])),
        throwsA(isA<HttpException>()),
      );
      expect(refused, 1);
    });
  });

  group('a shared, capped link', () {
    setUp(() async {
      source = Uint8List.fromList(
        List.generate(3 << 20, (i) => (i * 31) % 251),
      );
      proxy.close();
      proxy = RipperRangeProxy(concurrency: 8, userAgent: 'test');
      await proxy.start();
    });

    test('caps every connection together', () async {
      final watch = Stopwatch()..start();
      final result = await fetch(register(['/link-a', '/link-b']));
      expect(result.$2, source);
      // 3 MiB at 1.25 MB/s takes 2.5 s however many connections share it.
      expect(watch.elapsed, greaterThan(const Duration(milliseconds: 2400)));
      expect(peak, greaterThan(1));
    });

    test('plays a bitrate well below the link through', () async {
      // 4.8 Mbit/s on a 10 Mbit/s link.
      final played = await playback(
        register(['/link-a', '/link-b']),
        600000,
      );
      expect(played.bytes.takeBytes(), source);
      expect(played.underruns, 0);
    });
  });

  test('hedge resumes the live primary prefix on a different node', () async {
    final watch = Stopwatch()..start();
    final result = await fetch(register(['/resume-primary', '/resume-backup']));
    expect(result.$2, source);
    expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    final originals = requests.where(
      (r) => r.$1 == '/resume-primary' && r.$2 >= 65536,
    );
    expect(
      originals.any(
        (a) => requests.any(
          (b) =>
              b.$1 == '/resume-backup' && b.$3 == a.$3 && b.$2 == a.$2 + 65536,
        ),
      ),
      isTrue,
    );
  });
}

class _CountingAuto extends RipperAutoConcurrency {
  int sessions = 0;

  @override
  void newSession() {
    sessions++;
    super.newSession();
  }
}

/// One downlink that every `/link` response shares: [bytesPerSecond] in
/// total, handed out in 32 KiB slices in turn, after a 40 ms round trip per
/// response. The link itself is the limit, as on a capped mobile or overseas
/// route, so every piece in flight takes bandwidth from the others.
class _Link {
  _Link(this.bytesPerSecond);
  final int bytesPerSecond;
  static const latency = Duration(milliseconds: 40);
  final _clock = Stopwatch()..start();
  int _freeAt = 0;

  void send(HttpResponse response, List<int> body, List<Timer> timers) {
    var gone = false;
    unawaited(
      response.done.then((_) => gone = true, onError: (Object _) => gone = true),
    );
    var at = 0;
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
      timers.add(
        Timer(Duration(microseconds: _freeAt - now), () {
          if (gone) return;
          try {
            response.add(slice);
          } catch (_) {
            gone = true;
            return;
          }
          next();
        }),
      );
    }

    timers.add(Timer(latency, next));
  }
}

/// What a player reading a track at a steady bitrate saw.
class _Playback {
  _Playback(this.byteRate);
  final double byteRate;
  final bytes = BytesBuilder(copy: false);
  int received = 0;
  double played = 0;
  bool playing = false;
  bool ended = false;
  int underruns = 0;
  Duration? startedAt;

  double get aheadSeconds => (received - played) / byteRate;
}

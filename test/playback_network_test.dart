import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:PiliPlus/services/thread_ripper/direct_cdn_selector.dart';
import 'package:PiliPlus/services/thread_ripper/playback_buffer.dart';
import 'package:PiliPlus/services/thread_ripper/playback_network_session.dart';
import 'package:PiliPlus/services/thread_ripper/range_proxy.dart';
import 'package:flutter_test/flutter_test.dart';

class _FixtureProxy extends RipperRangeProxy {
  _FixtureProxy() : super(concurrency: 4, userAgent: 'test');

  @override
  String register(Iterable<String> urls, {bool isAudio = false}) {
    return registerCandidates(urls.map(Uri.parse).toList(), isAudio: isAudio);
  }
}

class _UnavailableProxy extends RipperRangeProxy {
  _UnavailableProxy() : super(userAgent: 'test');
  @override
  Future<void> start() async => throw const SocketException('Unavailable');
}

class _DelayedProxy extends RipperRangeProxy {
  _DelayedProxy() : super(userAgent: 'test');
  final ready = Completer<void>();
  final started = Completer<void>();

  @override
  Future<void> start() async {
    started.complete();
    await ready.future;
    await super.start();
  }
}

class _RememberedSelector extends DirectCdnSelector {
  _RememberedSelector(this.selected) : super(userAgent: 'test');
  final String selected;
  int calls = 0;

  @override
  Future<String> select(Iterable<String> candidates, String fallback) async {
    calls++;
    return selected;
  }
}

void main() {
  final media = Uint8List.fromList(
    List.generate(3 * 1024 * 1024, (i) => i % 251),
  );
  final servers = <HttpServer>[];
  final requests = <int, int>{};
  final pendingHandlers = <Future<void>>{};
  var active = 0;
  var maxActive = 0;

  Future<String> cdn({int delayMs = 0, bool valid = true}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final id = servers.length;
    servers.add(server);
    Future<void> serve(HttpRequest request) async {
      requests[id] = (requests[id] ?? 0) + 1;
      active++;
      maxActive = max(active, maxActive);
      try {
        await Future<void>.delayed(Duration(milliseconds: delayMs));
        final range = RipperRangeProxy.parseRange(
          request.headers.value(HttpHeaders.rangeHeader),
          media.length,
        );
        final (start, end) = range;
        request.response.statusCode = valid ? 206 : 200;
        request.response.headers
          ..set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-$end/${media.length}',
          )
          ..contentLength = end - start + 1;
        request.response.add(Uint8List.sublistView(media, start, end + 1));
        await request.response.close().timeout(const Duration(milliseconds: 500));
      } catch (_) {
        // A cancelled probe/download is expected to disconnect.
      } finally {
        active--;
      }
    }
    server.listen((request) {
      final pending = serve(request);
      pendingHandlers.add(pending);
      pending.whenComplete(() => pendingHandlers.remove(pending)).ignore();
    });
    return 'http://127.0.0.1:${server.port}/video.m4s';
  }

  tearDown(() async {
    for (final server in servers) {
      await server.close(force: true);
    }
    await Future.wait(pendingHandlers.toList());
    servers.clear();
    requests.clear();
    active = maxActive = 0;
  });

  Future<Uint8List> read(String url) async {
    final client = HttpClient();
    try {
      final response = await (await client.getUrl(Uri.parse(url))).close();
      expect(response.statusCode, anyOf(200, 206));
      final bytes = BytesBuilder(copy: false);
      await for (final part in response) {
        bytes.add(part);
      }
      return bytes.takeBytes();
    } finally {
      client.close(force: true);
    }
  }

  test(
    'BTR uses multiple CDNs then restores the exact manual video/audio URLs',
    () async {
      final first = await cdn(delayMs: 200);
      final second = await cdn(delayMs: 5);
      final source = PlaybackNetworkSources(
        video: '$first?sign=manual',
        audio: '$first?sign=manual-audio',
        videoCandidates: [first, second],
        audioCandidates: [first, second],
      );
      final session = PlaybackNetworkSession(
        userAgent: 'test',
        proxyFactory: (_, _) => _FixtureProxy(),
      );
      addTearDown(session.dispose);
      final enabled = (await session.resolve(
        source,
        const PlaybackNetworkOptions(btrEnabled: true),
      ))!;
      expect(session.usingBtr, isTrue);
      expect(enabled.video, startsWith('http://127.0.0.1:'));
      expect(enabled.video, isNot(source.video));
      final results = await Future.wait([
        read(enabled.video),
        read(enabled.audio!),
      ]);
      for (final bytes in results) {
        expect(bytes, orderedEquals(media));
      }
      expect(requests[0], greaterThan(0));
      expect(requests[1], greaterThan(0));

      final restored = (await session.resolve(
        source,
        const PlaybackNetworkOptions(),
      ))!;
      expect(session.usingBtr, isFalse);
      expect(restored.video, source.video);
      expect(restored.audio, source.audio);
      expect(source.videoCandidates, [first, second]);
      // The old proxy really stopped listening when switched off.
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 1);
      addTearDown(() => client.close(force: true));
      await expectLater(
        client.getUrl(Uri.parse(enabled.video)).then((r) => r.close()),
        throwsA(isA<SocketException>()),
      );
    },
  );

  test('proxy startup failure falls back to remembered manual URLs', () async {
    final session = PlaybackNetworkSession(
      userAgent: 'test',
      proxyFactory: (_, _) => _UnavailableProxy(),
    );
    addTearDown(session.dispose);
    const source = PlaybackNetworkSources(
      video: 'https://saved.bilivideo.com/video.m4s?sign=keep',
      audio: 'https://saved.bilivideo.com/audio.m4s?sign=keep',
      videoCandidates: ['https://saved.bilivideo.com/video.m4s?sign=keep'],
    );
    final result = await session.resolve(
      source,
      const PlaybackNetworkOptions(btrEnabled: true),
    );
    expect(identical(result, source), isTrue);
    expect(session.usingBtr, isFalse);
  });

  test('non-DASH and excluded sources never start a proxy or probes', () async {
    final session = PlaybackNetworkSession(
      userAgent: 'test',
      proxyFactory: (_, _) => throw StateError('Must not start'),
    );
    addTearDown(session.dispose);
    const source = PlaybackNetworkSources(
      video: 'https://example.com/live.m3u8',
    );
    expect(
      await session.resolve(
        source,
        const PlaybackNetworkOptions(btrEnabled: true, autoSelectCdn: true),
      ),
      same(source),
    );
  });

  test(
    'disabling BTR while it starts cannot bring the old proxy back',
    () async {
      final proxy = _DelayedProxy();
      final session = PlaybackNetworkSession(
        userAgent: 'test',
        proxyFactory: (_, _) => proxy,
      );
      addTearDown(session.dispose);
      const source = PlaybackNetworkSources(
        video: 'https://saved.bilivideo.com/video.m4s',
        videoCandidates: ['https://saved.bilivideo.com/video.m4s'],
      );
      final pending = session.resolve(
        source,
        const PlaybackNetworkOptions(btrEnabled: true),
      );
      await proxy.started.future;
      expect(
        await session.resolve(source, const PlaybackNetworkOptions()),
        same(source),
      );
      proxy.ready.complete();
      expect(await pending, isNull);
      expect(session.usingBtr, isFalse);
    },
  );

  test('BTR leaves independent automatic/manual direct modes intact', () async {
    const selected =
        'https://upos-sz-mirrorcosov.bilivideo.com/video.m4s?sign=current';
    final selector = _RememberedSelector(selected);
    final session = PlaybackNetworkSession(
      userAgent: 'test',
      selector: selector,
      proxyFactory: (_, _) => _FixtureProxy(),
    );
    addTearDown(session.dispose);
    const source = PlaybackNetworkSources(
      video: 'https://upos-sz-mirrorali.bilivideo.com/video.m4s?sign=saved',
      videoCandidates: [
        'https://upos-sz-mirrorali.bilivideo.com/video.m4s?sign=saved',
      ],
    );
    await session.resolve(
      source,
      const PlaybackNetworkOptions(btrEnabled: true, autoSelectCdn: true),
    );
    expect(selector.calls, 0);
    final automatic = (await session.resolve(
      source,
      const PlaybackNetworkOptions(autoSelectCdn: true),
    ))!;
    expect(automatic.video, selected);
    final manual = (await session.resolve(
      source,
      const PlaybackNetworkOptions(),
    ))!;
    expect(manual.video, source.video);
    expect(selector.calls, 1);
    expect(session.usingBtr, isFalse);
  });

  test(
    'bounded probes choose a valid faster node and reuse a fresh signature',
    () async {
      final slow = await cdn(delayMs: 120);
      final fast = await cdn(delayMs: 5);
      var now = DateTime(2026, 10, 10);
      final selector = DirectCdnSelector(
        userAgent: 'test',
        sampleBytes: 16 * 1024,
        now: () => now,
      );
      addTearDown(selector.clear);
      expect(await selector.select([slow, fast], slow), fast);
      expect(maxActive, lessThanOrEqualTo(2));
      final count = requests.values.fold(0, (a, b) => a + b);
      final freshFast = '$fast?sign=fresh';
      expect(
        await selector.select(['$slow?sign=fresh', freshFast], slow),
        freshFast,
      );
      expect(requests.values.fold(0, (a, b) => a + b), count);
      now = now.add(const Duration(minutes: 3));
      await selector.select([slow, fast], slow);
      expect(requests.values.fold(0, (a, b) => a + b), greaterThan(count));
      selector.clear();
      await selector.select([slow, fast], slow);
      expect(requests.values.fold(0, (a, b) => a + b), greaterThan(count));
    },
  );

  test('invalid ranges cannot replace the manual CDN', () async {
    final invalid = await cdn(valid: false);
    final selector = DirectCdnSelector(userAgent: 'test');
    addTearDown(selector.clear);
    expect(
      await selector.select([invalid], 'saved-manual-url'),
      'saved-manual-url',
    );
  });

  test(
    'probe deadline preserves manual URL and caps candidate count',
    () async {
      final urls = <String>[];
      for (var i = 0; i < 6; i++) {
        urls.add(await cdn(delayMs: 250));
      }
      final selector = DirectCdnSelector(
        userAgent: 'test',
        timeout: const Duration(milliseconds: 80),
      );
      addTearDown(selector.clear);
      final clock = Stopwatch()..start();
      expect(await selector.select(urls, 'manual'), 'manual');
      expect(clock.elapsedMilliseconds, lessThan(500));
      expect(requests.length, lessThanOrEqualTo(4));
      expect(maxActive, lessThanOrEqualTo(2));
    },
  );

  test('a new source cancels an unfinished selection', () async {
    final url = await cdn(delayMs: 200);
    final selector = DirectCdnSelector(userAgent: 'test');
    addTearDown(selector.clear);
    final pending = selector.select([url], 'old-manual');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    selector.cancel();
    expect(await pending, 'old-manual');
  });

  test('buffer grows for bitrate and speed, remains bounded and preserves manual settings', () {
    Map<String, String> buffer({
      int? bandwidth,
      double speed = 1,
      bool adaptive = true,
      double size = 4,
    }) => playbackBuffer(
      sizeMiB: size,
      seconds: 16,
      bandwidth: bandwidth,
      speed: speed,
      adaptive: adaptive,
    );
    final high = buffer(bandwidth: 20 * 1000 * 1000);
    expect(int.parse(high['demuxer-max-bytes']!), greaterThan(4 * 1024 * 1024));
    expect(high['demuxer-max-back-bytes'], '${4 * 1024 * 1024}');
    final fast = buffer(bandwidth: 20 * 1000 * 1000, speed: 2);
    expect(fast['cache-secs'], '32.000');
    expect(fast['demuxer-max-bytes'], '${64 * 1024 * 1024}');
    expect(
      buffer(bandwidth: 1000000000)['demuxer-max-bytes'],
      '${64 * 1024 * 1024}',
    );
    expect(
      buffer(bandwidth: 1000000000, adaptive: false)['demuxer-max-bytes'],
      '${4 * 1024 * 1024}',
    );
    expect(buffer(size: 128)['demuxer-max-bytes'], '${128 * 1024 * 1024}');
  });
}

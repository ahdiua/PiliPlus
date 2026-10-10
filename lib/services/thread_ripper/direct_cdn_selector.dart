import 'dart:async';
import 'dart:io';

/// Small, bounded probes select one URL; playback itself remains a direct read.
class DirectCdnSelector {
  DirectCdnSelector({
    required this.userAgent,
    this.sampleBytes = 128 * 1024,
    this.timeout = const Duration(milliseconds: 1200),
    this.cacheTtl = const Duration(minutes: 2),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final String userAgent;
  final int sampleBytes;
  final Duration timeout;
  final Duration cacheTtl;
  final DateTime Function() _now;
  final _cache = <String, ({String authority, DateTime at})>{};
  HttpClient? _client;
  int _generation = 0;

  void cancel() {
    _generation++;
    _client?.close(force: true);
    _client = null;
  }

  void clear() {
    cancel();
    _cache.clear();
  }

  Future<String> select(Iterable<String> candidates, String fallback) async {
    cancel();
    final generation = _generation;
    final distinctHosts = <String>{};
    final urls = candidates
        .map(Uri.parse)
        .where((u) => distinctHosts.add(u.authority))
        .take(4)
        .toList();
    if (urls.isEmpty) return fallback;
    _cache.removeWhere((_, v) => _now().difference(v.at) >= cacheTtl);
    final key = urls.map((u) => '${u.authority}${u.path}').join('|');
    final cached = _cache[key];
    if (cached != null) {
      // Use the current signature, never a cached signed URL.
      return urls.firstWhere((u) => u.authority == cached.authority).toString();
    }

    final client = HttpClient()
      ..autoUncompress = false
      ..connectionTimeout = timeout;
    _client = client;
    final successful = <({Uri url, double speed})>[];
    var next = 0;
    var finished = false;
    Future<void> worker() async {
      while (!finished && next < urls.length && generation == _generation) {
        final url = urls[next++];
        try {
          final speed = await _probe(client, url).timeout(timeout);
          if (!finished && generation == _generation)
            successful.add((url: url, speed: speed));
        } catch (_) {
          // A failed or invalid candidate must not replace the manual URL.
        }
      }
    }

    try {
      await Future.wait([worker(), worker()]).timeout(timeout);
    } catch (_) {
      // The entire selection has a deadline, including queued probes.
    } finally {
      finished = true;
      client.close(force: true);
      if (identical(_client, client)) _client = null;
    }
    if (generation != _generation || successful.isEmpty) return fallback;
    successful.sort((a, b) => b.speed.compareTo(a.speed));
    final winner = successful.first.url;
    if (_cache.length >= 64) _cache.remove(_cache.keys.first);
    _cache[key] = (authority: winner.authority, at: _now());
    return winner.toString();
  }

  Future<double> _probe(HttpClient client, Uri url) async {
    final clock = Stopwatch()..start();
    final request = await client.getUrl(url);
    request.followRedirects = false;
    request.headers
      ..set(HttpHeaders.rangeHeader, 'bytes=0-${sampleBytes - 1}')
      ..set(HttpHeaders.acceptEncodingHeader, 'identity')
      ..set(HttpHeaders.userAgentHeader, userAgent)
      ..set(HttpHeaders.refererHeader, 'https://www.bilibili.com/');
    try {
      final response = await request.close();
      final match = RegExp(r'^bytes 0-(\d+)/(\d+)$').firstMatch(
        response.headers.value(HttpHeaders.contentRangeHeader) ?? '',
      );
      if (response.statusCode != 206 || match == null) {
        throw const HttpException('Invalid probe range');
      }
      final total = int.parse(match[2]!);
      final expected = total < sampleBytes ? total : sampleBytes;
      if (expected <= 0 || int.parse(match[1]!) != expected - 1) {
        throw const HttpException('Invalid probe length');
      }
      var received = 0;
      await for (final bytes in response) {
        received += bytes.length;
        if (received > expected) throw const HttpException('Oversized probe');
      }
      if (received != expected) throw const HttpException('Truncated probe');
      return received * 1000000 / clock.elapsedMicroseconds.clamp(1, 1 << 62);
    } catch (_) {
      request.abort();
      rethrow;
    }
  }
}

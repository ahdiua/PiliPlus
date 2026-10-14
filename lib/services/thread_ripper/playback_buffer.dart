import 'dart:math';

Map<String, String> playbackBuffer({
  required double sizeMiB,
  required double seconds,
  double speed = 1,
  int? bandwidth,
  bool adaptive = true,
}) {
  final targetSeconds = seconds * speed;
  final manualBytes = (sizeMiB * 1024 * 1024).round();
  final recommended = bandwidth != null && bandwidth > 0
      ? (bandwidth / 8 * targetSeconds * 1.2).ceil()
      : 16 * 1024 * 1024;
  final forwardBytes = adaptive
      ? max(manualBytes, min(64 * 1024 * 1024, recommended))
      : manualBytes;
  return {
    'cache': 'yes',
    'cache-secs': targetSeconds.toStringAsFixed(3),
    'demuxer-hysteresis-secs': (targetSeconds / 1.5).toStringAsFixed(3),
    'demuxer-max-bytes': '$forwardBytes',
    'demuxer-max-back-bytes': '$manualBytes',
  };
}

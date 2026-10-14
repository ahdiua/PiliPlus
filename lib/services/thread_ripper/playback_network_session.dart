import 'package:PiliPlus/services/thread_ripper/auto_concurrency.dart';
import 'package:PiliPlus/services/thread_ripper/cdn_resolver.dart';
import 'package:PiliPlus/services/thread_ripper/direct_cdn_selector.dart';
import 'package:PiliPlus/services/thread_ripper/range_proxy.dart';

class PlaybackNetworkOptions {
  const PlaybackNetworkOptions({
    this.btrEnabled = false,
    this.autoSelectCdn = false,
    this.overseas = true,
    this.autoConcurrency = true,
    this.concurrency = 8,
    this.audioFollowCdn = true,
  });

  final bool btrEnabled;
  final bool autoSelectCdn;
  final bool overseas;
  final bool autoConcurrency;
  final int concurrency;
  final bool audioFollowCdn;
}

class PlaybackNetworkSources {
  const PlaybackNetworkSources({
    required this.video,
    this.audio,
    this.videoCandidates = const [],
    this.audioCandidates = const [],
  });

  // These remain the user's manual single-CDN URLs throughout BTR sessions.
  final String video;
  final String? audio;
  final List<String> videoCandidates;
  final List<String> audioCandidates;
}

/// Owns download sessions, without writing the user's CDN preference.
class PlaybackNetworkSession {
  PlaybackNetworkSession({
    required this.userAgent,
    DirectCdnSelector? selector,
    this.proxyFactory,
  }) : selector = selector ?? DirectCdnSelector(userAgent: userAgent);

  final String userAgent;
  final DirectCdnSelector selector;
  final RipperRangeProxy Function(
    PlaybackNetworkOptions,
    RipperAutoConcurrency,
  )?
  proxyFactory;
  final _autoConcurrency = RipperAutoConcurrency();
  RipperRangeProxy? _proxy;
  int _generation = 0;

  RipperAutoConcurrency? get autoConcurrency => _proxy?.autoConcurrency;
  bool get usingBtr => _proxy != null;

  void cancel() {
    _generation++;
    selector.cancel();
    _proxy?.close();
    _proxy = null;
  }

  void dispose() {
    cancel();
    selector.clear();
  }

  Future<PlaybackNetworkSources?> resolve(
    PlaybackNetworkSources source,
    PlaybackNetworkOptions options,
  ) async {
    cancel();
    final generation = _generation;
    if (source.videoCandidates.isEmpty) return source;
    if (options.btrEnabled) {
      final proxy =
          proxyFactory?.call(options, _autoConcurrency) ??
          RipperRangeProxy(
            concurrency: options.concurrency,
            overseas: options.overseas,
            autoConcurrency: options.autoConcurrency ? _autoConcurrency : null,
            userAgent: userAgent,
          );
      _proxy = proxy;
      try {
        await proxy.start();
        if (generation != _generation) return null;
        final video = proxy.register(source.videoCandidates);
        final audio = source.audio != null && source.audioCandidates.isNotEmpty
            ? proxy.register(source.audioCandidates, isAudio: true)
            : source.audio;
        return PlaybackNetworkSources(video: video, audio: audio);
      } catch (_) {
        proxy.close();
        if (generation != _generation) return null;
        _proxy = null;
        return source;
      }
    }
    if (!options.autoSelectCdn) return source;
    String video;
    try {
      video = await selector.select({
        if (RipperCdnResolver.supports(Uri.parse(source.video))) source.video,
        ...RipperCdnResolver.candidates(
          source.videoCandidates,
          overseas: options.overseas,
        ).map((u) => u.toString()),
      }, source.video);
    } catch (_) {
      return generation == _generation ? source : null;
    }
    if (generation != _generation) return null;
    var audio = source.audio;
    if (options.audioFollowCdn && audio != null && video != source.video) {
      final host = Uri.parse(video).host;
      for (final candidate in RipperCdnResolver.candidates(
        source.audioCandidates,
        overseas: options.overseas,
      )) {
        if (candidate.host == host) {
          audio = candidate.toString();
          break;
        }
      }
    }
    return PlaybackNetworkSources(video: video, audio: audio);
  }
}

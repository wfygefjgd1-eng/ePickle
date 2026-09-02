import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

import '../models/video_item.dart';
import '../utils/http_headers.dart';
import '../utils/playback_helpers.dart';
import 'source_catalog.dart';

/// One pre-warmed decoder: a paused, muted player for a site card's first
/// video plus the (item URL, stream URL) pair it was built for.
class _WarmEntry {
  _WarmEntry({
    required this.itemUrl,
    required this.streamUrl,
    required this.controller,
  });

  final String itemUrl;
  final String streamUrl;
  final VideoPlayerController controller;
}

/// 激进预加载的媒体层（设置开关，默认开）：首页空闲时为站点卡片的首个
/// 视频预初始化一个暂停、静音的播放器，把"详情 → 选流 → 解码器初始化 →
/// 首帧缓冲"整条串行链提前完成。
///
/// 与现有预加载的边界（不冲突的关键）：
/// - 信息流内部的 lookahead 预加载槽（下一条/下下条）完全不动；
/// - 播放器页通过 [take] 用「条目 URL + 首候选流 URL」精确匹配收编，
///   任何不匹配（画质上限变了、条目换了、没有预热）都走原有冷启动路径；
/// - 预热槽最多 [maxWarmPlayers] 个（LRU 淘汰），App 退后台、开关关闭、
///   某个预热被收编时全部释放——不给信息流自己的解码器预算添乱。
///
/// 卡片列表/详情层的预热由 HomePage 的既有链路完成（FeedListCache /
/// FeedDetailCache），本服务只负责最贵的解码器这一层。
class MediaPrewarm with WidgetsBindingObserver {
  MediaPrewarm._();

  static final MediaPrewarm instance = MediaPrewarm._();

  /// 解码器预算。信息流自己要 1 活动 + 2 lookahead，设备硬件解码器有限，
  /// 预热槽最多占 2 个（= 排在最前的 2 个站点卡片）。
  static const int maxWarmPlayers = 2;

  static const _initTimeout = Duration(seconds: 8);

  final List<_WarmEntry> _entries = [];
  bool _enabled = false;
  bool _observing = false;
  bool _appInForeground = true;

  bool get enabled => _enabled;

  /// Toggle follow-up: turning off releases every warm decoder immediately.
  void setEnabled(bool on) {
    if (_enabled == on) return;
    _enabled = on;
    if (on) {
      _appInForeground =
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed ||
              WidgetsBinding.instance.lifecycleState == null;
      if (!_observing) {
        WidgetsBinding.instance.addObserver(this);
        _observing = true;
      }
    } else {
      disposeAll('激进预加载已关闭');
    }
  }

  /// Pre-initialize one first-video player. Fire-and-forget safe; every
  /// failure path disposes its own decoder and quietly falls back to the
  /// normal cold play path.
  Future<void> warm({
    required SiteDef site,
    required VideoItem item,
    required VideoDetail detail,
    required int qualityCap,
  }) async {
    if (!_enabled || !_appInForeground) return;
    if (detail.countryBlocked || detail.unavailable) return;
    if (detail.prefersBrowserPlayer || detail.streams.isEmpty) return;
    // Same pick rule as the feed screens so [take] can match candidates.first.
    final stream =
        PlaybackHelpers.pickStream(detail, qualityCap) ?? detail.bestStream;
    if (stream == null || stream.url.isEmpty) return;
    if (_entries.any((e) => e.streamUrl == stream.url)) return;
    final player = VideoPlayerController.networkUrl(
      Uri.parse(stream.url),
      // Must mirror the screens' _createNetworkPlayer header stack exactly:
      // the adopted controller replays with these headers.
      httpHeaders: {
        ...AppHttpHeaders.forMediaUrl(
          null,
          pageUrl: site.primaryHost.replaceAll(RegExp(r'/$'), ''),
        ),
        ...AppHttpHeaders.forMediaUrl(
          stream.url,
          pageUrl: stream.referer ?? detail.url,
        ),
        ...stream.headers,
      },
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
    );
    try {
      await player.initialize().timeout(_initTimeout);
    } catch (_) {
      await _dispose(player);
      return;
    }
    if (PlaybackHelpers.isLikelyPreview(
      player,
      detail,
      siteId: site.id,
      isLive: site.kind == SiteKind.live,
    )) {
      // A teaser clip would poison the first play — drop it.
      await _dispose(player);
      return;
    }
    if (!_enabled || !_appInForeground) {
      await _dispose(player);
      return;
    }
    try {
      await player.pause();
      await player.setVolume(0);
    } catch (_) {}
    // LRU: make room before parking the new decoder.
    while (_entries.length >= maxWarmPlayers) {
      final oldest = _entries.removeAt(0);
      await _dispose(oldest.controller);
    }
    _entries.add(_WarmEntry(
      itemUrl: item.url,
      streamUrl: stream.url,
      controller: player,
    ));
  }

  /// Feed screens: adopt the warm controller for [itemUrl] playing
  /// [streamUrl]. On match the controller is handed over and the remaining
  /// warm players are released (the feed's own lookahead slots need the
  /// decoders). Entries for the same item with a different stream are dead
  /// (quality cap changed between warm and tap) and are released too.
  /// Returns null whenever nothing matches — the caller keeps its cold path.
  VideoPlayerController? take(String itemUrl, String? streamUrl) {
    if (_entries.isEmpty) return null;
    final idx = streamUrl == null
        ? -1
        : _entries.indexWhere(
            (e) => e.itemUrl == itemUrl && e.streamUrl == streamUrl,
          );
    if (idx < 0) {
      // Same item, different stream: the warm entry can never be adopted.
      final dead = _entries.where((e) => e.itemUrl == itemUrl).toList();
      for (final e in dead) {
        _entries.remove(e);
        unawaited(_dispose(e.controller));
      }
      return null;
    }
    final controller = _entries.removeAt(idx).controller;
    disposeAll('预热播放器已被播放页收编');
    return controller;
  }

  /// Release every warm decoder (toggle off / app backgrounded / adopted).
  void disposeAll(String reason) {
    if (_entries.isEmpty) return;
    assert(() {
      debugPrint('MediaPrewarm disposeAll: $reason (${_entries.length})');
      return true;
    }());
    for (final e in _entries) {
      unawaited(_dispose(e.controller));
    }
    _entries.clear();
  }

  Future<void> _dispose(VideoPlayerController player) async {
    try {
      await player.pause();
    } catch (_) {}
    try {
      await player.dispose();
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Same foreground rule the feed screens use (inactive counts: iOS
    // control-center swipes must not leave hidden decoders playing).
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      _appInForeground = false;
      disposeAll('App 退后台');
    } else if (state == AppLifecycleState.resumed) {
      _appInForeground = true;
    }
  }
}

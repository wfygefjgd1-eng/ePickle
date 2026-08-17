import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/feed_kind.dart';
import '../models/video_item.dart';
import '../services/generic_site_api.dart';
import '../services/mitao_api.dart';
import '../services/phub_api.dart';
import '../services/translator.dart';
import '../services/xvideos_api.dart';
import '../services/app_settings.dart';
import '../services/auto_rotate_controller.dart';
import '../services/cache_manager.dart';
import '../services/feed_list_cache.dart';
import '../services/player_chrome.dart';
import '../services/source_catalog.dart';
import '../services/watch_history.dart';
import '../utils/http_headers.dart';
import '../utils/playback_helpers.dart';
import '../widgets/player_settings_sheet.dart';
import '../widgets/stripchat_live_view.dart';
import '../widgets/video_player_page.dart';

export '../models/feed_kind.dart';

/// Vertical feed: one active player plus a small foreground-only preload pool.
class VideoFeedScreen extends StatefulWidget {
  const VideoFeedScreen({
    super.key,
    this.kind = VideoFeedKind.hot,
    this.autoStart = false,
    this.site,
    this.tagId,
    this.initialItems = const [],
    this.initialIndex = 0,
  });

  final VideoFeedKind kind;
  final bool autoStart;

  /// When set, non-native sites use [GenericSiteApi].
  final SiteDef? site;
  final String? tagId;
  final List<VideoItem> initialItems;
  final int initialIndex;

  @override
  State<VideoFeedScreen> createState() => VideoFeedScreenState();
}

class VideoFeedScreenState extends State<VideoFeedScreen>
    with WidgetsBindingObserver {
  final List<VideoItem> _items = [];
  final Set<String> _seen = {};
  late final PageController _pageCtrl;

  /// Only the currently playing controller (never multiple).
  VideoPlayerController? _controller;
  VideoPlayerController? _frozenController;
  int? _frozenIndex;
  int _frozenStreamHeight = 0;
  String? _browserLiveUrl;
  bool _browserIsStripchat = false;
  int _currentIndex = 0;
  int _loadSeq = 0;

  /// Pre-buffered next video controller (paused, muted) for instant swipe.
  VideoPlayerController? _preloadController;
  int? _preloadIndex;
  StreamQuality? _preloadStream;
  int _preloadRetries = 0;

  VideoPlayerController? _preloadController2;
  int? _preloadIndex2;
  StreamQuality? _preloadStream2;
  int _preloadRetries2 = 0;

  // Legacy slots are retained for state migration/cleanup, but the runtime
  // cap below never schedules them.
  VideoPlayerController? _preloadController3;
  int? _preloadIndex3;
  StreamQuality? _preloadStream3;
  int _preloadRetries3 = 0;

  VideoPlayerController? _preloadController4;
  int? _preloadIndex4;
  StreamQuality? _preloadStream4;
  int _preloadRetries4 = 0;

  bool _loading = false;
  bool _loadingMore = false;
  int _genericPage = 1;
  bool _pageLoading = false;
  bool _muted = false;
  bool _active = false;
  bool _appInForeground = true;
  bool _allowPop = false;
  bool _exiting = false;
  int _lifecycleEpoch = 0;
  String? _error;
  String _titleText = '';
  final ValueNotifier<String> _speedLabel = ValueNotifier<String>('');

  Timer? _progressTimer;
  Timer? _retryTimer;
  Timer? _skipTimer;
  Timer? _loadMoreTimer;
  Timer? _liveWatchdog;
  final ValueNotifier<double> _sliderValue = ValueNotifier(0);
  final ValueNotifier<String> _currentTime = ValueNotifier('0:00');
  final ValueNotifier<String> _totalTime = ValueNotifier<String>('0:00');
  int _baseSpeed = 1500;
  double _lastBufferedMs = 0;
  int _lastTickMs = 0;
  double _lastPosMs = 0;
  String _lastSpeedLabel = '';
  double _smoothedSpeedKbps = 0;
  int _speedSamples = 0;
  final Map<int, VideoDetail> _detailCache = {};
  int? _prefetchingIndex;
  int _preloadCycle = 0;
  bool _seeking = false;
  VideoDetail? _currentDetail;
  PlayerChrome? _chrome;
  AutoRotateController? _autoRotate;
  AppSettings? _settings;
  final Set<VideoPlayerController> _initializingControllers = {};

  int _currentStreamHeight = 0;
  int? _sessionQualityCap;
  int _stallTicks = 0;
  bool _stallLowering = false;
  bool _stallLoweredForItem = false;

  /// Ignore stall until this ms epoch. Long after resume (iOS progress freeze).
  int _stallArmedAfterMs = 0;

  /// Ignore PageView callbacks while re-syncing after portrait↔landscape layout.
  bool _resyncingPage = false;

  /// MUST include site id — otherwise all sites sharing kind=hot load the same list.
  String get _cacheKey {
    final siteId = widget.site?.id ?? 'legacy';
    final tag = widget.tagId ?? widget.kind.name;
    return '${siteId}_$tag';
  }

  late final Map<String, String> _httpHeaders = _buildHeaders();

  int get _effectiveQualityCap {
    if (_sessionQualityCap != null) return _sessionQualityCap!;
    // Prefer cached settings — avoid context.read after dispose / mid-async.
    return _settings?.qualityCap ?? 0;
  }

  /// Keep the decoder budget identical on iOS and Android.
  int get _preloadSlotCount =>
      PlaybackHelpers.preloadSlotCount(defaultTargetPlatform);

  bool get _canRun => mounted && _active && _appInForeground;

  /// Live list hard cap (window around current index).
  static const _maxLiveItems = 150;

  bool get _multiPreload => _preloadSlotCount > 1;

  /// Get current video URL for sharing
  String? getCurrentVideoUrl() {
    if (_currentIndex < 0 || _currentIndex >= _items.length) return null;
    return _items[_currentIndex].url;
  }

  Map<String, String> _buildHeaders() {
    final site = widget.site;
    if (site != null) {
      final base = site.primaryHost.replaceAll(RegExp(r'/$'), '');
      return AppHttpHeaders.forMediaUrl(null, pageUrl: base);
    }
    switch (widget.kind) {
      case VideoFeedKind.x:
        return AppHttpHeaders.forMediaUrl(
          null,
          pageUrl: 'https://www.xvideos.com',
        );
      case VideoFeedKind.zhong:
        return {
          ...AppHttpHeaders.forMediaUrl(null, pageUrl: 'https://mitaohk.com'),
          'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
        };
      case VideoFeedKind.hot:
      case VideoFeedKind.asian:
        return AppHttpHeaders.forMediaUrl(
          null,
          pageUrl: 'https://www.pornhub.com',
        );
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _chrome ??= context.read<PlayerChrome>();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _muted = context.read<AppSettings>().muted;
    final genericVideoSite = widget.site != null &&
        SourceCatalog.usesRandomizedGenericFeed(widget.site!);
    if (genericVideoSite) {
      // Native sources already randomize pages internally. Generic sites used
      // to always start at page 1 and restore the same cached list, making
      // every visit look identical.
      _genericPage = 1 + Random().nextInt(10);
      FeedListCache.clear(_cacheKey);
    }
    final hasInitialItems = widget.initialItems.isNotEmpty;
    if (hasInitialItems) {
      _items.addAll(widget.initialItems);
      _seen.addAll(widget.initialItems.map((item) => item.viewkey));
      _currentIndex = widget.initialIndex.clamp(0, _items.length - 1);
      _loading = false;
      _genericPage = 2;
    }
    final snap = hasInitialItems || genericVideoSite
        ? null
        : FeedListCache.take(_cacheKey);
    if (!hasInitialItems && snap != null && snap.items.isNotEmpty) {
      _items.addAll(snap.items);
      _seen.addAll(snap.seen);
      _currentIndex = snap.index.clamp(0, _items.length - 1);
      _loading = false;
      _genericPage = ((_items.length + 29) ~/ 30) + 1;
    }
    _pageCtrl = PageController(initialPage: _currentIndex);
    _autoRotate = AutoRotateController(onAction: _onAutoRotate);
    _settings = context.read<AppSettings>();
    _autoRotate!.enabled = _settings!.autoRotate;
    _autoRotate!.listening = false;
    _settings!.addListener(_onSettingsChanged);
    if (widget.autoStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) startPlaying();
      });
    }
  }

  void _onSettingsChanged() {
    final s = _settings;
    if (!mounted || s == null) return;
    _autoRotate?.enabled = s.autoRotate;
  }

  void _recordWatch(VideoItem item) {
    if (!mounted) return;
    final detail = _currentDetail;
    final watched = item.copyWith(
      title: detail != null && detail.title.trim().isNotEmpty
          ? detail.title.trim()
          : item.title,
      duration: detail != null && detail.durationSec > 0
          ? detail.durationLabel
          : item.duration,
      thumb: detail?.thumb ?? item.thumb,
    );
    // History persistence must never interrupt playback startup.
    unawaited(
      context.read<WatchHistory>().record(watched).catchError((_) {}),
    );
  }

  void _syncAutoRotateListening() {
    final ar = _autoRotate;
    if (ar == null) return;
    final on = _canRun;
    ar.listening = on;
    if (on) {
      ar.start();
    } else {
      ar.stop();
    }
  }

  void _onAutoRotate(AutoRotateAction action, DeviceOrientation? side) {
    final chrome = _chrome;
    if (!_canRun || chrome == null) {
      _autoRotate?.rejectAction();
      return;
    }
    switch (action) {
      case AutoRotateAction.enterLandscape:
      case AutoRotateAction.switchSide:
        _autoRotate?.confirmAction(action, side: side);
        // ignore: unawaited_futures
        chrome.enterFullscreen(preferredOrientation: side).then((_) {
          if (mounted) {
            setState(() {});
            _schedulePageResync();
          }
        });
      case AutoRotateAction.exitLandscape:
        if (!chrome.immersive) {
          _autoRotate?.confirmAction(action);
          return;
        }
        _autoRotate?.confirmAction(action);
        // ignore: unawaited_futures
        chrome.exitFullscreen().then((_) {
          if (mounted) {
            setState(() {});
            _schedulePageResync();
          }
        });
    }
  }

  @override
  void dispose() {
    _active = false;
    _appInForeground = false;
    _loadSeq++;
    _lifecycleEpoch++;
    _cancelBackgroundWork();
    if (_browserLiveUrl != null) {
      unawaited(StripchatLiveView.pauseLive());
    }
    if (_items.isNotEmpty && widget.initialItems.isEmpty) {
      final idx = _currentIndex.clamp(0, _items.length - 1);
      FeedListCache.put(
        _cacheKey,
        FeedListSnapshot(
          items: List<VideoItem>.from(_items),
          seen: Set<String>.from(_seen),
          index: idx,
        ),
      );
    }
    if (widget.initialItems.isNotEmpty) {
      FeedListCache.clear(_cacheKey);
      _items.clear();
      _seen.clear();
      _detailCache.clear();
    }
    _settings?.removeListener(_onSettingsChanged);
    _settings = null;
    _autoRotate?.dispose();
    _autoRotate = null;
    try {
      _chrome?.ensurePortraitChrome();
    } catch (_) {}
    WidgetsBinding.instance.removeObserver(this);
    _progressTimer?.cancel();
    _retryTimer?.cancel();
    _skipTimer?.cancel();
    _loadMoreTimer?.cancel();
    _liveWatchdog?.cancel();
    _liveWatchdog = null;
    _sliderValue.dispose();
    _currentTime.dispose();
    _totalTime.dispose();
    _speedLabel.dispose();
    _pageCtrl.dispose();
    final c = _controller;
    _controller = null;
    try {
      c?.pause();
      c?.dispose();
    } catch (_) {}
    final frozen = _frozenController;
    _frozenController = null;
    _frozenIndex = null;
    if (frozen != null) {
      unawaited(
        frozen.pause().catchError((_) {}).whenComplete(() => frozen.dispose()),
      );
    }
    _disposeInitializingPlayersSync();
    _disposePreloadSync();
    WakelockPlus.disable();
    super.dispose();
  }

  void _disposePreloadSync() {
    final p = _preloadController;
    _preloadController = null;
    _preloadIndex = null;
    _preloadStream = null;
    _preloadRetries = 0;
    if (p != null) {
      // ignore: unawaited_futures
      p.pause().catchError((_) {}).whenComplete(() {
        try {
          p.dispose();
        } catch (_) {}
      });
    }

    final p2 = _preloadController2;
    _preloadController2 = null;
    _preloadIndex2 = null;
    _preloadStream2 = null;
    _preloadRetries2 = 0;
    if (p2 != null) {
      // ignore: unawaited_futures
      p2.pause().catchError((_) {}).whenComplete(() {
        try {
          p2.dispose();
        } catch (_) {}
      });
    }

    final p3 = _preloadController3;
    _preloadController3 = null;
    _preloadIndex3 = null;
    _preloadStream3 = null;
    _preloadRetries3 = 0;
    if (p3 != null) {
      unawaited(p3.pause().catchError((_) {}).whenComplete(() => p3.dispose()));
    }

    final p4 = _preloadController4;
    _preloadController4 = null;
    _preloadIndex4 = null;
    _preloadStream4 = null;
    _preloadRetries4 = 0;
    if (p4 != null) {
      unawaited(p4.pause().catchError((_) {}).whenComplete(() => p4.dispose()));
    }
  }

  void _disposeInitializingPlayersSync() {
    final players = List<VideoPlayerController>.from(_initializingControllers);
    _initializingControllers.clear();
    for (final player in players) {
      unawaited(player.dispose().catchError((_) {}));
    }
  }

  VideoPlayerController _createNetworkPlayer(
    StreamQuality stream,
    String pageUrl,
  ) {
    final mediaUrl = stream.url;
    final player = VideoPlayerController.networkUrl(
      Uri.parse(mediaUrl),
      httpHeaders: {
        ..._httpHeaders,
        ...AppHttpHeaders.forMediaUrl(
          mediaUrl,
          pageUrl: stream.referer ?? pageUrl,
        ),
        ...stream.headers,
      },
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
    );
    _initializingControllers.add(player);
    return player;
  }

  void _cancelBackgroundWork() {
    _preloadCycle++;
    _progressTimer?.cancel();
    _progressTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    _skipTimer?.cancel();
    _skipTimer = null;
    _loadMoreTimer?.cancel();
    _loadMoreTimer = null;
    _liveWatchdog?.cancel();
    _liveWatchdog = null;
    context.read<PhubApi>().cancelRequests('app backgrounded');
    context.read<XvideosApi>().cancelRequests('app backgrounded');
    context.read<MitaoApi>().cancelRequests('app backgrounded');
    context.read<GenericSiteApi>().cancelRequests('app backgrounded');
    _disposeInitializingPlayersSync();
    _disposePreloadSync();
  }

  Future<void> _toggleFullscreen() async {
    final chrome = context.read<PlayerChrome>();
    if (chrome.immersive) {
      await chrome.exitFullscreen();
      _autoRotate?.syncLandscapeMode(false, fromUser: true);
    } else {
      final side = _autoRotate?.lastSide;
      await chrome.enterFullscreen(preferredOrientation: side);
      _autoRotate?.syncLandscapeMode(true, fromUser: true, side: side);
    }
    if (mounted) {
      setState(() {});
      _schedulePageResync();
    }
  }

  /// RotatedBox landscape changes PageView viewport extent; pixel offset then
  /// maps to the wrong page (often 0). Re-pin to [_currentIndex] after layout.
  void _schedulePageResync() {
    void pin() {
      if (!mounted || !_pageCtrl.hasClients) return;
      final i = _currentIndex.clamp(
        0,
        (_items.isEmpty ? 1 : _items.length) - 1,
      );
      if (_items.isEmpty) return;
      _resyncingPage = true;
      try {
        _pageCtrl.jumpToPage(i);
      } catch (_) {}
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          _resyncingPage = false;
          return;
        }
        if (_pageCtrl.hasClients) {
          final p = _pageCtrl.page?.round();
          if (p != null && p != i) {
            try {
              _pageCtrl.jumpToPage(i);
            } catch (_) {}
          }
        }
        _resyncingPage = false;
      });
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => pin());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      if (!_appInForeground) return;
      _appInForeground = false;
      _lifecycleEpoch++;
      _loadSeq++;
      _autoRotate?.listening = false;
      _autoRotate?.stop();
      _cancelBackgroundWork();
      final controller = _controller;
      if (controller != null) {
        unawaited(controller.pause().catchError((_) {}));
      }
      if (_browserLiveUrl != null) {
        unawaited(StripchatLiveView.pauseLive());
      }
      WakelockPlus.disable();
      // iOS freezes progress in background — never treat as stall on return.
      _stallTicks = 0;
      _stallArmedAfterMs = DateTime.now().millisecondsSinceEpoch + 8000;
    } else if (state == AppLifecycleState.resumed) {
      _appInForeground = true;
      _stallTicks = 0;
      _stallArmedAfterMs = DateTime.now().millisecondsSinceEpoch + 8000;
      if (!_active) return;
      _syncAutoRotateListening();
      final controller = _controller;
      if (_browserLiveUrl != null) {
        unawaited(StripchatLiveView.resumeLive());
        _startLiveWatchdog();
        WakelockPlus.enable();
      } else if (controller != null && controller.value.isInitialized) {
        unawaited(controller.play().then((_) {
          if (!_canRun || !identical(controller, _controller)) return;
          _startProgressTimer();
          _restartPreloading();
        }).catchError((_) {}));
        WakelockPlus.enable();
      } else if (_items.isNotEmpty) {
        unawaited(_playIndex(_currentIndex.clamp(0, _items.length - 1)));
      } else if (!_loadingMore) {
        unawaited(_loadMore());
      }
    }
  }

  void _restartPreloading() {
    if (!_canRun || _items.isEmpty) return;
    final cycle = ++_preloadCycle;
    unawaited(_runPreloadCycle(cycle));
  }

  Future<void> _runPreloadCycle(int cycle) async {
    for (var slot = 0; slot < _preloadSlotCount; slot++) {
      final index = _currentIndex + slot + 1;
      if (cycle != _preloadCycle || !_canRun || index >= _items.length) return;
      await _prefetchDetail(index);
      if (cycle != _preloadCycle || !_canRun) return;
      if (slot == 0) {
        await _preloadNext(index);
      } else if (slot == 1) {
        await _preloadNext2(index);
      } else if (slot == 2) {
        await _preloadNext3(index);
      } else {
        await _preloadNext4(index);
      }
    }
  }

  void startPlaying() {
    _active = true;
    if (!_appInForeground) return;
    final immersive = _chrome?.immersive ?? false;
    _autoRotate?.syncLandscapeMode(
      immersive,
      side: immersive ? _chrome?.landscapeSide : null,
    );
    _syncAutoRotateListening();
    if (_browserLiveUrl != null) {
      WakelockPlus.enable();
      return;
    }
    if (_items.isEmpty) {
      if (!_loadingMore) {
        setState(() => _loading = true);
        _loadMore();
      }
      return;
    }
    if (_controller != null && _controller!.value.isInitialized) {
      _controller!.play();
      _startProgressTimer();
      WakelockPlus.enable();
      return;
    }
    _playIndex(_currentIndex);
  }

  void pausePlayback({bool releasePlayers = true}) {
    _active = false;
    _autoRotate?.syncLandscapeMode(false);
    _syncAutoRotateListening();
    _loadSeq++;
    _lifecycleEpoch++;
    _cancelBackgroundWork();
    final c = _controller;
    _controller = null;
    final hadBrowserLive = _browserLiveUrl != null;
    _browserLiveUrl = null;
    _browserIsStripchat = false;
    try {
      c?.setVolume(0);
      c?.pause();
    } catch (_) {}
    final frozen = _frozenController;
    _frozenController = null;
    _frozenIndex = null;
    if (frozen != null) {
      unawaited(frozen
          .pause()
          .catchError((_) {})
          .whenComplete(() => frozen.dispose()));
    }
    WakelockPlus.disable();
    if (hadBrowserLive) {
      unawaited(StripchatLiveView.pauseLive());
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
    if (releasePlayers && c != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        try {
          c.dispose();
        } catch (_) {}
      });
    }
  }

  bool get _useGeneric {
    final s = widget.site;
    if (s == null) return false;
    return s.id != 'pornhub' && s.id != 'xvideos' && s.id != 'mitao';
  }

  Future<List<VideoItem>> _fetchBatch({required bool isCold}) async {
    // Cold: few URLs, fail fast (less spinner). Warm: more variety.
    final limit = isCold ? 10 : 30;
    final maxUrls = isCold ? 2 : 5;
    if (_useGeneric && widget.site != null) {
      final requestedPage = _genericPage;
      final genericApi = context.read<GenericSiteApi>();
      final site = widget.site!;
      final tagId = widget.tagId ?? 'hot';
      final randomize = SourceCatalog.usesRandomizedGenericFeed(site);
      List<VideoItem> list;
      try {
        list = await genericApi.fetchFeed(
          site,
          tagId: tagId,
          page: requestedPage,
          exclude: _seen,
          limit: limit,
        );
      } catch (_) {
        if (!randomize || !isCold || requestedPage == 1) rethrow;
        // Some smaller sites have fewer pages. Randomization must never turn
        // a working source into an error, so retry its first page once.
        list = await genericApi.fetchFeed(
          site,
          tagId: tagId,
          page: 1,
          exclude: _seen,
          limit: limit,
        );
        _genericPage = 1;
      }
      if (randomize) list.shuffle();
      if (list.isNotEmpty && requestedPage == _genericPage) {
        _genericPage++;
      } else if (list.isNotEmpty && _genericPage == 1) {
        _genericPage = 2;
      }
      return list;
    }
    switch (widget.kind) {
      case VideoFeedKind.asian:
        return context.read<PhubApi>().fetchAsian(
              exclude: _seen,
              limit: limit,
              maxUrls: maxUrls,
            );
      case VideoFeedKind.hot:
        return context.read<PhubApi>().fetchRecommend(
              exclude: _seen,
              limit: limit,
              maxUrls: maxUrls,
            );
      case VideoFeedKind.x:
        return context.read<XvideosApi>().fetchFeed(
              exclude: _seen,
              limit: limit,
              maxUrls: maxUrls,
            );
      case VideoFeedKind.zhong:
        return context.read<MitaoApi>().fetchZhong(
              exclude: _seen,
              limit: limit,
              maxPages: maxUrls,
            );
    }
  }

  Future<VideoDetail> _fetchDetail(String url) {
    // Prefer host-based adapters when FreePorn (or other directories) link out.
    final low = url.toLowerCase();
    if (low.contains('xvideos.com') || low.contains('xvideos.es')) {
      return context.read<XvideosApi>().getVideoDetail(url);
    }
    if (low.contains('mitaohk.com')) {
      return context.read<MitaoApi>().getVideoDetail(url);
    }
    if (low.contains('pornhub.com') || low.contains('pornhub.org')) {
      return context.read<PhubApi>().getVideoDetail(url);
    }
    if (_useGeneric && widget.site != null) {
      // If the card points at another built-in site, parse with that site's rules.
      SiteDef? hostSite;
      for (final s in SourceCatalog.all) {
        if (s.kind != SiteKind.video) continue;
        final hit = s.mirrors.any((m) {
          final h = Uri.tryParse(m)?.host.toLowerCase() ?? '';
          return h.isNotEmpty && low.contains(h);
        });
        if (hit) {
          hostSite = s;
          break;
        }
      }
      return context
          .read<GenericSiteApi>()
          .getVideoDetail(hostSite ?? widget.site!, url);
    }
    if (widget.kind == VideoFeedKind.x) {
      return context.read<XvideosApi>().getVideoDetail(url);
    }
    if (widget.kind == VideoFeedKind.zhong) {
      return context.read<MitaoApi>().getVideoDetail(url);
    }
    if (widget.kind == VideoFeedKind.hot ||
        widget.kind == VideoFeedKind.asian) {
      return context.read<PhubApi>().getVideoDetail(url);
    }
    return context.read<GenericSiteApi>().getCustomDetail(url);
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_appInForeground) return;
    final lifecycleEpoch = _lifecycleEpoch;
    setState(() {
      _loadingMore = true;
      _error = null;
    });
    final isCold = _items.isEmpty;
    try {
      var list = await _fetchBatch(isCold: isCold);
      if (list.isEmpty && isCold) {
        list = await _fetchBatch(isCold: false);
      }
      if (!mounted || !_appInForeground || lifecycleEpoch != _lifecycleEpoch) {
        _discardStaleLoad();
        return;
      }
      final addedStart = _items.length;
      for (final item in list) {
        if (_seen.add(item.viewkey)) _items.add(item);
      }
      _trimItemsWindow();
      if (!mounted) return;
      setState(() {
        _loadingMore = false;
        _loading = false;
        if (_items.isEmpty) {
          _error = '内容不存在(404)';
        }
      });
      // PH / X titles are English — batch translate after list load.
      final translateStart = addedStart.clamp(0, _items.length);
      if (widget.kind != VideoFeedKind.zhong &&
          widget.site?.kind != SiteKind.live &&
          _items.length > translateStart) {
        // ignore: unawaited_futures
        _translateItemsRange(translateStart);
      }
      if (_canRun &&
          _items.isNotEmpty &&
          _controller == null &&
          _browserLiveUrl == null) {
        _playIndex(_currentIndex.clamp(0, _items.length - 1));
      }
      if (isCold && _items.length < 20 && _canRun) {
        _loadMoreTimer?.cancel();
        _loadMoreTimer = Timer(const Duration(seconds: 1), () {
          if (_canRun) _loadMore();
        });
      }
    } catch (e) {
      if (!mounted) return;
      if (!_appInForeground || lifecycleEpoch != _lifecycleEpoch) {
        _discardStaleLoad();
        return;
      }
      setState(() {
        _loading = false;
        _loadingMore = false;
        if (_items.isEmpty) {
          _error = PlaybackHelpers.friendlyError(e);
        } else if (mounted) {
          PlaybackHelpers.toast(
            context,
            '加载更多失败：${PlaybackHelpers.friendlyError(e)}',
          );
        }
      });
    }
  }

  void _discardStaleLoad() {
    _loading = false;
    _loadingMore = false;
    if (!_canRun || _items.isNotEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_canRun && !_loadingMore && _items.isEmpty) {
        unawaited(_loadMore());
      }
    });
  }

  final Set<int> _retried = {};

  /// Temporarily disabled auto-skip so failed items stay on screen for debugging.
  void _scheduleSkipToNext(int fromIndex) {
    if (!_canRun) return;
    final settings = _settings ?? context.read<AppSettings>();
    if (!settings.autoSkipUnavailable) {
      PlaybackHelpers.toast(
        context,
        '当前频道无法播放；可在设置中开启“自动跳过无信号频道”。',
      );
      return;
    }
    if (_items.length < 2) return;
    final next = (fromIndex + 1) % _items.length;
    PlaybackHelpers.toast(
      context,
      '当前频道无信号，正在切换下一个；可在设置中关闭自动跳过。',
    );
    _retryTimer?.cancel();
    _retryTimer = Timer(const Duration(milliseconds: 700), () {
      if (_canRun && mounted) _playIndex(next);
    });
    return;
    // One silent retry only — never auto-jump to next video.
    /*
    if (!_retried.contains(fromIndex)) {
      _retried.add(fromIndex);
      _retryTimer?.cancel();
      _retryTimer = Timer(const Duration(milliseconds: 800), () {
        if (!_canRun) return;
        _playIndex(fromIndex);
      });
      return;
    }
    if (mounted) {
      PlaybackHelpers.toast(
        context,
        '本条无法播放（已停止自动跳过，请手动上下滑）',
        duration: const Duration(seconds: 3),
      );
    }
    */
  }

  Future<void> _exitAfterStopping() async {
    if (_exiting) return;
    _exiting = true;
    _active = false;
    _appInForeground = false;
    _loadSeq++;
    _lifecycleEpoch++;
    _cancelBackgroundWork();
    _liveWatchdog?.cancel();
    _liveWatchdog = null;
    if (_browserLiveUrl != null) {
      try {
        await StripchatLiveView.pauseLive();
      } catch (_) {}
    }
    _browserLiveUrl = null;
    _browserIsStripchat = false;
    final frozen = _frozenController;
    _frozenController = null;
    _frozenIndex = null;
    if (frozen != null) {
      try {
        await frozen.pause();
      } catch (_) {}
      try {
        await frozen.dispose();
      } catch (_) {}
    }
    await _disposeController().timeout(
      const Duration(seconds: 2),
      onTimeout: () {},
    );
    WakelockPlus.disable();
    if (!mounted) return;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  Future<void> _prefetchDetail(int index) async {
    if (!_canRun || index < 0 || index >= _items.length) return;
    if (_detailCache.containsKey(index)) return;
    if (_prefetchingIndex == index) return;
    _prefetchingIndex = index;
    final url = _items[index].url;
    try {
      final d = await _fetchDetail(url);
      if (!_canRun) return;
      _detailCache[index] = d;
      _prunePageState(_currentIndex);
    } catch (_) {
      // Ignore errors in prefetch
    } finally {
      if (_prefetchingIndex == index) _prefetchingIndex = null;
    }
  }

  void _disposePreload() {
    final p = _preloadController;
    _preloadController = null;
    _preloadIndex = null;
    _preloadStream = null;
    _preloadRetries = 0;
    if (p != null) {
      // ignore: unawaited_futures
      p.pause().catchError((_) {}).whenComplete(() {
        try {
          p.dispose();
        } catch (_) {}
      });
    }

    final p2 = _preloadController2;
    _preloadController2 = null;
    _preloadIndex2 = null;
    _preloadStream2 = null;
    _preloadRetries2 = 0;
    if (p2 != null) {
      // ignore: unawaited_futures
      p2.pause().catchError((_) {}).whenComplete(() {
        try {
          p2.dispose();
        } catch (_) {}
      });
    }

    final p3 = _preloadController3;
    _preloadController3 = null;
    _preloadIndex3 = null;
    _preloadStream3 = null;
    _preloadRetries3 = 0;
    if (p3 != null) {
      unawaited(p3.pause().catchError((_) {}).whenComplete(() => p3.dispose()));
    }

    final p4 = _preloadController4;
    _preloadController4 = null;
    _preloadIndex4 = null;
    _preloadStream4 = null;
    _preloadRetries4 = 0;
    if (p4 != null) {
      unawaited(p4.pause().catchError((_) {}).whenComplete(() => p4.dispose()));
    }
  }

  Future<void> _preloadNext(int index) async {
    if (!_canRun ||
        index < 0 ||
        index >= _items.length ||
        index == _currentIndex) {
      return;
    }
    if (_preloadIndex == index && _preloadController != null) return;
    final seq = _loadSeq;
    final detail = _detailCache[index];
    if (detail == null) return;
    if (detail.countryBlocked || detail.unavailable) return;
    final cap = _effectiveQualityCap;
    final stream = PlaybackHelpers.pickStream(detail, cap) ?? detail.bestStream;
    if (stream == null) return;
    if (_preloadIndex == index &&
        _preloadController != null &&
        _preloadStream?.url == stream.url) {
      return;
    }
    final existing = _preloadController;
    final existingIndex = _preloadIndex;
    _preloadController = null;
    _preloadIndex = null;
    _preloadStream = null;
    _preloadRetries = 0;
    if (existing != null && existingIndex != index) {
      // ignore: unawaited_futures
      existing.pause().catchError((_) {}).whenComplete(() {
        try {
          existing.dispose();
        } catch (_) {}
      });
    }
    if (seq != _loadSeq || !_canRun) return;
    final player = _createNetworkPlayer(stream, detail.url);
    try {
      await player.initialize().timeout(const Duration(seconds: 12));
      _initializingControllers.remove(player);
      if (PlaybackHelpers.isLikelyPreview(
        player,
        detail,
        siteId: widget.site?.id,
        isLive: widget.site?.kind == SiteKind.live,
      )) {
        await player.dispose();
        return;
      }
      _preloadRetries = 0;
    } catch (e) {
      _initializingControllers.remove(player);
      // Retry up to 2 times for transient failures
      if (_preloadRetries < 2 && seq == _loadSeq && _canRun) {
        _preloadRetries++;
        try {
          await player.dispose();
        } catch (_) {}
        await Future.delayed(Duration(milliseconds: 300 * _preloadRetries));
        if (seq == _loadSeq && _canRun) {
          return _preloadNext(index);
        }
      }
      try {
        await player.dispose();
      } catch (_) {}
      return;
    }
    if (seq != _loadSeq || !_canRun) {
      try {
        await player.dispose();
      } catch (_) {}
      return;
    }
    _preloadController = player;
    _preloadIndex = index;
    _preloadStream = stream;
    _preloadRetries = 0;
    try {
      await player.pause();
      player.setVolume(0);
    } catch (_) {}
  }

  Future<void> _preloadNext2(int index) async {
    if (!_canRun ||
        index < 0 ||
        index >= _items.length ||
        index == _currentIndex) {
      return;
    }
    if (_preloadIndex2 == index && _preloadController2 != null) return;
    final seq = _loadSeq;
    final detail = _detailCache[index];
    if (detail == null) return;
    if (detail.countryBlocked || detail.unavailable) return;
    final cap = _effectiveQualityCap;
    final stream = PlaybackHelpers.pickStream(detail, cap) ?? detail.bestStream;
    if (stream == null) return;
    if (_preloadIndex2 == index &&
        _preloadController2 != null &&
        _preloadStream2?.url == stream.url) {
      return;
    }
    final existing = _preloadController2;
    final existingIndex = _preloadIndex2;
    _preloadController2 = null;
    _preloadIndex2 = null;
    _preloadStream2 = null;
    _preloadRetries2 = 0;
    if (existing != null && existingIndex != index) {
      // ignore: unawaited_futures
      existing.pause().catchError((_) {}).whenComplete(() {
        try {
          existing.dispose();
        } catch (_) {}
      });
    }
    if (seq != _loadSeq || !_canRun) return;
    final player = _createNetworkPlayer(stream, detail.url);
    try {
      await player.initialize().timeout(const Duration(seconds: 12));
      _initializingControllers.remove(player);
      if (PlaybackHelpers.isLikelyPreview(
        player,
        detail,
        siteId: widget.site?.id,
        isLive: widget.site?.kind == SiteKind.live,
      )) {
        await player.dispose();
        return;
      }
      _preloadRetries2 = 0;
    } catch (e) {
      _initializingControllers.remove(player);
      // Retry up to 2 times for transient failures
      if (_preloadRetries2 < 2 && seq == _loadSeq && _canRun) {
        _preloadRetries2++;
        try {
          await player.dispose();
        } catch (_) {}
        await Future.delayed(Duration(milliseconds: 300 * _preloadRetries2));
        if (seq == _loadSeq && _canRun) {
          return _preloadNext2(index);
        }
      }
      try {
        await player.dispose();
      } catch (_) {}
      return;
    }
    if (seq != _loadSeq || !_canRun) {
      try {
        await player.dispose();
      } catch (_) {}
      return;
    }
    _preloadController2 = player;
    _preloadIndex2 = index;
    _preloadStream2 = stream;
    _preloadRetries2 = 0;
    try {
      await player.pause();
      player.setVolume(0);
    } catch (_) {}
  }

  // ignore: unused_element
  Future<void> _preloadNext3(int index) async {
    if (!_canRun ||
        index < 0 ||
        index >= _items.length ||
        index == _currentIndex) {
      return;
    }
    if (_preloadIndex3 == index && _preloadController3 != null) return;
    final seq = _loadSeq;
    final detail = _detailCache[index];
    if (detail == null) return;
    if (detail.countryBlocked || detail.unavailable) return;
    final cap = _effectiveQualityCap;
    final stream = PlaybackHelpers.pickStream(detail, cap) ?? detail.bestStream;
    if (stream == null) return;
    if (_preloadIndex3 == index &&
        _preloadController3 != null &&
        _preloadStream3?.url == stream.url) {
      return;
    }
    final existing = _preloadController3;
    final existingIndex = _preloadIndex3;
    _preloadController3 = null;
    _preloadIndex3 = null;
    _preloadStream3 = null;
    _preloadRetries3 = 0;
    if (existing != null && existingIndex != index) {
      // ignore: unawaited_futures
      existing.pause().catchError((_) {}).whenComplete(() {
        try {
          existing.dispose();
        } catch (_) {}
      });
    }
    if (seq != _loadSeq || !_canRun) return;
    final player = _createNetworkPlayer(stream, detail.url);
    try {
      await player.initialize().timeout(const Duration(seconds: 12));
      _initializingControllers.remove(player);
      if (PlaybackHelpers.isLikelyPreview(
        player,
        detail,
        siteId: widget.site?.id,
        isLive: widget.site?.kind == SiteKind.live,
      )) {
        await player.dispose();
        return;
      }
      _preloadRetries3 = 0;
    } catch (e) {
      _initializingControllers.remove(player);
      // Retry up to 2 times for transient failures
      if (_preloadRetries3 < 2 && seq == _loadSeq && _canRun) {
        _preloadRetries3++;
        try {
          await player.dispose();
        } catch (_) {}
        await Future.delayed(Duration(milliseconds: 300 * _preloadRetries3));
        if (seq == _loadSeq && _canRun) {
          return _preloadNext3(index);
        }
      }
      try {
        await player.dispose();
      } catch (_) {}
      return;
    }
    if (seq != _loadSeq || !_canRun) {
      try {
        await player.dispose();
      } catch (_) {}
      return;
    }
    _preloadController3 = player;
    _preloadIndex3 = index;
    _preloadStream3 = stream;
    _preloadRetries3 = 0;
    try {
      await player.pause();
      player.setVolume(0);
    } catch (_) {}
  }

  // ignore: unused_element
  Future<void> _preloadNext4(int index) async {
    if (!_canRun ||
        index < 0 ||
        index >= _items.length ||
        index == _currentIndex) {
      return;
    }
    if (_preloadIndex4 == index && _preloadController4 != null) return;
    final seq = _loadSeq;
    final detail = _detailCache[index];
    if (detail == null) return;
    if (detail.countryBlocked || detail.unavailable) return;
    final cap = _effectiveQualityCap;
    final stream = PlaybackHelpers.pickStream(detail, cap) ?? detail.bestStream;
    if (stream == null) return;
    if (_preloadIndex4 == index &&
        _preloadController4 != null &&
        _preloadStream4?.url == stream.url) {
      return;
    }
    final existing = _preloadController4;
    final existingIndex = _preloadIndex4;
    _preloadController4 = null;
    _preloadIndex4 = null;
    _preloadStream4 = null;
    _preloadRetries4 = 0;
    if (existing != null && existingIndex != index) {
      // ignore: unawaited_futures
      existing.pause().catchError((_) {}).whenComplete(() {
        try {
          existing.dispose();
        } catch (_) {}
      });
    }
    if (seq != _loadSeq || !_canRun) return;
    final player = _createNetworkPlayer(stream, detail.url);
    try {
      await player.initialize().timeout(const Duration(seconds: 12));
      _initializingControllers.remove(player);
      if (PlaybackHelpers.isLikelyPreview(
        player,
        detail,
        siteId: widget.site?.id,
        isLive: widget.site?.kind == SiteKind.live,
      )) {
        await player.dispose();
        return;
      }
      _preloadRetries4 = 0;
    } catch (e) {
      _initializingControllers.remove(player);
      // Retry up to 2 times for transient failures
      if (_preloadRetries4 < 2 && seq == _loadSeq && _canRun) {
        _preloadRetries4++;
        try {
          await player.dispose();
        } catch (_) {}
        await Future.delayed(Duration(milliseconds: 300 * _preloadRetries4));
        if (seq == _loadSeq && _canRun) {
          return _preloadNext4(index);
        }
      }
      try {
        await player.dispose();
      } catch (_) {}
      return;
    }
    if (seq != _loadSeq || !_canRun) {
      try {
        await player.dispose();
      } catch (_) {}
      return;
    }
    _preloadController4 = player;
    _preloadIndex4 = index;
    _preloadStream4 = stream;
    _preloadRetries4 = 0;
    try {
      await player.pause();
      player.setVolume(0);
    } catch (_) {}
  }

  Future<void> _playIndex(int index) async {
    if (!_canRun || index < 0 || index >= _items.length) return;
    final seq = ++_loadSeq;
    final item = _items[index];

    if (widget.site?.isStripchat == true) {
      _disposePreload();
      await _disposeController();
      if (seq != _loadSeq || !_canRun || !mounted) return;
      final sourceUri = Uri.tryParse(item.url);
      final roomSegments = sourceUri?.pathSegments
              .where((segment) => segment.trim().isNotEmpty)
              .toList() ??
          const <String>[];
      final room = roomSegments.isEmpty ? null : roomSegments.last;
      if (room == null || !RegExp(r'^[a-zA-Z0-9_-]{3,60}$').hasMatch(room)) {
        setState(() {
          _pageLoading = false;
          _browserLiveUrl = null;
          _browserIsStripchat = false;
        });
        PlaybackHelpers.toast(context, 'Stripchat 主播房间地址无效');
        return;
      }
      await _playInAppBrowser(
        index: index,
        item: item,
        pageUrl: 'https://stripchat.com/$room',
        title: item.title,
        live: true,
        seq: seq,
        stripchat: true,
      );
      return;
    }

    _browserLiveUrl = null;
    _browserIsStripchat = false;

    // Check if we have this index preloaded in any slot
    VideoPlayerController? preloaded;
    VideoDetail? preloadDetail;
    StreamQuality? preloadStream;
    int? frozenTargetHeight;
    int preloadSlot = 0; // 1, 2, or 3

    if (_frozenIndex == index &&
        _frozenController != null &&
        _frozenController!.value.isInitialized) {
      preloaded = _frozenController!;
      preloadDetail = _detailCache[index];
      frozenTargetHeight = _frozenStreamHeight;
      preloadSlot = -1;
    } else if (_preloadIndex == index &&
        _preloadController != null &&
        _preloadController!.value.isInitialized) {
      preloaded = _preloadController!;
      preloadDetail = _detailCache[index];
      preloadStream = _preloadStream;
      preloadSlot = 1;
    } else if (_preloadSlotCount >= 2 &&
        _preloadIndex2 == index &&
        _preloadController2 != null &&
        _preloadController2!.value.isInitialized) {
      preloaded = _preloadController2!;
      preloadDetail = _detailCache[index];
      preloadStream = _preloadStream2;
      preloadSlot = 2;
    } else if (_preloadSlotCount >= 3 &&
        _preloadIndex3 == index &&
        _preloadController3 != null &&
        _preloadController3!.value.isInitialized) {
      preloaded = _preloadController3!;
      preloadDetail = _detailCache[index];
      preloadStream = _preloadStream3;
      preloadSlot = 3;
    } else if (_preloadSlotCount >= 4 &&
        _preloadIndex4 == index &&
        _preloadController4 != null &&
        _preloadController4!.value.isInitialized) {
      preloaded = _preloadController4!;
      preloadDetail = _detailCache[index];
      preloadStream = _preloadStream4;
      preloadSlot = 4;
    }

    if (preloaded != null) {
      final previous = _controller;
      final previousIndex = _currentIndex;
      final previousHeight = _currentStreamHeight;
      _controller = null;

      // Clear the slot that was used
      if (preloadSlot == -1) {
        _frozenController = null;
        _frozenIndex = null;
        preloadStream = null;
      } else if (preloadSlot == 1) {
        _preloadController = null;
        _preloadIndex = null;
        _preloadStream = null;
      } else if (preloadSlot == 2) {
        _preloadController2 = null;
        _preloadIndex2 = null;
        _preloadStream2 = null;
      } else if (preloadSlot == 3) {
        _preloadController3 = null;
        _preloadIndex3 = null;
        _preloadStream3 = null;
      } else if (preloadSlot == 4) {
        _preloadController4 = null;
        _preloadIndex4 = null;
        _preloadStream4 = null;
      }

      if (previous != null && !identical(previous, preloaded)) {
        await _freezePrevious(previous, previousIndex, previousHeight);
      }
      if (seq != _loadSeq || !_canRun || !mounted) {
        try {
          await preloaded.dispose();
        } catch (_) {}
        return;
      }
      _currentDetail = preloadDetail;
      _currentIndex = index;
      _currentStreamHeight = preloadSlot == -1
          ? (frozenTargetHeight ?? 0)
          : (preloadStream?.height ?? 0);
      _stallTicks = 0;
      _stallLoweredForItem = false;
      _stallArmedAfterMs = DateTime.now().millisecondsSinceEpoch + 4000;
      final settings = context.read<AppSettings>();
      _muted = settings.muted;
      preloaded.setVolume(_muted ? 0 : 1);
      if (preloadDetail != null) {
        await PlaybackHelpers.skipIntro(
          preloaded,
          enabled: settings.skipIntro,
          fallbackDurationSec: preloadDetail.durationSec,
        );
      }
      if (seq != _loadSeq || !_canRun) {
        try {
          await preloaded.dispose();
        } catch (_) {}
        return;
      }
      if (!mounted) return;
      _controller = preloaded;
      final dur = PlaybackHelpers.effectiveDuration(
        preloaded,
        fallbackSec: preloadDetail?.durationSec ?? 0,
      );
      setState(() {
        _pageLoading = false;
        _titleText = preloadDetail?.title ?? item.title;
        _totalTime.value = PlaybackHelpers.fmtDuration(dur);
        _baseSpeed = preloadStream != null
            ? _estimateBaseSpeed(preloadStream.height)
            : 1500;
      });
      _sliderValue.value = 0;
      _currentTime.value = '0:00';
      if (preloadDetail != null) {
        _translateTitleOnly(preloadDetail.title);
      }
      await preloaded.play();
      if (seq != _loadSeq || !_canRun) {
        if (identical(_controller, preloaded)) _controller = null;
        await preloaded.dispose();
        return;
      }
      _recordWatch(item);
      _startProgressTimer();
      WakelockPlus.enable();
      if (mounted) setState(() {});

      if (_multiPreload) {
        if (_preloadController2 != null && _preloadIndex2 == index + 1) {
          _preloadController = _preloadController2;
          _preloadIndex = _preloadIndex2;
          _preloadStream = _preloadStream2;
          _preloadRetries = _preloadRetries2;
          _preloadController2 = _preloadController3;
          _preloadIndex2 = _preloadIndex3;
          _preloadStream2 = _preloadStream3;
          _preloadRetries2 = _preloadRetries3;
          _preloadController3 = _preloadController4;
          _preloadIndex3 = _preloadIndex4;
          _preloadStream3 = _preloadStream4;
          _preloadRetries3 = _preloadRetries4;
          _preloadController4 = null;
          _preloadIndex4 = null;
          _preloadStream4 = null;
          _preloadRetries4 = 0;
        } else {
          // ignore: unawaited_futures
          _preloadNext(index + 1);
        }
        final n = _preloadSlotCount;
        if (n >= 2) unawaited(_preloadNext2(index + 2));
        if (n >= 3) unawaited(_preloadNext3(index + 3));
        if (n >= 4) unawaited(_preloadNext4(index + 4));
      }

      // Clean up old detail cache to prevent memory growth
      _cleanupDetailCache(index);
      return;
    }

    _disposePreload();

    final previous = _controller;
    final previousIndex = _currentIndex;
    final previousHeight = _currentStreamHeight;
    _controller = null;
    if (previous != null) {
      await _freezePrevious(previous, previousIndex, previousHeight);
    }

    if (seq != _loadSeq || !_canRun || !mounted) return;
    setState(() {
      _pageLoading = true;
      _currentIndex = index;
      _titleText = item.title;
      _totalTime.value = '0:00';
      _speedLabel.value = '';
    });
    _sliderValue.value = 0;
    _currentTime.value = '0:00';

    VideoDetail detail;
    try {
      if (_detailCache.containsKey(index)) {
        detail = _detailCache[index]!;
      } else {
        detail = await _fetchDetail(item.url);
        _detailCache[index] = detail;
      }
    } catch (e) {
      if (!mounted || seq != _loadSeq) return;
      setState(() => _pageLoading = false);
      PlaybackHelpers.toast(
        context,
        '详情加载失败：${PlaybackHelpers.friendlyError(e)}',
      );
      _scheduleSkipToNext(index);
      return;
    }
    if (seq != _loadSeq || !_canRun || !mounted) return;

    if (detail.countryBlocked) {
      setState(() => _pageLoading = false);
      PlaybackHelpers.toast(context, '该视频在当前地区不可用（不自动跳过）');
      return;
    }
    if (detail.unavailable) {
      setState(() => _pageLoading = false);
      PlaybackHelpers.toast(context, '视频标记为不可用（不自动跳过）');
      return;
    }

    final settings = context.read<AppSettings>();

    // Plan A: real streams first; empty streams → in-app WebView page.
    if (detail.prefersBrowserPlayer || detail.streams.isEmpty) {
      final page = detail.browserPlaybackUrl?.trim().isNotEmpty == true
          ? detail.browserPlaybackUrl!.trim()
          : item.url;
      await _playInAppBrowser(
        index: index,
        item: item,
        pageUrl: page,
        title: detail.title.isNotEmpty ? detail.title : item.title,
        live: false,
        seq: seq,
        detail: detail,
      );
      return;
    }

    final cap = _effectiveQualityCap;
    final candidates = PlaybackHelpers.streamCandidates(detail, cap);
    if (candidates.isEmpty) {
      final page = detail.browserPlaybackUrl?.trim().isNotEmpty == true
          ? detail.browserPlaybackUrl!.trim()
          : item.url;
      await _playInAppBrowser(
        index: index,
        item: item,
        pageUrl: page,
        title: detail.title.isNotEmpty ? detail.title : item.title,
        live: false,
        seq: seq,
        detail: detail,
      );
      return;
    }

    _currentDetail = detail;

    VideoPlayerController? player;
    StreamQuality? stream;
    final playerDeadline = DateTime.now().add(const Duration(seconds: 18));
    for (final c in candidates) {
      if (seq != _loadSeq || !_canRun) {
        await player?.dispose();
        return;
      }
      final next = _createNetworkPlayer(c, detail.url);
      try {
        final remaining = playerDeadline.difference(DateTime.now());
        if (remaining.inMilliseconds <= 0) {
          _initializingControllers.remove(next);
          await next.dispose();
          break;
        }
        await next.initialize().timeout(
              remaining < const Duration(seconds: 12)
                  ? remaining
                  : const Duration(seconds: 12),
            );
        _initializingControllers.remove(next);
        if (PlaybackHelpers.isLikelyPreview(
          next,
          detail,
          siteId: widget.site?.id,
          isLive: widget.site?.kind == SiteKind.live,
        )) {
          await next.dispose();
          continue;
        }
        player = next;
        stream = c;
        break;
      } catch (_) {
        _initializingControllers.remove(next);
        try {
          await next.dispose();
        } catch (_) {}
      }
    }
    if (player == null || stream == null) {
      // Stream URLs failed → fall back to in-app WebView of the detail page.
      if (mounted && seq == _loadSeq) {
        final page = detail.browserPlaybackUrl?.trim().isNotEmpty == true
            ? detail.browserPlaybackUrl!.trim()
            : (detail.url.startsWith('http') ? detail.url : item.url);
        await _playInAppBrowser(
          index: index,
          item: item,
          pageUrl: page,
          title: detail.title.isNotEmpty ? detail.title : item.title,
          live: false,
          seq: seq,
          detail: detail,
        );
        return;
      }
      return;
    }
    if (seq != _loadSeq || !_canRun) {
      await player.dispose();
      return;
    }

    if (!mounted) {
      await player.dispose();
      return;
    }
    _currentStreamHeight = stream.height;
    _stallTicks = 0;
    _stallLoweredForItem = false;
    _stallArmedAfterMs = DateTime.now().millisecondsSinceEpoch + 4000;
    _muted = settings.muted;
    player.setVolume(_muted ? 0 : 1);
    _baseSpeed = _estimateBaseSpeed(stream.height);

    await PlaybackHelpers.skipIntro(
      player,
      enabled: settings.skipIntro,
      fallbackDurationSec: detail.durationSec,
    );

    if (seq != _loadSeq || !_canRun) {
      await player.dispose();
      return;
    }
    final ready = player;
    _controller = ready;
    final effDur = PlaybackHelpers.effectiveDuration(
      ready,
      fallbackSec: detail.durationSec,
    );
    setState(() {
      _pageLoading = false;
      _titleText = detail.title;
      _totalTime.value = PlaybackHelpers.fmtDuration(effDur);
    });
    _translateTitleOnly(detail.title);
    await ready.play();
    if (seq != _loadSeq || !_canRun) {
      if (identical(_controller, ready)) _controller = null;
      await ready.dispose();
      return;
    }
    if (_multiPreload) {
      final n = _preloadSlotCount;
      unawaited(_preloadNext(index + 1));
      if (n >= 2) unawaited(_preloadNext2(index + 2));
      if (n >= 3) unawaited(_preloadNext3(index + 3));
      if (n >= 4) unawaited(_preloadNext4(index + 4));
    } else {
      unawaited(_preloadNext(index + 1));
      unawaited(_prefetchDetail(index + 2));
    }
    _recordWatch(item);
    _startProgressTimer();
    WakelockPlus.enable();
    if (mounted) setState(() {});

    CacheManager.onVideoPlayed();
    _cleanupDetailCache(index);
  }

  /// Play a site page inside App WKWebView (Stripchat-style), not system Safari.
  Future<void> _playInAppBrowser({
    required int index,
    required VideoItem item,
    required String pageUrl,
    required String title,
    required bool live,
    required int seq,
    VideoDetail? detail,
    bool stripchat = false,
  }) async {
    _disposePreload();
    await _disposeController();
    if (seq != _loadSeq || !_canRun || !mounted) return;
    final url = pageUrl.trim();
    if (!url.startsWith('http')) {
      setState(() {
        _pageLoading = false;
        _browserLiveUrl = null;
        _browserIsStripchat = false;
      });
      PlaybackHelpers.toast(context, '无法打开页面地址');
      return;
    }
    _currentIndex = index;
    _currentDetail = detail;
    _browserLiveUrl = url;
    // Both providers can restore a promotional/full-site shell after an iOS
    // background round-trip. Keep their WebViews in controlled player mode.
    final focusLive = live &&
        (widget.site?.isChaturbate == true || widget.site?.isStripchat == true);
    _browserIsStripchat = focusLive;
    _titleText = title;
    _totalTime.value = live ? 'LIVE' : '-';
    _speedLabel.value = live ? '' : '网页';
    _sliderValue.value = 0;
    _currentTime.value = live ? 'LIVE' : '0:00';
    setState(() => _pageLoading = false);
    _recordWatch(item);
    WakelockPlus.enable();
    if (live || stripchat) {
      _startLiveWatchdog();
    } else {
      _liveWatchdog?.cancel();
      _liveWatchdog = null;
    }
  }

  /// Soft-recover stalled Stripchat/WebView live without full page reload.
  void _startLiveWatchdog() {
    _liveWatchdog?.cancel();
    _liveWatchdog = Timer.periodic(const Duration(seconds: 12), (_) {
      if (!_canRun || _browserLiveUrl == null) {
        _liveWatchdog?.cancel();
        _liveWatchdog = null;
        return;
      }
      if (!_appInForeground) return;
      unawaited(StripchatLiveView.kickPlayback());
    });
  }

  /// Drop items far from the play head so memory stays bounded.
  void _trimItemsWindow() {
    if (_items.length <= _maxLiveItems) return;
    final i = _currentIndex.clamp(0, _items.length - 1);
    final half = _maxLiveItems ~/ 2;
    var start = (i - half).clamp(0, _items.length);
    var end = (start + _maxLiveItems).clamp(0, _items.length);
    if (end - start < _maxLiveItems) {
      start = (end - _maxLiveItems).clamp(0, end);
    }
    if (start == 0 && end == _items.length) return;
    final kept = _items.sublist(start, end);
    _items
      ..clear()
      ..addAll(kept);
    _currentIndex = (i - start).clamp(0, _items.length - 1);
    _seen
      ..clear()
      ..addAll(kept.map((e) => e.viewkey));
    // Rebase detail cache keys to new indices (drop far entries).
    final rebased = <int, VideoDetail>{};
    for (final e in _detailCache.entries) {
      final ni = e.key - start;
      if (ni >= 0 && ni < _items.length) rebased[ni] = e.value;
    }
    _detailCache
      ..clear()
      ..addAll(rebased);
    if (_pageCtrl.hasClients) {
      try {
        _pageCtrl.jumpToPage(_currentIndex);
      } catch (_) {}
    }
  }

  Future<void> _disposeController({
    VideoPlayerController? exclude,
  }) async {
    _progressTimer?.cancel();
    _progressTimer = null;
    final c = _controller;
    if (c == null || identical(c, exclude)) return;
    // Detach only if field still points here (avoid racing a newer play).
    if (identical(_controller, c)) {
      _controller = null;
    }
    // Always dispose the detached handle — never skip by seqGuard (leak).
    try {
      await c.pause();
    } catch (_) {}
    try {
      await c.dispose();
    } catch (_) {}
  }

  void _startProgressTimer() {
    final ctrl = _controller;
    if (ctrl == null || !_canRun) return;
    _progressTimer?.cancel();
    _lastBufferedMs = 0;
    _lastTickMs = 0;
    _lastPosMs = 0;
    _smoothedSpeedKbps = 0;
    _speedSamples = 0;
    // 200ms feels smoother than 400ms; skip UI while user is dragging.
    _progressTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!_canRun ||
          !identical(ctrl, _controller) ||
          !ctrl.value.isInitialized) {
        _progressTimer?.cancel();
        _progressTimer = null;
        return;
      }
      // Skip update while seeking, but keep timer alive
      if (_seeking) return;

      final pos = ctrl.value.position;
      final dur = PlaybackHelpers.effectiveDuration(
        ctrl,
        fallbackSec: _currentDetail?.durationSec ?? 0,
      );
      if (dur.inMilliseconds <= 0) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      final ranges = ctrl.value.buffered;
      final bufMs =
          ranges.isEmpty ? 0.0 : ranges.last.end.inMilliseconds.toDouble();
      final posMs = pos.inMilliseconds.toDouble();
      if (_lastTickMs > 0) {
        final dMs = now - _lastTickMs;
        final dBuf = bufMs - _lastBufferedMs;
        final dPlayed = posMs - _lastPosMs;
        final downloaded = (dBuf + dPlayed).clamp(0.0, double.infinity);
        if (dMs > 0 && downloaded > 0) {
          final ratio = (downloaded / dMs).clamp(0.0, 3.0);
          final sample = (_baseSpeed * ratio).clamp(0, 12000).toDouble();
          // Warm up and use a slower rise so one buffer burst cannot jump the label.
          _speedSamples++;
          if (_speedSamples >= 3) {
            if (_smoothedSpeedKbps <= 0) {
              _smoothedSpeedKbps = sample.clamp(0, 1200);
            } else {
              final weight = sample > _smoothedSpeedKbps ? 0.08 : 0.24;
              _smoothedSpeedKbps += (sample - _smoothedSpeedKbps) * weight;
            }
          }
          if (_speedSamples >= 3) {
            final speed = _smoothedSpeedKbps.round().clamp(0, 20000);
            final label = '$speed Kbps';
            if (label != _lastSpeedLabel) {
              _lastSpeedLabel = label;
              _speedLabel.value = label;
            }
          }
        }
        // Stall: playing but position barely advances.
        final isPlaying = ctrl.value.isPlaying;
        final nearEnd = posMs >= dur.inMilliseconds - 800;
        final armed = now >= _stallArmedAfterMs;
        if (armed &&
            isPlaying &&
            !nearEnd &&
            dMs >= 150 &&
            dPlayed < 40 &&
            posMs > 2000) {
          _stallTicks++;
        } else if (dPlayed >= 80) {
          _stallTicks = 0;
        }
        if (_stallTicks >= 14) {
          _stallTicks = 0;
          // ignore: unawaited_futures
          _maybeAutoLowerQuality();
        }
      }
      _lastBufferedMs = bufMs;
      _lastTickMs = now;
      _lastPosMs = posMs;
      _sliderValue.value = (pos.inMilliseconds / dur.inMilliseconds).clamp(
        0.0,
        1.0,
      );
      _currentTime.value = PlaybackHelpers.fmtDuration(pos);
      if (dur.inMilliseconds > 0) {
        final t = PlaybackHelpers.fmtDuration(dur);
        if (t != _totalTime.value) {
          _totalTime.value = t;
        }
      }
    });
  }

  void _onPageChanged(int page) {
    if (_resyncingPage) return;
    if (page == _currentIndex) return;
    if (_browserLiveUrl != null) {
      _liveWatchdog?.cancel();
      _liveWatchdog = null;
    }
    // Stall auto-lower is per-item only.
    _sessionQualityCap = null;
    _stallLoweredForItem = false;
    _stallTicks = 0;
    _prunePageState(page);
    // Hard switch: dispose old, play new only
    _playIndex(page);
    if (page >= _items.length - 3) {
      _loadMore();
    }
  }

  Future<void> _translateTitleOnly(String title) async {
    if (title.isEmpty) return;
    if (widget.site?.kind == SiteKind.live) return;
    // Already Chinese (e.g. 中 tab) — keep as-is.
    if (RegExp(r'[\u4e00-\u9fff]').hasMatch(title)) {
      if (mounted) setState(() => _titleText = title);
      return;
    }
    try {
      final zh = await context.read<Translator>().enToZh(title);
      if (!mounted || zh.isEmpty) return;
      setState(() => _titleText = zh);
      // Also update list item so next swipe shows Chinese immediately.
      final i = _currentIndex;
      if (i >= 0 && i < _items.length && _items[i].title == title) {
        _items[i] = _items[i].copyWith(title: zh);
      }
    } catch (_) {}
  }

  /// Batch-translate newly loaded English titles; prioritize near current index.
  Future<void> _translateItemsRange(int start) async {
    if (start < 0 || start >= _items.length) return;
    if (widget.kind == VideoFeedKind.zhong || widget.site?.kind == SiteKind.live) {
      return;
    }
    try {
      final slice = _items.sublist(start);
      final urls = slice.map((e) => e.url).toList();
      final titles = slice.map((e) => e.title).toList();
      // Translate current neighborhood first (snappier UI), then the rest.
      final order = List<int>.generate(titles.length, (i) => i);
      order.sort((a, b) {
        final da = ((start + a) - _currentIndex).abs();
        final db = ((start + b) - _currentIndex).abs();
        return da.compareTo(db);
      });
      final orderedTitles = [for (final i in order) titles[i]];
      final zhOrdered = await context.read<Translator>().batchEnToZh(
            orderedTitles,
          );
      if (!mounted) return;
      final zh = List<String>.filled(titles.length, '');
      for (var k = 0; k < order.length; k++) {
        zh[order[k]] = zhOrdered[k];
      }
      setState(() {
        for (var i = 0; i < zh.length; i++) {
          final idx = start + i;
          if (idx >= _items.length) break;
          if (_items[idx].url != urls[i]) continue;
          if (zh[i].isEmpty || zh[i] == titles[i]) continue;
          _items[idx] = _items[idx].copyWith(title: zh[i]);
          if (idx == _currentIndex &&
              (_titleText == titles[i] || _titleText.isEmpty)) {
            _titleText = zh[i];
          }
        }
      });
    } catch (_) {}
  }

  int _estimateBaseSpeed(int height) {
    if (height >= 1080) return 4500;
    if (height >= 720) return 2800;
    if (height >= 480) return 1500;
    if (height >= 360) return 900;
    return 600;
  }

  /// Drag/tap preview only — never touch the player (prevents snap-back).
  void _onSeekPreview(double v) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final durMs = c.value.duration.inMilliseconds;
    if (durMs <= 0) return;
    final pos = (durMs * v).round();
    _sliderValue.value = v.clamp(0.0, 1.0);
    _currentTime.value = PlaybackHelpers.fmtDuration(
      Duration(milliseconds: pos),
    );
  }

  /// Seek after drag/tap ends; keep [_seeking] until player position settles.
  Future<void> _onSeekCommit(double v) async {
    // Buffer refill after seek is normal — not a stall.
    _stallTicks = 0;
    _stallArmedAfterMs = DateTime.now().millisecondsSinceEpoch + 3000;
    final c = _controller;
    if (c == null || !c.value.isInitialized) {
      _seeking = false;
      return;
    }
    final durMs = c.value.duration.inMilliseconds;
    if (durMs <= 0) {
      _seeking = false;
      return;
    }
    final target = v.clamp(0.0, 1.0);
    final posMs = (durMs * target).round();
    _seeking = true;
    _sliderValue.value = target;
    _currentTime.value = PlaybackHelpers.fmtDuration(
      Duration(milliseconds: posMs),
    );
    try {
      await c.seekTo(Duration(milliseconds: posMs));
      // Brief hold so progress timer doesn't overwrite with stale position
      await Future<void>.delayed(const Duration(milliseconds: 120));
      if (!mounted || !identical(c, _controller)) return;
      final p = c.value.position;
      final d = c.value.duration;
      if (d.inMilliseconds > 0) {
        _sliderValue.value = (p.inMilliseconds / d.inMilliseconds).clamp(
          0.0,
          1.0,
        );
        _currentTime.value = PlaybackHelpers.fmtDuration(p);
      }
    } catch (_) {
    } finally {
      if (mounted) _seeking = false;
    }
  }

  void _toggleMute() {
    _muted = !_muted;
    _controller?.setVolume(_muted ? 0 : 1);
    if (_browserLiveUrl != null) {
      unawaited(StripchatLiveView.setMuted(_muted));
    }
    context.read<AppSettings>().setMuted(_muted);
    setState(() {});
  }

  void _fastForward() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final currentPos = c.value.position;
    final duration = c.value.duration;
    final newPos = currentPos + const Duration(seconds: 30);

    _seeking = true;
    if (newPos < duration) {
      c.seekTo(newPos).then((_) {
        if (mounted) {
          Future.delayed(const Duration(milliseconds: 120), () {
            if (mounted) _seeking = false;
          });
        }
      });
    } else {
      c.seekTo(duration).then((_) {
        if (mounted) {
          Future.delayed(const Duration(milliseconds: 120), () {
            if (mounted) _seeking = false;
          });
        }
      });
    }
  }

  Future<void> _maybeAutoLowerQuality() async {
    if (!mounted || _stallLowering || _stallLoweredForItem) return;
    final enabled = _settings?.autoLowerOnStall ??
        context.read<AppSettings>().autoLowerOnStall;
    if (!enabled) return;
    final detail = _currentDetail;
    if (detail == null || detail.streams.length < 2) return;
    final heights =
        detail.streams.map((s) => s.height).where((h) => h > 0).toSet();
    if (heights.length < 2) return; // single fake stream (e.g. 中源) — skip
    final curH = _currentStreamHeight;
    if (curH <= 0) return;
    final lower = detail.streams
        .where((s) => s.height > 0 && s.height < curH)
        .toList()
      ..sort((a, b) => b.height.compareTo(a.height));
    if (lower.isEmpty) return;

    final target = lower.first;
    _stallLowering = true;
    _stallLoweredForItem = true;
    _sessionQualityCap = target.height;
    try {
      if (mounted) {
        PlaybackHelpers.toast(
          context,
          '卡顿，已自动降至 ${target.label}（仅本条）',
          duration: const Duration(seconds: 2),
        );
      }
      if (mounted) await _playIndex(_currentIndex);
    } finally {
      _stallLowering = false;
    }
  }

  void _openPlayerSettings() {
    final detail = _currentDetail;
    final heights = <int>[];
    if (detail != null) {
      for (final s in detail.streams) {
        if (s.height > 0) heights.add(s.height);
      }
    }
    showPlayerSettingsSheet(
      context,
      qualityHeights: heights.isEmpty ? null : heights,
      onQualityChanged: () {
        _sessionQualityCap = null;
        if (mounted) _playIndex(_currentIndex);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFFFF6B35)),
        ),
      );
    }
    if (_items.isEmpty) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _error ?? '内容不存在(404)',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFFF6B35),
                  ),
                  onPressed: () {
                    setState(() {
                      _loading = true;
                      _error = null;
                    });
                    _active = true;
                    _loadMore();
                  },
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final immersive = context.select<PlayerChrome, bool>((c) => c.immersive);

    final chrome = context.read<PlayerChrome>();
    return PopScope(
      canPop: _allowPop || defaultTargetPlatform == TargetPlatform.iOS,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (immersive) {
          // ignore: unawaited_futures
          chrome.exitFullscreen().then((_) {
            _autoRotate?.syncLandscapeMode(false, fromUser: true);
            if (mounted) {
              setState(() {});
              _schedulePageResync();
            }
          });
          return;
        }
        // ignore: unawaited_futures
        _exitAfterStopping();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: chrome.wrapBody(
          context,
          GestureDetector(
            onTap: () {
              final c = _controller;
              if (c == null || !c.value.isInitialized) return;
              if (c.value.isPlaying) {
                c.pause();
              } else {
                c.play();
              }
            },
            onLongPressStart: (_) => _controller?.setPlaybackSpeed(3.0),
            onLongPressEnd: (_) => _controller?.setPlaybackSpeed(1.0),
            child: VideoPlayerPage(
              items: _items,
              currentIndex: _currentIndex,
              controller: _controller,
              pageLoading: _pageLoading,
              muted: _muted,
              immersive: immersive,
              pageCtrl: _pageCtrl,
              sliderValue: _sliderValue,
              currentTime: _currentTime,
              totalTime: _totalTime,
              titleText: _titleText,
              speedLabel: _speedLabel,
              browserLiveUrl: _browserLiveUrl,
              browserIsStripchat: _browserIsStripchat,
              onPageChanged: _onPageChanged,
              onMute: _toggleMute,
              onFastForward: _fastForward,
              onFullscreen: _toggleFullscreen,
              onBack: _exitAfterStopping,
              onOpenSettings: _openPlayerSettings,
              onSeekPreview: _onSeekPreview,
              onSeekStart: () => _seeking = true,
              onSeekEnd: _onSeekCommit,
            ),
          ),
        ),
      ),
    );
  }

  /// Clean up detail cache that's far from current position to prevent memory growth
  void _cleanupDetailCache(int currentIndex) {
    _prunePageState(currentIndex);
  }

  Future<void> _freezePrevious(
    VideoPlayerController controller,
    int index,
    int streamHeight,
  ) async {
    final stale = _frozenController;
    _frozenController = null;
    _frozenIndex = null;
    if (stale != null && !identical(stale, controller)) {
      try {
        await stale.pause();
      } catch (_) {}
      try {
        await stale.dispose();
      } catch (_) {}
    }
    try {
      await controller.setVolume(0);
      await controller.pause();
    } catch (_) {}
    if (!_canRun) {
      try {
        await controller.dispose();
      } catch (_) {}
      return;
    }
    _frozenController = controller;
    _frozenIndex = index;
    _frozenStreamHeight = streamHeight;
  }

  void _prunePageState(int currentIndex) {
    final lastFuturePage = currentIndex + _preloadSlotCount + 1;
    _detailCache.removeWhere(
      (index, _) => index < currentIndex - 1 || index > lastFuturePage,
    );
    _retried.removeWhere(
      (index) => index < currentIndex - 1 || index > lastFuturePage,
    );
  }
}

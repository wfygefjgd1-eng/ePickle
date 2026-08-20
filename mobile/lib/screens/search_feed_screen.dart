import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/video_item.dart';
import '../services/generic_site_api.dart';
import '../services/huangguo_api.dart';
import '../services/mitao_api.dart';
import '../services/phub_api.dart';
import '../services/translator.dart';
import '../services/xvideos_api.dart';
import '../services/app_settings.dart';
import '../services/app_route_observer.dart';
import '../services/auto_rotate_controller.dart';
import '../services/player_chrome.dart';
import '../services/source_catalog.dart';
import '../utils/http_headers.dart';
import '../utils/playback_helpers.dart';
import '../widgets/player_settings_sheet.dart';

/// Which backend to use for detail / headers.
enum SearchSource { ph, x, zhong, huangguo, generic }

/// Vertical swipe player for search results.
/// Single active player + one silent pre-buffered next-video controller
/// (TikTok-style) for instant swipe; preloads next detail; can append pages via [onLoadMore].
class SearchFeedScreen extends StatefulWidget {
  const SearchFeedScreen({
    super.key,
    required this.items,
    required this.source,
    this.initialIndex = 0,
    this.title = '播放',
    this.onLoadMore,
    this.site,
  });

  final List<VideoItem> items;
  final SearchSource source;
  final int initialIndex;
  final String title;

  /// Returns newly appended items (may be empty when no more).
  final Future<List<VideoItem>> Function()? onLoadMore;

  /// Required when [source] is [SearchSource.generic].
  final SiteDef? site;

  @override
  State<SearchFeedScreen> createState() => _SearchFeedScreenState();
}

class _SearchFeedScreenState extends State<SearchFeedScreen>
    with WidgetsBindingObserver, RouteAware {
  late final PageController _pageCtrl;
  late final List<VideoItem> _items;
  late int _index;
  int _seq = 0;

  VideoPlayerController? _controller;
  VideoPlayerController? _frozenController;
  int? _frozenIndex;
  int _frozenStreamHeight = 0;
  bool _pageLoading = false;
  bool _loadingMore = false;
  bool _muted = false;
  bool _seeking = false;
  String _titleText = '';
  String _speedLabel = '';
  double _smoothedSpeedKbps = 0;
  int _speedSamples = 0;
  String _totalTime = '0:00';
  Timer? _progressTimer;
  Timer? _retryTimer;
  Timer? _skipTimer;
  final ValueNotifier<double> _slider = ValueNotifier(0);
  final ValueNotifier<String> _curTime = ValueNotifier('0:00');

  final Map<int, VideoDetail> _detailCache = {};

  /// 已展开成连续剧集的系列（key = 系列详情 url），防止重复插入。
  final Set<String> _expandedSeries = {};

  /// 列表结构版本：插入剧集条目后递增，使在途预取结果作废。
  int _itemsEpoch = 0;
  int? _prefetchingIndex;
  int _preloadWaveSeq = 0;
  int _preloadWaveIndex = -1;
  PlayerChrome? _chrome;
  AutoRotateController? _autoRotate;
  AppSettings? _settings;

  bool _showExitButton = false;
  bool _speedBoostActive = false;
  bool _manualPaused = false;
  double? _dragStartX;
  Duration? _dragStartPosition;
  Duration? _dragTargetPosition;
  String _seekPreviewText = '';
  bool _resumePlaybackOnRouteReturn = false;
  PageRoute<dynamic>? _route;

  /// Shared iOS/Android lookahead pool.
  VideoPlayerController? _preloadController;
  int? _preloadIndex;
  StreamQuality? _preloadStream;
  int _preloadRetries = 0;

  VideoPlayerController? _preloadController2;
  int? _preloadIndex2;
  StreamQuality? _preloadStream2;
  int _preloadRetries2 = 0;

  VideoPlayerController? _preloadController3;
  int? _preloadIndex3;
  StreamQuality? _preloadStream3;
  int _preloadRetries3 = 0;

  int _currentStreamHeight = 0;
  int? _sessionQualityCap;
  int _stallTicks = 0;
  bool _stallLowering = false;
  bool _stallLoweredForItem = false;
  int _stallArmedAfterMs = 0;
  bool _resyncingPage = false;
  bool _appInForeground = true;
  bool _resumePlaybackOnForeground = false;
  bool _allowPop = false;
  bool _exiting = false;
  final Set<VideoPlayerController> _initializingControllers = {};

  late final Map<String, String> _headers = _buildHeaders();

  int get _effectiveQualityCap {
    if (_sessionQualityCap != null) return _sessionQualityCap!;
    return _settings?.qualityCap ?? 0;
  }

  /// Keep the decoder budget identical on iOS and Android.
  int get _preloadSlotCount => PlaybackHelpers.preloadSlotCount;

  bool get _multiPreload => _preloadSlotCount > 1;
  bool get _canRun => mounted && _appInForeground;

  Map<String, String> _buildHeaders() {
    switch (widget.source) {
      case SearchSource.x:
        return AppHttpHeaders.forMediaUrl(
          null,
          pageUrl: 'https://www.xvideos.com',
        );
      case SearchSource.zhong:
        return {
          ...AppHttpHeaders.forMediaUrl(null, pageUrl: 'https://mitaohk.com'),
          'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
        };
      case SearchSource.ph:
        return AppHttpHeaders.forMediaUrl(
          null,
          pageUrl: 'https://www.pornhub.com',
        );
      case SearchSource.huangguo:
        final s = widget.site;
        final base = (_settings?.huangguoDomain ??
                s?.primaryHost ??
                HuangGuoApi.defaultBase)
            .replaceAll(RegExp(r'/$'), '');
        return {
          ...AppHttpHeaders.forMediaUrl(null, pageUrl: base),
          'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
        };
      case SearchSource.generic:
        final s = widget.site;
        if (s != null) {
          final base = s.primaryHost.replaceAll(RegExp(r'/$'), '');
          return AppHttpHeaders.forMediaUrl(null, pageUrl: base);
        }
        return AppHttpHeaders.browser;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _chrome ??= context.read<PlayerChrome>();
    final route = ModalRoute.of(context);
    if (route is PageRoute<dynamic> && !identical(route, _route)) {
      if (_route != null) {
        appRouteObserver.unsubscribe(this);
      }
      _route = route;
      appRouteObserver.subscribe(this, route);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _muted = context.read<AppSettings>().muted;
    _items = List<VideoItem>.from(widget.items);
    // Empty list: clamp(0, -1) throws; keep index 0 safely.
    _index =
        _items.isEmpty ? 0 : widget.initialIndex.clamp(0, _items.length - 1);
    _pageCtrl = PageController(initialPage: _index);
    _titleText = _items.isEmpty ? '' : _items[_index].title;
    _autoRotate = AutoRotateController(onAction: _onAutoRotate);
    _settings = context.read<AppSettings>();
    _autoRotate!.enabled = _settings!.autoRotate;
    _settings!.addListener(_onSettingsChanged);
    _autoRotate!.start();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_canRun) _playIndex(_index);
    });
  }

  void _onSettingsChanged() {
    final s = _settings;
    if (!mounted || s == null) return;
    _autoRotate?.enabled = s.autoRotate;
  }

  @override
  void didPushNext() {
    _resumePlaybackOnRouteReturn =
        (_controller?.value.isPlaying ?? false) || _pageLoading;
    unawaited(_pausePlaybackForRouteChange(releasePlayers: false));
  }

  @override
  void didPopNext() {
    if (!_resumePlaybackOnRouteReturn || !mounted) return;
    _resumePlaybackOnRouteReturn = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _canRun) {
        startPlaying();
      }
    });
  }

  void startPlaying() {
    _resumePlaybackOnRouteReturn = false;
    if (!_appInForeground) return;
    final immersive = _chrome?.immersive ?? false;
    _autoRotate?.syncLandscapeMode(
      immersive,
      side: immersive ? _chrome?.landscapeSide : null,
    );
    _autoRotate?.listening = true;
    _autoRotate?.start();
    final c = _controller;
    if (c != null && c.value.isInitialized) {
      unawaited(c.play().then((_) {
        if (_canRun) _startTimer();
        _restartPreloading();
      }).catchError((_) {}));
      WakelockPlus.enable();
      return;
    }
    if (_items.isNotEmpty) {
      unawaited(_playIndex(_index.clamp(0, _items.length - 1)));
    }
  }

  Future<void> _pausePlaybackForRouteChange({
    required bool releasePlayers,
  }) async {
    _seq++;
    _progressTimer?.cancel();
    _progressTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    _skipTimer?.cancel();
    _skipTimer = null;
    _cancelBackgroundWork();
    final current = _controller;
    _autoRotate?.syncLandscapeMode(false);
    _autoRotate?.listening = false;
    _autoRotate?.stop();
    try {
      if (current != null) {
        await current.setVolume(0);
        await current.pause();
      }
    } catch (_) {}
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
    WakelockPlus.disable();
    if (releasePlayers) {
      _controller = null;
    }
    if (releasePlayers && current != null) {
      try {
        await current.dispose();
      } catch (_) {}
    }
  }

  void _onAutoRotate(AutoRotateAction action, DeviceOrientation? side) {
    final chrome = _chrome;
    if (chrome == null || !mounted) {
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
        }).catchError((_) {});
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
        }).catchError((_) {});
    }
  }

  @override
  void dispose() {
    stopPlaybackImmediately();
    _settings?.removeListener(_onSettingsChanged);
    _settings = null;
    _autoRotate?.dispose();
    _autoRotate = null;
    if (_route != null) {
      appRouteObserver.unsubscribe(this);
      _route = null;
    }
    try {
      _chrome?.ensurePortraitChrome();
    } catch (_) {}
    WidgetsBinding.instance.removeObserver(this);
    _progressTimer?.cancel();
    _retryTimer?.cancel();
    _skipTimer?.cancel();
    _slider.dispose();
    _curTime.dispose();
    _pageCtrl.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  void stopPlaybackImmediately() {
    _appInForeground = false;
    _resumePlaybackOnRouteReturn = false;
    _resumePlaybackOnForeground = false;
    _seq++;
    _progressTimer?.cancel();
    _progressTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    _skipTimer?.cancel();
    _skipTimer = null;
    _autoRotate?.syncLandscapeMode(false);
    _autoRotate?.listening = false;
    _autoRotate?.stop();

    final players = <VideoPlayerController>[
      if (_controller != null) _controller!,
      if (_frozenController != null) _frozenController!,
      if (_preloadController != null) _preloadController!,
      if (_preloadController2 != null) _preloadController2!,
      if (_preloadController3 != null) _preloadController3!,
      ..._initializingControllers,
    ];
    _controller = null;
    _frozenController = null;
    _frozenIndex = null;
    _preloadController = null;
    _preloadIndex = null;
    _preloadStream = null;
    _preloadRetries = 0;
    _preloadController2 = null;
    _preloadIndex2 = null;
    _preloadStream2 = null;
    _preloadRetries2 = 0;
    _preloadController3 = null;
    _preloadIndex3 = null;
    _preloadStream3 = null;
    _preloadRetries3 = 0;
    _initializingControllers.clear();
    for (final player in players.toSet()) {
      unawaited(_mutePauseDispose(player));
    }
    WakelockPlus.disable();
  }

  Future<void> _mutePauseDispose(VideoPlayerController player) async {
    try {
      await player.setVolume(0);
    } catch (_) {}
    try {
      await player.pause();
    } catch (_) {}
    try {
      await player.dispose();
    } catch (_) {}
  }

  void _disposePreloadSync() {
    void drop(VideoPlayerController? c) {
      if (c == null) return;
      // ignore: unawaited_futures
      c.pause().catchError((_) {}).whenComplete(() {
        try {
          c.dispose();
        } catch (_) {}
      });
    }

    drop(_preloadController);
    _preloadController = null;
    _preloadIndex = null;
    _preloadStream = null;
    _preloadRetries = 0;
    drop(_preloadController2);
    _preloadController2 = null;
    _preloadIndex2 = null;
    _preloadStream2 = null;
    _preloadRetries2 = 0;
    drop(_preloadController3);
    _preloadController3 = null;
    _preloadIndex3 = null;
    _preloadStream3 = null;
    _preloadRetries3 = 0;
  }

  Future<void> _exitAfterStopping() async {
    if (_exiting) return;
    _exiting = true;
    stopPlaybackImmediately();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    if (!mounted) return;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  VideoPlayerController _createNetworkPlayer(
    StreamQuality stream,
    String pageUrl,
  ) {
    final player = VideoPlayerController.networkUrl(
      Uri.parse(stream.url),
      httpHeaders: {
        ..._headers,
        ...AppHttpHeaders.forMediaUrl(
          stream.url,
          pageUrl: stream.referer ?? pageUrl,
        ),
        ...stream.headers,
      },
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
    );
    _initializingControllers.add(player);
    return player;
  }

  void _disposeInitializingPlayersSync() {
    final players = List<VideoPlayerController>.from(_initializingControllers);
    _initializingControllers.clear();
    for (final player in players) {
      unawaited(player.dispose().catchError((_) {}));
    }
  }

  void _restartPreloading() {
    if (!_canRun || _items.isEmpty) return;
    if (_preloadWaveSeq == _seq && _preloadWaveIndex == _index) {
      return;
    }
    _preloadWaveSeq = _seq;
    _preloadWaveIndex = _index;
    unawaited(_runPreloadCycle(_seq));
  }

  Future<void> _runPreloadCycle(int seq) async {
    final jobs = <Future<void>>[];
    for (var slot = 0; slot < _preloadSlotCount; slot++) {
      final index = _index + slot + 1;
      if (index >= _items.length) break;
      jobs.add(_warmPreloadSlot(seq, index, slot));
    }
    await Future.wait(jobs);
  }

  Future<void> _warmPreloadSlot(int seq, int index, int slot) async {
    try {
      if (seq != _seq || !_canRun || index >= _items.length) return;
      await _prefetchDetail(index);
      if (seq != _seq || !_canRun) return;
      if (slot == 0) {
        await _preloadNext(index);
      } else if (slot == 1) {
        await _preloadNext2(index);
      } else {
        await _preloadNext3(index);
      }
    } catch (_) {
    }
  }

  void _cancelBackgroundWork() {
    _progressTimer?.cancel();
    _progressTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    _skipTimer?.cancel();
    _skipTimer = null;
    context.read<PhubApi>().cancelRequests('app backgrounded');
    context.read<XvideosApi>().cancelRequests('app backgrounded');
    context.read<MitaoApi>().cancelRequests('app backgrounded');
    context.read<HuangGuoApi>().cancelRequests('app backgrounded');
    context.read<GenericSiteApi>().cancelRequests('app backgrounded');
    _disposeInitializingPlayersSync();
    _disposePreloadSync();
  }

  Future<void> _toggleFullscreen() async {
    final chrome = context.read<PlayerChrome>();
    try {
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
    } catch (_) {
      // Orientation/fullscreen channel can throw mid-transition; never let it
      // surface as an unhandled async error.
    }
  }

  /// See VideoFeedScreen: RotatedBox changes viewport → PageView offset drifts.
  void _schedulePageResync() {
    void pin() {
      if (!mounted || !_pageCtrl.hasClients || _items.isEmpty) return;
      final i = _index.clamp(0, _items.length - 1);
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
      _resumePlaybackOnForeground =
          (_controller?.value.isPlaying ?? false) || _pageLoading;
      _seq++;
      _autoRotate?.listening = false;
      _autoRotate?.stop();
      _cancelBackgroundWork();
      final controller = _controller;
      if (controller != null) {
        unawaited(controller.pause().catchError((_) {}));
      }
      WakelockPlus.disable();
      _stallTicks = 0;
      _stallArmedAfterMs = DateTime.now().millisecondsSinceEpoch + 8000;
    } else if (state == AppLifecycleState.resumed) {
      _appInForeground = true;
      _stallTicks = 0;
      _stallArmedAfterMs = DateTime.now().millisecondsSinceEpoch + 8000;
      _autoRotate?.listening = true;
      _autoRotate?.start();
      if (!_resumePlaybackOnForeground) return;
      _resumePlaybackOnForeground = false;
      startPlaying();
    }
  }

  Future<VideoDetail> _fetchDetail(String url, {VideoItem? item}) {
    switch (widget.source) {
      case SearchSource.x:
        return context.read<XvideosApi>().getVideoDetail(url);
      case SearchSource.zhong:
        return context.read<MitaoApi>().getVideoDetail(url);
      case SearchSource.huangguo:
        // 剧集条目已带直接播放地址，跳过详情抓取。
        final direct = item?.directUrl;
        if (direct != null && direct.isNotEmpty) {
          return Future.value(
            VideoDetail(
              url: item!.url,
              title: item.title,
              durationSec: 0,
              thumb: item.thumb,
              streams: [
                StreamQuality(width: 1280, height: 720, url: direct),
              ],
            ),
          );
        }
        return context.read<HuangGuoApi>().getVideoDetail(url);
      case SearchSource.ph:
        return context.read<PhubApi>().getVideoDetail(url);
      case SearchSource.generic:
        final s = widget.site;
        if (s != null) {
          return context.read<GenericSiteApi>().getVideoDetail(s, url);
        }
        return context.read<GenericSiteApi>().getCustomDetail(url);
    }
  }

  Future<void> _ensureMoreIfNearEnd(int page) async {
    if (widget.onLoadMore == null) return;
    if (_loadingMore) return;
    if (page < _items.length - 3) return;
    _loadingMore = true;
    try {
      final extra = await widget.onLoadMore!();
      if (!mounted || extra.isEmpty) return;
      final seen = <String>{for (final e in _items) e.viewkey};
      final add = <VideoItem>[];
      for (final e in extra) {
        if (seen.add(e.viewkey)) add.add(e);
      }
      if (add.isEmpty) return;
      setState(() {
        _items.addAll(add);
        // Soft cap search-feed list memory.
        const max = 200;
        if (_items.length > max) {
          final drop = _items.length - max;
          _items.removeRange(0, drop);
          _index = (_index - drop).clamp(0, _items.length - 1);
          // Rebased indices invalidate index-keyed state: a stale
          // _detailCache hit would play the wrong video's stream, and
          // preload/frozen slots alias the wrong items. Drop them all; they
          // re-arm on the next play/preload wave.
          _itemsEpoch++;
          _detailCache.clear();
          _retried.clear();
          _frozenController = null;
          _frozenIndex = null;
          _frozenStreamHeight = 0;
          _disposePreloadSync();
          if (_pageCtrl.hasClients) {
            try {
              _pageCtrl.jumpToPage(_index);
            } catch (_) {}
          }
        }
      });
    } catch (_) {
    } finally {
      _loadingMore = false;
    }
  }

  final Set<int> _retried = {};

  /// Auto-skip retries once per item, then parks on it with a toast — no
  /// endless skip loop on a dead feed.
  void _scheduleSkipToNext(int fromIndex) {
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
  }

  /// Failure-safe play: any error escaping the play path must never surface as
  /// an unhandled async error from a Timer/PageView callback.
  Future<void> _playIndex(int index) async {
    try {
      await _playIndexInner(index);
    } catch (e) {
      debugPrint('ePickle search _playIndex error: $e');
      if (mounted) {
        try {
          setState(() => _pageLoading = false);
        } catch (_) {}
      }
    }
  }

  Future<void> _playIndexInner(int index) async {
    if (!_canRun || index < 0 || index >= _items.length) return;
    final seq = ++_seq;
    final item = _items[index];

    VideoPlayerController? preloaded;
    VideoDetail? preloadDetail;
    StreamQuality? preloadStream;
    int? frozenTargetHeight;
    var preloadSlot = 0;

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
    }

    if (preloaded != null) {
      final previous = _controller;
      final previousIndex = _index;
      final previousHeight = _currentStreamHeight;
      _controller = null;
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
      }

      if (previous != null && !identical(previous, preloaded)) {
        await _freezePrevious(previous, previousIndex, previousHeight);
      }
      if (seq != _seq || !_canRun || !mounted) {
        try {
          await preloaded.dispose();
        } catch (_) {}
        return;
      }
      _index = index;
      _currentStreamHeight = preloadSlot == -1
          ? (frozenTargetHeight ?? 0)
          : (preloadStream?.height ?? 0);
      _stallTicks = 0;
      if (_sessionQualityCap == null) _stallLoweredForItem = false;
      _stallArmedAfterMs = DateTime.now().millisecondsSinceEpoch + 4000;
      _muted = context.read<AppSettings>().muted;
      preloaded.setVolume(_muted ? 0 : 1);
      if (seq != _seq || !_canRun) {
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
        _totalTime = PlaybackHelpers.fmtDuration(dur);
      });
      _slider.value = 0;
      _curTime.value = '0:00';
      // ignore: unawaited_futures
      _ensureMoreIfNearEnd(index);
      if (preloadDetail != null) {
        final s = context.read<AppSettings>();
        unawaited(
          PlaybackHelpers.skipIntro(
            preloaded,
            enabled: s.skipIntro && widget.source != SearchSource.huangguo,
            fallbackDurationSec: preloadDetail.durationSec,
            minSec: s.skipIntroMinSec,
            tiers: s.skipIntroTiers,
          ),
        );
      }
      await preloaded.play();
      if (seq != _seq || !_canRun) {
        if (identical(_controller, preloaded)) _controller = null;
        // A newer play may have frozen this controller while we awaited
        // play(); never dispose what the frozen slot now owns.
        if (!identical(_frozenController, preloaded)) {
          try {
            await preloaded.pause().catchError((_) {});
            await preloaded.dispose();
          } catch (_) {}
        }
        return;
      }
      _startTimer();
      WakelockPlus.enable();
      if (preloadDetail != null) {
        // ignore: unawaited_futures
        _translateTitleOnly(preloadDetail.title);
      }
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
          _preloadController3 = null;
          _preloadIndex3 = null;
          _preloadStream3 = null;
          _preloadRetries3 = 0;
        } else {
          // ignore: unawaited_futures
          _preloadNext(index + 1);
        }
        final n = _preloadSlotCount;
        if (n >= 2) {
          // ignore: unawaited_futures
          _preloadNext2(index + 2);
        }
        if (n >= 3) {
          // ignore: unawaited_futures
          _preloadNext3(index + 3);
        }
      } else {
        // ignore: unawaited_futures
        _preloadNext(index + 1);
        unawaited(_prefetchDetail(index + 2));
      }

      _prunePageState(index);
      return;
    }

    _trimPreloadState(index);

    final previous = _controller;
    final previousIndex = _index;
    final previousHeight = _currentStreamHeight;
    _controller = null;
    if (previous != null) {
      await _freezePrevious(previous, previousIndex, previousHeight);
    }
    if (seq != _seq || !_canRun || !mounted) return;

    setState(() {
      _pageLoading = true;
      _index = index;
      _titleText = item.title;
      _totalTime = '0:00';
    });
    _slider.value = 0;
    _curTime.value = '0:00';

    // Fire load-more early so swipe never dead-ends
    // ignore: unawaited_futures
    _ensureMoreIfNearEnd(index);

    VideoDetail detail;
    try {
      if (_detailCache.containsKey(index)) {
        detail = _detailCache[index]!;
      } else {
        detail = await _fetchDetail(item.url, item: item);
        _detailCache[index] = detail;
      }
      _maybeExpandSeries(item, index);
    } catch (e) {
      if (mounted && seq == _seq) {
        setState(() => _pageLoading = false);
        PlaybackHelpers.toast(
          context,
          '详情加载失败：${PlaybackHelpers.friendlyError(e)}',
        );
        _scheduleSkipToNext(index);
      }
      return;
    }
    if (seq != _seq || !_canRun || !mounted) return;

    if (detail.countryBlocked) {
      setState(() => _pageLoading = false);
      PlaybackHelpers.toast(context, '该视频在当前地区不可用，已跳过');
      _scheduleSkipToNext(index);
      return;
    }
    if (detail.unavailable) {
      setState(() => _pageLoading = false);
      PlaybackHelpers.toast(context, '视频不可用，已跳过');
      _scheduleSkipToNext(index);
      return;
    }

    _restartPreloading();

    final cap = _effectiveQualityCap;
    final candidates = PlaybackHelpers.streamCandidates(detail, cap);
    if (candidates.isEmpty) {
      setState(() => _pageLoading = false);
      PlaybackHelpers.toast(context, '无可用播放地址，已跳过');
      _scheduleSkipToNext(index);
      return;
    }

    VideoPlayerController? player;
    StreamQuality? stream;
    final playerDeadline = DateTime.now().add(const Duration(seconds: 18));
    for (final c in candidates) {
      if (seq != _seq || !_canRun) {
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
      if (mounted && seq == _seq) {
        setState(() => _pageLoading = false);
        // Proxy is auto-followed from the system route; there is no in-app
        // proxy settings UI — direct the user to TUN / system proxy instead.
        PlaybackHelpers.toast(
          context,
          '播放失败。有列表播不动：开 TUN 或检查系统代理',
          duration: const Duration(seconds: 3),
        );
        _scheduleSkipToNext(index);
      }
      return;
    }
    if (seq != _seq || !_canRun) {
      await player.dispose();
      return;
    }

    _currentStreamHeight = stream.height;
    _stallTicks = 0;
    if (_sessionQualityCap == null) _stallLoweredForItem = false;
    _stallArmedAfterMs = DateTime.now().millisecondsSinceEpoch + 4000;
    if (!mounted) {
      await player.dispose();
      return;
    }
    _muted = context.read<AppSettings>().muted;
    player.setVolume(_muted ? 0 : 1);
    if (seq != _seq || !_canRun) {
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
      _totalTime = PlaybackHelpers.fmtDuration(effDur);
    });
    final s = context.read<AppSettings>();
    unawaited(
      PlaybackHelpers.skipIntro(
        player,
        enabled: s.skipIntro && widget.source != SearchSource.huangguo,
        fallbackDurationSec: detail.durationSec,
        minSec: s.skipIntroMinSec,
        tiers: s.skipIntroTiers,
      ),
    );
    await player.play();
    if (seq != _seq || !_canRun) {
      if (identical(_controller, player)) _controller = null;
      await player.pause().catchError((_) {});
      await player.dispose();
      return;
    }
    // _restartPreloading() above already launched the wave covering
    // index+1..+3; scheduling the same slots again here races it and leaks a
    // second initialized controller per swipe.
    _trimPreloadState(index);
    _startTimer();
    WakelockPlus.enable();
    // ignore: unawaited_futures
    _translateTitleOnly(detail.title);
    if (mounted) setState(() {});

    // Clean up old detail cache to prevent memory growth
    _prunePageState(index);
  }

  Future<void> _translateTitleOnly(String title) async {
    if (title.isEmpty) return;
    if (RegExp(r'[\u4e00-\u9fff]').hasMatch(title)) {
      if (mounted) setState(() => _titleText = title);
      return;
    }
    try {
      final zh = await context.read<Translator>().enToZh(title);
      if (!mounted || zh.isEmpty) return;
      final i = _index;
      if (i >= 0 && i < _items.length && _items[i].title == title) {
        _items[i] = _items[i].copyWith(title: zh);
      }
      if (mounted) setState(() => _titleText = zh);
    } catch (_) {}
  }

  Future<void> _prefetchDetail(int index) async {
    if (!_canRun || index < 0 || index >= _items.length) return;
    if (_detailCache.containsKey(index)) return;
    if (_prefetchingIndex == index) return;
    _prefetchingIndex = index;
    final seq = _seq;
    final epoch = _itemsEpoch;
    final item = _items[index];
    try {
      final d = await _fetchDetail(item.url, item: item);
      if (seq != _seq || !_canRun || epoch != _itemsEpoch) return;
      _detailCache[index] = d;
      _maybeExpandSeries(item, index);
      if (epoch != _itemsEpoch) return;
      _prunePageState(_index);
    } catch (_) {
      // Ignore errors in prefetch
    } finally {
      if (_prefetchingIndex == index) _prefetchingIndex = null;
    }
  }

  /// 黄果短剧是“整部剧”而非单个视频：详情抓取到集列表后，
  /// 把 2..N 集插入当前条目之后，使上滑按 1,2,3… 顺序播放。
  void _maybeExpandSeries(VideoItem item, int index) {
    if (widget.source != SearchSource.huangguo) return;
    if (item.episode != null) return;
    if (index < 0 || index >= _items.length) return;
    if (_items[index].url != item.url) return;
    if (!_expandedSeries.add(item.url)) return;
    final episodes = context.read<HuangGuoApi>().episodesFor(item.url);
    if (episodes == null || episodes.length < 2) {
      _expandedSeries.remove(item.url);
      return;
    }
    final tail = episodes.sublist(1);
    _itemsEpoch++;
    if (mounted) {
      setState(() {
        _items.insertAll(index + 1, tail);
      });
    } else {
      _items.insertAll(index + 1, tail);
    }
    // 插入后旧索引错位：清掉索引缓存与预载，按新列表重新预取。
    _detailCache.removeWhere((k, _) => k > index);
    _prefetchingIndex = null;
    _preloadWaveSeq = -1;
    _preloadWaveIndex = -1;
    _disposePreloadSync();
    _restartPreloading();
  }

  void _trimPreloadState(int currentIndex) {
    final minKeep = currentIndex + 1;
    final maxKeep = currentIndex + _preloadSlotCount;

    bool keep(int? index) =>
        index != null && index >= minKeep && index <= maxKeep;

    void drop(VideoPlayerController? controller) {
      if (controller == null) return;
      unawaited(controller.pause().catchError((_) {}).whenComplete(() {
        try {
          controller.dispose();
        } catch (_) {}
      }));
    }

    if (!keep(_preloadIndex)) {
      drop(_preloadController);
      _preloadController = null;
      _preloadIndex = null;
      _preloadStream = null;
      _preloadRetries = 0;
    }
    if (_preloadSlotCount >= 2 && !keep(_preloadIndex2)) {
      drop(_preloadController2);
      _preloadController2 = null;
      _preloadIndex2 = null;
      _preloadStream2 = null;
      _preloadRetries2 = 0;
    }
    if (_preloadSlotCount >= 3 && !keep(_preloadIndex3)) {
      drop(_preloadController3);
      _preloadController3 = null;
      _preloadIndex3 = null;
      _preloadStream3 = null;
      _preloadRetries3 = 0;
    }
  }

  Future<void> _preloadNext(int index) async {
    if (!_canRun || index < 0 || index >= _items.length || index == _index) {
      return;
    }
    if (_preloadIndex == index && _preloadController != null) return;
    final seq = _seq;
    final epoch = _itemsEpoch;
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
    if (seq != _seq || !_canRun) return;
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
      if (_preloadRetries < 2 && seq == _seq) {
        _preloadRetries++;
        try {
          await player.dispose();
        } catch (_) {}
        await Future.delayed(Duration(milliseconds: 300 * _preloadRetries));
        if (seq == _seq && epoch == _itemsEpoch && _canRun) {
          return _preloadNext(index);
        }
      }
      try {
        await player.dispose();
      } catch (_) {}
      return;
    }
    if (seq != _seq || !_canRun || epoch != _itemsEpoch) {
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
    if (!_canRun || index < 0 || index >= _items.length || index == _index) {
      return;
    }
    if (_preloadIndex2 == index && _preloadController2 != null) return;
    final seq = _seq;
    final epoch = _itemsEpoch;
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
    if (seq != _seq || !_canRun) return;
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
      if (_preloadRetries2 < 2 && seq == _seq) {
        _preloadRetries2++;
        try {
          await player.dispose();
        } catch (_) {}
        await Future.delayed(Duration(milliseconds: 300 * _preloadRetries2));
        if (seq == _seq && epoch == _itemsEpoch && _canRun) {
          return _preloadNext2(index);
        }
      }
      try {
        await player.dispose();
      } catch (_) {}
      return;
    }
    if (seq != _seq || !_canRun || epoch != _itemsEpoch) {
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

  Future<void> _preloadNext3(int index) async {
    if (!_canRun || index < 0 || index >= _items.length || index == _index) {
      return;
    }
    if (_preloadIndex3 == index && _preloadController3 != null) return;
    final seq = _seq;
    final epoch = _itemsEpoch;
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
    if (seq != _seq || !_canRun) return;
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
      if (_preloadRetries3 < 2 && seq == _seq) {
        _preloadRetries3++;
        try {
          await player.dispose();
        } catch (_) {}
        await Future.delayed(Duration(milliseconds: 300 * _preloadRetries3));
        if (seq == _seq && epoch == _itemsEpoch && _canRun) {
          return _preloadNext3(index);
        }
      }
      try {
        await player.dispose();
      } catch (_) {}
      return;
    }
    if (seq != _seq || !_canRun || epoch != _itemsEpoch) {
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

  void _startTimer() {
    final ctrl = _controller;
    if (ctrl == null || !_canRun) return;
    _progressTimer?.cancel();
    var lastTickMs = 0;
    var lastPosMs = 0.0;
    var lastBufferedMs = 0.0;
    _smoothedSpeedKbps = 0;
    _speedSamples = 0;
    _speedLabel = '';
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
      final fallback = (_index >= 0 && _detailCache.containsKey(_index))
          ? (_detailCache[_index]?.durationSec ?? 0)
          : 0;
      final dur = PlaybackHelpers.effectiveDuration(
        ctrl,
        fallbackSec: fallback,
      );
      if (dur.inMilliseconds <= 0) return;
      // 黄果短剧按剧集播放：一集播完自动接下一集（同一部剧 1,2,3…）。
      if (widget.source == SearchSource.huangguo &&
          ctrl.value.isPlaying &&
          pos.inMilliseconds >= dur.inMilliseconds - 600) {
        _maybeAutoNextEpisode();
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      final posMs = pos.inMilliseconds.toDouble();
      final ranges = ctrl.value.buffered;
      final bufferedMs =
          ranges.isEmpty ? 0.0 : ranges.last.end.inMilliseconds.toDouble();
      if (lastTickMs > 0) {
        final dMs = now - lastTickMs;
        final dPlayed = posMs - lastPosMs;
        final downloaded =
            (bufferedMs - lastBufferedMs + dPlayed).clamp(0.0, double.infinity);
        if (dMs > 0 && downloaded > 0) {
          final sample = (1500 * (downloaded / dMs).clamp(0.0, 3.0))
              .clamp(0, 12000)
              .toDouble();
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
            final label = '${_smoothedSpeedKbps.round().clamp(0, 20000)} Kbps';
            if (label != _speedLabel && mounted) {
              setState(() => _speedLabel = label);
            }
          }
        }
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
      lastTickMs = now;
      lastPosMs = posMs;
      lastBufferedMs = bufferedMs;
      _slider.value = (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0);
      _curTime.value = PlaybackHelpers.fmtDuration(pos);
      final t = PlaybackHelpers.fmtDuration(dur);
      if (t != _totalTime && mounted) setState(() => _totalTime = t);
    });
  }

  /// 剧集结束自动接下一集（每集只触发一次，避免计时器重复调度）。
  int? _autoAdvancedPage;

  void _maybeAutoNextEpisode() {
    // Caller only invokes this for huangguo series near episode end.
    final i = _index;
    if (i >= _items.length - 1) return;
    if (_autoAdvancedPage == i) return;
    if (!mounted || !_pageCtrl.hasClients) return;
    _autoAdvancedPage = i;
    try {
      _pageCtrl.animateToPage(
        i + 1,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOut,
      );
    } catch (_) {}
  }

  /// 长按 3 倍速：按住加速，松手还原，左上角淡显“3倍速播放中”。
  void _onLongPressBoost(bool active) {
    if (mounted) setState(() => _speedBoostActive = active);
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    c.setPlaybackSpeed(active ? 3.0 : 1.0);
  }

  void _onPageChanged(int page) {
    if (_resyncingPage) return;
    if (page == _index) return;
    _autoAdvancedPage = null;
    _speedBoostActive = false;
    _manualPaused = false;
    // Stall auto-lower is per-item only.
    _sessionQualityCap = null;
    _stallLoweredForItem = false;
    _stallTicks = 0;
    _prunePageState(page);
    _playIndex(page);
    // ignore: unawaited_futures
    _ensureMoreIfNearEnd(page);
  }

  void _onSeekPreview(double v) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final durMs = c.value.duration.inMilliseconds;
    if (durMs <= 0) return;
    final ms = (durMs * v).round();
    _slider.value = v.clamp(0.0, 1.0);
    _curTime.value = PlaybackHelpers.fmtDuration(Duration(milliseconds: ms));
  }

  Future<void> _onSeekCommit(double v) async {
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
    final ms = (durMs * target).round();
    _seeking = true;
    _slider.value = target;
    _curTime.value = PlaybackHelpers.fmtDuration(Duration(milliseconds: ms));
    try {
      // Timeout a hanging seek so _seeking can never wedge the progress bar.
      await c
          .seekTo(Duration(milliseconds: ms))
          .timeout(const Duration(seconds: 4));
      await Future<void>.delayed(const Duration(milliseconds: 120));
      if (!mounted || !identical(c, _controller)) return;
      final p = c.value.position;
      final d = c.value.duration;
      if (d.inMilliseconds > 0) {
        _slider.value = (p.inMilliseconds / d.inMilliseconds).clamp(0.0, 1.0);
        _curTime.value = PlaybackHelpers.fmtDuration(p);
      }
    } catch (_) {
    } finally {
      if (mounted) _seeking = false;
    }
  }

  void _toggleMute() {
    _muted = !_muted;
    _controller?.setVolume(_muted ? 0 : 1);
    context.read<AppSettings>().setMuted(_muted);
    setState(() {});
  }

  Future<void> _fastForward() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final currentPos = c.value.position;
    final duration = c.value.duration;
    final newPos = currentPos + const Duration(seconds: 30);

    _seeking = true;
    void settle() {
      Future.delayed(const Duration(milliseconds: 120), () {
        if (mounted) _seeking = false;
      });
    }

    try {
      if (newPos < duration) {
        await c.seekTo(newPos).timeout(const Duration(seconds: 4));
      } else {
        await c.seekTo(duration).timeout(const Duration(seconds: 4));
      }
      settle();
    } catch (_) {
      if (mounted) _seeking = false;
    }
  }

  void _onHorizontalDragStart(DragStartDetails details) {
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized) return;

    _seeking = true;
    setState(() {
      _dragStartX = details.globalPosition.dx;
      _dragStartPosition = ctrl.value.position;
      _seekPreviewText = '';
    });
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    if (_dragStartX == null || _dragStartPosition == null) {
      return;
    }
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized) return;

    final deltaX = details.globalPosition.dx - _dragStartX!;
    final screenWidth = MediaQuery.of(context).size.width;

    final secondsPerScreenWidth = 360.0;
    final deltaSec = (deltaX / screenWidth * secondsPerScreenWidth).round();

    final newPos = _dragStartPosition! + Duration(seconds: deltaSec);
    final duration = ctrl.value.duration;
    final clampedPos = Duration(
      milliseconds: newPos.inMilliseconds.clamp(0, duration.inMilliseconds),
    );
    final ratio = duration.inMilliseconds > 0
        ? (clampedPos.inMilliseconds / duration.inMilliseconds)
            .clamp(0.0, 1.0)
        : 0.0;

    String formatTime(Duration d) {
      final min = d.inMinutes;
      final sec = d.inSeconds % 60;
      return '$min:${sec.toString().padLeft(2, '0')}';
    }

    setState(() {
      _dragTargetPosition = clampedPos;
      if (deltaSec > 0) {
        _seekPreviewText = '+$deltaSec绉?鈫?${formatTime(clampedPos)}';
      } else if (deltaSec < 0) {
        _seekPreviewText = '$deltaSec绉?鈫?${formatTime(clampedPos)}';
      } else {
        _seekPreviewText = formatTime(clampedPos);
      }
    });
    _onSeekPreview(ratio);
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    if (_dragStartX == null || _dragStartPosition == null) {
      return;
    }
    final ctrl = _controller;
    final targetPos = _dragTargetPosition ?? _dragStartPosition!;
    setState(() {
      _dragStartX = null;
      _dragStartPosition = null;
      _dragTargetPosition = null;
      _seekPreviewText = '';
    });
    if (ctrl == null || !ctrl.value.isInitialized) {
      _seeking = false;
      return;
    }

    final durMs = ctrl.value.duration.inMilliseconds;
    final ratio =
        durMs > 0 ? (targetPos.inMilliseconds / durMs).clamp(0.0, 1.0) : 0.0;
    // ignore: unawaited_futures
    _onSeekCommit(ratio);
  }

  void _onTapScreen() {
    final chrome = _chrome;
    if (chrome == null || !chrome.immersive) return;
    setState(() {
      _showExitButton = !_showExitButton;
    });

    if (_showExitButton) {
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted && _showExitButton) {
          setState(() {
            _showExitButton = false;
          });
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final immersive = context.select<PlayerChrome, bool>((c) => c.immersive);
    final showSearchBackButton =
        defaultTargetPlatform != TargetPlatform.iOS ||
        context.select<AppSettings, bool>((s) => s.showSearchBackButton);
    final showFullscreenButton =
        defaultTargetPlatform != TargetPlatform.iOS ||
        context.select<AppSettings, bool>((s) => s.showFullscreenButton);
    final showMuteButton =
        defaultTargetPlatform != TargetPlatform.iOS ||
        context.select<AppSettings, bool>((s) => s.showMuteButton);

    final chrome = context.read<PlayerChrome>();
    return PopScope(
      canPop: _allowPop || defaultTargetPlatform == TargetPlatform.iOS,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          stopPlaybackImmediately();
          return;
        }
        if (immersive) {
          // ignore: unawaited_futures
          chrome.exitFullscreen().then((_) {
            _autoRotate?.syncLandscapeMode(false, fromUser: true);
            if (mounted) {
              setState(() {});
              _schedulePageResync();
            }
          }).catchError((_) {});
          return;
        }
        // ignore: unawaited_futures
        _exitAfterStopping();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        extendBodyBehindAppBar: true,
        appBar: null,
        body: chrome.wrapBody(
          context,
          GestureDetector(
            onTap: () {
              if (_chrome?.immersive == true) {
                _onTapScreen();
              } else {
                final c = _controller;
                if (c == null || !c.value.isInitialized) return;
                if (c.value.isPlaying) {
                  c.pause();
                  if (mounted) setState(() => _manualPaused = true);
                } else {
                  c.play();
                  if (mounted) setState(() => _manualPaused = false);
                }
              }
            },
            onLongPressStart: (_) => _onLongPressBoost(true),
            onLongPressEnd: (_) => _onLongPressBoost(false),
            onHorizontalDragStart: _onHorizontalDragStart,
            onHorizontalDragUpdate: _onHorizontalDragUpdate,
            onHorizontalDragEnd: _onHorizontalDragEnd,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Landscape: never use PageView — RotatedBox viewport change
                // maps pixel offset to page 0 (first thumb) while audio keeps
                // playing the real controller. Portrait: vertical swipe feed.
                if (immersive)
                  Builder(
                    builder: (_) {
                      final c = _controller;
                      if (c != null && c.value.isInitialized) {
                        final ar = c.value.aspectRatio;
                        return ColoredBox(
                          color: Colors.black,
                          child: Center(
                            child: AspectRatio(
                              aspectRatio:
                                  (ar.isFinite && ar > 0.05) ? ar : (16 / 9),
                              child: VideoPlayer(c),
                            ),
                          ),
                        );
                      }
                      final thumb = (_index >= 0 && _index < _items.length)
                          ? _items[_index].thumb
                          : null;
                      return Container(
                        color: const Color(0xFF1A1A1A),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (thumb != null && thumb.isNotEmpty)
                              CachedNetworkImage(
                                imageUrl: thumb,
                                httpHeaders: AppHttpHeaders.forMediaUrl(thumb),
                                fit: BoxFit.cover,
                                memCacheWidth: 720,
                                placeholder: (_, __) =>
                                    const ColoredBox(color: Color(0xFF1A1A1A)),
                                errorWidget: (_, __, ___) =>
                                    const SizedBox.shrink(),
                              ),
                            if (_pageLoading)
                              const Center(
                                child: CircularProgressIndicator(
                                  color: Color(0xFFFF6B35),
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  )
                else
                  PageView.builder(
                    controller: _pageCtrl,
                    scrollDirection: Axis.vertical,
                    itemCount: _items.length,
                    onPageChanged: _onPageChanged,
                    itemBuilder: (_, i) {
                      if (i == _index &&
                          _controller != null &&
                          _controller!.value.isInitialized) {
                        final ar = _controller!.value.aspectRatio;
                        return ColoredBox(
                          color: Colors.black,
                          child: Center(
                            child: AspectRatio(
                              aspectRatio:
                                  (ar.isFinite && ar > 0.05) ? ar : (16 / 9),
                              child: VideoPlayer(_controller!),
                            ),
                          ),
                        );
                      }
                      final thumb = _items[i].thumb;
                      return Container(
                        color: const Color(0xFF1A1A1A),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (thumb != null && thumb.isNotEmpty)
                              CachedNetworkImage(
                                imageUrl: thumb,
                                httpHeaders: AppHttpHeaders.forMediaUrl(thumb),
                                fit: BoxFit.cover,
                                memCacheWidth: 720,
                                placeholder: (_, __) =>
                                    const ColoredBox(color: Color(0xFF1A1A1A)),
                                errorWidget: (_, __, ___) =>
                                    const SizedBox.shrink(),
                              ),
                            if (i == _index && _pageLoading)
                              const Center(
                                child: CircularProgressIndicator(
                                  color: Color(0xFFFF6B35),
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                // 横屏手势进度预览
        if (_seekPreviewText.isNotEmpty)
                  Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black87,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _seekPreviewText,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                if (immersive) ...[
                  // 横屏：点击屏幕显示/隐藏控制栏
                  if (_showExitButton) ...[
                    // 退出按钮
                    if (showFullscreenButton)
                      Positioned(
                        right: 16,
                        top: 16,
                        child: SafeArea(
                          child: GestureDetector(
                            onTap: _toggleFullscreen,
                            child: Icon(
                              Icons.fullscreen_exit,
                              color: Colors.white.withValues(alpha: 0.5),
                              size: 28,
                              shadows: const [
                                Shadow(color: Colors.black45, blurRadius: 4),
                              ],
                            ),
                          ),
                        ),
                      ),
                    // 设置按钮
                    Positioned(
                      left: 16,
                      top: 16,
                      child: SafeArea(
                        child: GestureDetector(
                          onTap: _openPlayerSettings,
                          child: Icon(
                            Icons.settings,
                            color: Colors.white.withValues(alpha: 0.5),
                            size: 28,
                            shadows: const [
                              Shadow(color: Colors.black45, blurRadius: 4),
                            ],
                          ),
                        ),
                      ),
                    ),
                    // 进度条
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: SafeArea(
                        child: FeedProgressBar(
                          slider: _slider,
                          curTime: _curTime,
                          totalTime: _totalTime,
                          onChanged: _onSeekPreview,
                          onChangeStart: (_) {
                            _seeking = true;
                          },
                          onChangeEnd: (v) {
                            // ignore: unawaited_futures
                            _onSeekCommit(v);
                          },
                        ),
                      ),
                    ),
                  ],
                ] else ...[
                  Positioned(
                    left: 12,
                    right: 12,
                    top: 8,
                    child: SafeArea(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _titleText,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 14,
                              shadows: [
                                Shadow(color: Colors.black87, blurRadius: 4)
                              ],
                            ),
                          ),
                          if (!immersive && _speedLabel.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                _speedLabel,
                                style: TextStyle(
                                  color: const Color(0xFF66D9A0)
                                      .withValues(alpha: 0.45),
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          if (_manualPaused &&
                              (_controller?.value.isInitialized ?? false) &&
                              !(_controller?.value.isPlaying ?? true))
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: const [
                                    Text(
                                      '已暂停',
                                      style: TextStyle(
                                        color: Color(0x73FFFFFF),
                                        fontSize: 11,
                                      ),
                                    ),
                                    SizedBox(width: 3),
                                    Icon(Icons.pause_circle_outline,
                                        size: 13,
                                        color: Color(0x73FFFFFF)),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  // 竖屏：全屏按钮（半透明，无背景）
                  if (showSearchBackButton)
                    Positioned(
                      left: 10,
                      top: 52,
                      child: SafeArea(
                        child: _MinimalButton(
                          storageKey: 'search_back_button_normal',
                          defaultOffset: const Offset(10, 52),
                          icon: Icons.arrow_back_ios_new,
                          iconAlpha: 0.3,
                          showShadow: false,
                          onTap: _exitAfterStopping,
                        ),
                      ),
                    ),
                  // 竖屏：设置按钮（半透明，无背景；与标题同行）
                  Positioned(
                    right: 10,
                    top: 8,
                    child: SafeArea(
                      child: _MinimalButton(
                        storageKey: 'search_settings_button_normal',
                        defaultOffset: const Offset(10, 52),
                        icon: Icons.settings,
                        iconAlpha: 0.18,
                        onTap: _openPlayerSettings,
                      ),
                    ),
                  ),
                  Positioned(
                    right: 10,
                    top: 96,
                    child: SafeArea(
                      child: showFullscreenButton
                          ? Opacity(
                              opacity: 0.42,
                              child: _MinimalButton(
                                storageKey: 'search_fullscreen_button_normal',
                                defaultOffset: const Offset(10, 96),
                                icon: Icons.fullscreen,
                                onTap: _toggleFullscreen,
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),
                  // 竖屏：快进按钮（半透明，无背景）
                  // 竖屏：音量按钮（半透明，无背景）
                  Positioned(
                    right: 10,
                    bottom: 80,
                    child: SafeArea(
                      child: showMuteButton
                          ? _MinimalButton(
                              storageKey: 'search_mute_button_normal',
                              defaultOffset: const Offset(10, 80),
                              icon: _muted
                                  ? Icons.volume_off
                                  : Icons.volume_up,
                              onTap: _toggleMute,
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: SafeArea(
                      child: FeedProgressBar(
                        slider: _slider,
                        curTime: _curTime,
                        totalTime: _totalTime,
                        onChanged: _onSeekPreview,
                        onChangeStart: (_) {
                          _seeking = true;
                        },
                        onChangeEnd: (v) {
                          // ignore: unawaited_futures
                          _onSeekCommit(v);
                        },
                      ),
                    ),
                  ),
                  // 长按 3 倍速提示（左上角，淡）
                  if (_speedBoostActive)
                    Positioned(
                      left: 16,
                      top: immersive ? 56 : 66,
                      child: SafeArea(
                        child: IgnorePointer(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.35),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text(
                              '3倍速播放中',
                              style: TextStyle(
                                color: Color(0x99FFFFFF),
                                fontSize: 11,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openPlayerSettings() {
    final detail = _detailCache[_index];
    final heights = <int>[];
    if (detail != null) {
      for (final s in detail.streams) {
        if (s.height > 0) heights.add(s.height);
      }
    }
    showPlayerSettingsSheet(
      context,
      qualityHeights: heights.isEmpty ? null : heights,
      onFastForward: _fastForward,
      onQualityChanged: () {
        _sessionQualityCap = null;
        if (mounted) _playIndex(_index);
      },
    );
  }

  Future<void> _maybeAutoLowerQuality() async {
    if (!mounted || _stallLowering || _stallLoweredForItem) return;
    final enabled = _settings?.autoLowerOnStall ??
        context.read<AppSettings>().autoLowerOnStall;
    if (!enabled) return;
    final detail = _detailCache[_index];
    if (detail == null || detail.streams.length < 2) return;
    final heights =
        detail.streams.map((s) => s.height).where((h) => h > 0).toSet();
    if (heights.length < 2) return;
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
      if (mounted) await _playIndex(_index);
    } finally {
      _stallLowering = false;
    }
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

/// 极简按钮：半透明图标，无背景，支持长按拖动
class _MinimalButton extends StatefulWidget {
  const _MinimalButton({
    required this.storageKey,
    required this.defaultOffset,
    required this.icon,
    required this.onTap,
    this.iconAlpha = 0.5,
    this.showShadow = true,
  });

  final String storageKey;
  final Offset defaultOffset;
  final IconData icon;
  final VoidCallback onTap;
  final double iconAlpha;
  final bool showShadow;

  @override
  State<_MinimalButton> createState() => _MinimalButtonState();
}

class _MinimalButtonState extends State<_MinimalButton> {
  Offset? _savedOffset;
  bool _isDragging = false;
  Offset _currentDragOffset = Offset.zero;
  Offset _dragStartOffset = Offset.zero;

  @override
  void initState() {
    super.initState();
    _loadOffset();
  }

  Future<void> _loadOffset() async {
    final prefs = await SharedPreferences.getInstance();
    final x = prefs.getDouble('${widget.storageKey}_offset_x');
    final y = prefs.getDouble('${widget.storageKey}_offset_y');
    if (x != null && y != null && mounted) {
      setState(() {
        _savedOffset = Offset(x, y);
      });
    }
  }

  Future<void> _saveOffset(Offset offset) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('${widget.storageKey}_offset_x', offset.dx);
    await prefs.setDouble('${widget.storageKey}_offset_y', offset.dy);
  }

  @override
  Widget build(BuildContext context) {
    final displayOffset =
        _isDragging ? _currentDragOffset : (_savedOffset ?? Offset.zero);

    return Transform.translate(
      offset: displayOffset,
      child: GestureDetector(
        onTap: _isDragging ? null : widget.onTap,
        onLongPressStart: (details) {
          setState(() {
            _isDragging = true;
            _dragStartOffset = _savedOffset ?? Offset.zero;
            _currentDragOffset = _dragStartOffset;
          });
        },
        onLongPressMoveUpdate: (details) {
          if (!_isDragging) return;
          setState(() {
            _currentDragOffset = _dragStartOffset + details.offsetFromOrigin;
            final size = MediaQuery.of(context).size;
            final padding = MediaQuery.of(context).padding;
            _currentDragOffset = Offset(
              _currentDragOffset.dx.clamp(
                -widget.defaultOffset.dx,
                size.width - widget.defaultOffset.dx - 40 - padding.right,
              ),
              _currentDragOffset.dy.clamp(
                -widget.defaultOffset.dy,
                size.height - widget.defaultOffset.dy - 40 - padding.bottom,
              ),
            );
          });
        },
        onLongPressEnd: (details) {
          setState(() {
            _savedOffset = _currentDragOffset;
            _isDragging = false;
          });
          _saveOffset(_currentDragOffset);
        },
        child: AnimatedScale(
          scale: _isDragging ? 1.2 : 1.0,
          duration: const Duration(milliseconds: 150),
          child: Icon(
            widget.icon,
            color: _isDragging
                ? Colors.white.withValues(alpha: 0.9)
                : Colors.white.withValues(alpha: widget.iconAlpha),
            size: 28,
            shadows: widget.showShadow
                ? const [Shadow(color: Colors.black45, blurRadius: 4)]
                : null,
          ),
        ),
      ),
    );
  }
}

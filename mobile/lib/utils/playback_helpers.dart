import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../models/video_item.dart';
import '../services/app_settings.dart';
import '../services/source_catalog.dart';

/// 全局「单一发声」执行器。
///
/// 背景：本应用的设计不变量是"同一时刻最多只有一个解码器在出声"，但这个
/// 不变量分散在每个播放路径的 try/catch 与 seq 守卫里。偶发场景（平台通道
/// 异常被吞、切 tab 与在途播放交叉、预热/冻结/预载槽收编竞态）只要漏掉
/// 一次 pause，就会出现"当前视频在播、后台还有另一个视频在响"且无人回收。
///
/// 兜底原理：每个 VideoPlayerController 创建时调用 [track]；任何 play() 之前
/// 调用 [enforceSolo]，把注册表里其它已初始化的控制器全部补一记 pause。
/// 平台通道按调用顺序 FIFO 执行，这些 pause 必然先于紧随的 play 生效，
/// 所以无论哪条路径漏了 pause，声音都活不过下一次 play()。
class PlaybackSolo {
  PlaybackSolo._();

  /// 被跟踪的解码器。只增不主动删：dispose 后的条目会在 enforceSolo 的
  /// pause 抛错时顺手摘除，另设 FIFO 上限防长会话累积（被挤掉的必然是
  /// 早已 dispose 的老控制器——活跃的冻结/预载条目离队首相差几十次创建）。
  static final List<VideoPlayerController> _tracked =
      <VideoPlayerController>[];

  /// 每次滑动新建 ~1-3 个控制器；24 ≈ 8 条滑动深度内全部保持被跟踪，
  /// 而任何存活控制器的年龄都不可能超过一个滑动周期。
  static const _maxTracked = 24;

  /// 控制器创建时登记（三个构造点：两个信息流屏的 _createNetworkPlayer、
  /// MediaPrewarm.warm）。重复登记按同一性去重。
  static void track(VideoPlayerController controller) {
    for (final c in _tracked) {
      if (identical(c, controller)) return;
    }
    _tracked.add(controller);
    while (_tracked.length > _maxTracked) {
      _tracked.removeAt(0);
    }
  }

  /// 即将在 [active] 上开始播放：把其它一切已初始化的控制器压停。
  /// fire-and-forget——pause 的平台消息同步入队，先于调用方随后的 play；
  /// 不 await 也避免给滑动起播串行加延迟。
  static void enforceSolo(VideoPlayerController active) {
    for (var i = _tracked.length - 1; i >= 0; i--) {
      final c = _tracked[i];
      if (identical(c, active)) continue;
      // 未初始化的控制器不可能在出声（也不会 autoplay）；对它调 pause 会
      // 抛 StateError，还会把一个即将合法播放的候选误摘出跟踪表。
      if (!c.value.isInitialized) continue;
      unawaited(
        c.pause().catchError((_) {
          // dispose 后的控制器 pause 必然抛错：借机摘除死条目。
          _tracked.remove(c);
        }),
      );
    }
  }
}

/// Shared playback helpers for feed / search-feed.
class PlaybackHelpers {
  /// Decoder budget shared by every vertical-feed implementation.
  /// Active player + 2 lookahead slots on mobile (was 3).
  static const preloadSlotCount = 2;


  /// [skipIntro] with the user's settings (跳过片头折叠配置)。
  static Future<void> skipIntroFromSettings(
    VideoPlayerController ctrl,
    AppSettings settings, {
    int fallbackDurationSec = 0,
  }) =>
      skipIntro(
        ctrl,
        enabled: settings.skipIntro,
        fallbackDurationSec: fallbackDurationSec,
        minSec: settings.skipIntroMinSec,
        tiers: settings.skipIntroTiers,
      );

  /// Skip intro ads based on video duration and the user's tiered rules
  /// (settings sheet → 跳过片头): videos shorter than [minSec] are never
  /// touched (teasers / broken 9s clips / live). Among [tiers] (ascending
  /// (atSec, skipSec) pairs) the largest tier whose threshold the duration
  /// meets wins — the longer the video, the more it skips.
  static Future<void> skipIntro(
    VideoPlayerController ctrl, {
    bool enabled = true,
    int fallbackDurationSec = 0,
    int minSec = 45,
    List<(int atSec, int skipSec)> tiers = const [
      (100, 10),
      (600, 15),
      (900, 25),
      (3000, 70),
    ],
  }) async {
    if (!enabled || !ctrl.value.isInitialized) return;
    var total = ctrl.value.duration.inSeconds;
    if (total <= 0 && fallbackDurationSec > 0) {
      total = fallbackDurationSec;
    }
    // Short / unknown: do not seek (avoids killing 9s teasers or live)
    if (total <= 0 || total < minSec) return;

    var skipSeconds = 0;
    for (final (at, sec) in tiers) {
      if (total >= at && sec > skipSeconds) skipSeconds = sec;
    }
    if (skipSeconds <= 0) return;
    if (total - skipSeconds < 5) return;

    try {
      await ctrl.seekTo(Duration(seconds: skipSeconds));
    } catch (_) {}
  }

  /// Effective duration for progress UI: player first, then detail metadata.
  static Duration effectiveDuration(
    VideoPlayerController ctrl, {
    int fallbackSec = 0,
  }) {
    final d = ctrl.value.duration;
    if (d.inMilliseconds > 500) return d;
    if (fallbackSec > 0) return Duration(seconds: fallbackSec);
    return d;
  }

  static StreamQuality? pickStream(VideoDetail detail, int qualityCap) =>
      detail.streamForCap(qualityCap);

  /// Ordered candidates for init fallback: preferred/cap first, then lower, then higher.
  static List<StreamQuality> streamCandidates(
    VideoDetail detail,
    int qualityCap,
  ) {
    if (detail.streams.isEmpty) return const [];
    final primary = detail.streamForCap(qualityCap);
    final rest = [...detail.streams]
      ..sort((a, b) => b.pixels.compareTo(a.pixels));
    final out = <StreamQuality>[];
    final seen = <String>{};
    void add(StreamQuality? s) {
      if (s == null || s.url.isEmpty) return;
      if (seen.add(s.url)) out.add(s);
    }

    add(primary);
    // Lower first (more likely to play on weak net), then any remaining.
    final lower = rest
        .where((s) =>
            primary == null || s.height <= 0 || s.height < primary.height)
        .toList()
      ..sort((a, b) => b.pixels.compareTo(a.pixels));
    for (final s in lower) {
      add(s);
    }
    for (final s in rest) {
      add(s);
    }
    return out;
  }

  /// Reject hover/ad/fallback clips that initialize successfully but are far
  /// shorter than the real VOD. Several sites return a valid 9-60 second MP4
  /// when their protected full-stream request was not authorized.
  static bool isLikelyPreview(
    VideoPlayerController controller,
    VideoDetail detail, {
    String? siteId,
    bool isLive = false,
  }) {
    if (isLive || !controller.value.isInitialized) return false;
    final seconds = controller.value.duration.inSeconds;
    if (seconds <= 0) return false;
    if (detail.durationSec >= 120 &&
        seconds < 90 &&
        seconds * 4 < detail.durationSec) {
      return true;
    }
    // 长片源站点 id 集中维护在 SourceCatalog（见 longFormPreviewSiteIds 注释），
    // 不在此处硬编码，避免站点列表更新后判断失效。
    return SourceCatalog.longFormPreviewSiteIds.contains(siteId) &&
        seconds <= 75;
  }

  /// Brief non-blocking toast.
  static void toast(
    BuildContext context,
    String msg, {
    Duration duration = const Duration(milliseconds: 1200),
  }) {
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontSize: 13)),
        duration: duration,
        behavior: SnackBarBehavior.floating,
        backgroundColor: Colors.black87,
        margin: const EdgeInsets.fromLTRB(48, 0, 48, 72),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      ),
    );
  }

  /// Map raw exceptions to short Chinese hints (no proxy essays).
  ///
  /// Prefers structured [DioException] fields ([DioException.type] /
  /// [DioException.response] status code) over `toString()` string matching,
  /// which is fragile across Dio/Flutter upgrades and localizations. String
  /// matching is kept only as a last-resort fallback for non-Dio errors.
  static String friendlyError(Object error) {
    if (error is DioException) {
      final structured = _friendlyFromDio(error);
      if (structured != null) return structured;
    }
    final s = error.toString();
    final low = s.toLowerCase();
    if (low.contains('404') || low.contains('not found')) {
      return '内容不存在(404)';
    }
    if (low.contains('403') || low.contains('forbidden')) {
      return '访问被拒绝(403)';
    }
    if (low.contains('timeout') || low.contains('timed out')) {
      return '网络超时';
    }
    if (low.contains('socket') ||
        low.contains('connection') ||
        low.contains('network') ||
        low.contains('failed host lookup') ||
        low.contains('connection refused') ||
        low.contains('proxy')) {
      return '网络异常';
    }
    if (low.contains('handshake') || low.contains('certificate')) {
      return '安全连接失败';
    }
    if (s.length > 80) return '${s.substring(0, 80)}…';
    return s;
  }

  /// Structured classification for [DioException]; returns null when it does
  /// not map cleanly (so the caller can fall back to message matching).
  static String? _friendlyFromDio(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return '网络超时';
      case DioExceptionType.connectionError:
        return '网络异常';
      case DioExceptionType.badCertificate:
        return '安全连接失败';
      case DioExceptionType.cancel:
        return '请求已取消';
      case DioExceptionType.badResponse:
        final code = e.response?.statusCode ?? 0;
        if (code == 404) return '内容不存在(404)';
        if (code == 403 || code == 401) return '访问被拒绝($code)';
        if (code == 408) return '源站请求超时 (408)';
        if (code == 429) return '请求过于频繁 (429)，请稍后重试';
        if (code > 0) return '源站返回异常状态 ($code)';
        return null;
      case DioExceptionType.unknown:
        return null;
    }
  }

  static String fmtDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}

/// Bottom seek bar; drag only updates UI — parent seeks on [onChangeEnd].
class FeedProgressBar extends StatelessWidget {
  const FeedProgressBar({
    super.key,
    required this.slider,
    required this.curTime,
    required this.totalTime,
    required this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
  });

  final ValueNotifier<double> slider;
  final ValueNotifier<String> curTime;
  final ValueNotifier<String> totalTime;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double>? onChangeEnd;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 48,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black87, Colors.transparent],
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          ValueListenableBuilder<String>(
            valueListenable: curTime,
            builder: (_, t, __) => Text(
              t,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 10,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderThemeData(
                trackHeight: 3.5,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                activeTrackColor: const Color(0xFFFF6B35),
                inactiveTrackColor: Colors.white24,
                thumbColor: const Color(0xFFFF6B35),
                // Smoother visual while dragging
                trackShape: const RoundedRectSliderTrackShape(),
              ),
              child: ValueListenableBuilder<double>(
                valueListenable: slider,
                builder: (_, v, __) => Slider(
                  value: v.clamp(0.0, 1.0),
                  onChanged: onChanged,
                  onChangeStart: onChangeStart,
                  onChangeEnd: onChangeEnd,
                ),
              ),
            ),
          ),
          ValueListenableBuilder<String>(
            valueListenable: totalTime,
            builder: (_, t, __) => Text(
              t,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 10,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One lookahead buffer slot shared by the vertical feed players: a prepared
/// (paused, muted) controller plus the item/stream it was built for.
class PreloadSlot {
  PreloadSlot();

  VideoPlayerController? controller;
  int? index;
  StreamQuality? stream;
  int retries = 0;

  /// True while a fill task is initializing for this slot. Prevents two
  /// concurrent fills for the same slot from both committing — the loser
  /// used to leak a fully initialized decoder.
  bool inFlight = false;
}

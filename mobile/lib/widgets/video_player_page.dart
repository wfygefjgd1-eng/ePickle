import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import '../models/video_item.dart';
import '../services/app_settings.dart';
import '../utils/http_headers.dart';
import '../utils/playback_helpers.dart';
import 'stripchat_live_view.dart';

class VideoPlayerPage extends StatefulWidget {
  const VideoPlayerPage({
    super.key,
    required this.items,
    required this.currentIndex,
    required this.controller,
    required this.pageLoading,
    required this.muted,
    required this.immersive,
    required this.pageCtrl,
    required this.sliderValue,
    required this.currentTime,
    required this.totalTime,
    required this.titleText,
    required this.speedLabel,
    this.browserLiveUrl,
    this.browserIsStripchat = false,
    required this.livePaused,
    required this.onPageChanged,
    required this.onMute,
    required this.onFastForward,
    required this.onFullscreen,
    required this.onBack,
    required this.onOpenSettings,
    required this.onLiveToggle,
    required this.onSeekPreview,
    required this.onSeekStart,
    required this.onSeekEnd,
  });

  final List<VideoItem> items;
  final int currentIndex;
  final VideoPlayerController? controller;
  final bool pageLoading;
  final bool muted;
  final bool immersive;
  final PageController pageCtrl;
  final ValueNotifier<double> sliderValue;
  final ValueNotifier<String> currentTime;
  final ValueNotifier<String> totalTime;
  final String titleText;
  final ValueNotifier<String> speedLabel;
  final String? browserLiveUrl;
  final bool browserIsStripchat;
  final bool livePaused;

  final ValueChanged<int> onPageChanged;
  final VoidCallback onMute;
  final VoidCallback onFastForward;
  final VoidCallback onFullscreen;
  final VoidCallback onBack;
  final VoidCallback onOpenSettings;
  final VoidCallback onLiveToggle;
  final ValueChanged<double> onSeekPreview;
  final VoidCallback onSeekStart;
  final ValueChanged<double> onSeekEnd;

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  bool _showExitButton = false;
  double? _dragStartX;
  Duration? _dragStartPosition;
  Duration? _dragTargetPosition;
  String _seekPreviewText = '';

  /// 退出按钮自动隐藏计时器：仅保留最近一次，重排前取消，避免快速连点
  /// 累积多个 future 导致按钮提前隐藏。
  Timer? _hideTimer;

  void _onHorizontalDragStart(DragStartDetails details) {
    final ctrl = widget.controller;
    if (ctrl == null || !ctrl.value.isInitialized) return;

    widget.onSeekStart();
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
    final ctrl = widget.controller;
    if (ctrl == null || !ctrl.value.isInitialized) return;

    final deltaX = details.globalPosition.dx - _dragStartX!;
    final screenWidth = MediaQuery.of(context).size.width;

    // 拖动映射：拖动 1/6 屏幕宽度 = 60 秒。
    final secondsPerScreenWidth = 360.0; // 全屏宽度 = 6 分钟
    final deltaSec = (deltaX / screenWidth * secondsPerScreenWidth).round();

    final newPos = _dragStartPosition! + Duration(seconds: deltaSec);
    final duration = ctrl.value.duration;
    final clampedPos = Duration(
      milliseconds: newPos.inMilliseconds.clamp(0, duration.inMilliseconds),
    );
    final ratio = duration.inMilliseconds > 0
        ? (clampedPos.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    String formatTime(Duration d) {
      final h = d.inHours;
      final min = d.inMinutes % 60;
      final sec = d.inSeconds % 60;
      final mm = min.toString().padLeft(2, '0');
      final ss = sec.toString().padLeft(2, '0');
      if (h > 0) {
        return '$h:$mm:$ss';
      }
      return '$min:$ss';
    }

    setState(() {
      _dragTargetPosition = clampedPos;
      if (deltaSec > 0) {
        _seekPreviewText = '+$deltaSec秒 → ${formatTime(clampedPos)}';
      } else if (deltaSec < 0) {
        _seekPreviewText = '$deltaSec秒 → ${formatTime(clampedPos)}';
      } else {
        _seekPreviewText = formatTime(clampedPos);
      }
    });
    widget.onSeekPreview(ratio);
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    if (_dragStartX == null || _dragStartPosition == null) {
      return;
    }
    final ctrl = widget.controller;
    final targetPos = _dragTargetPosition ?? _dragStartPosition!;
    setState(() {
      _dragStartX = null;
      _dragStartPosition = null;
      _dragTargetPosition = null;
      _seekPreviewText = '';
    });
    if (ctrl == null || !ctrl.value.isInitialized) {
      // Clear parent _seeking (onSeekStart already set it).
      widget.onSeekEnd(widget.sliderValue.value.clamp(0.0, 1.0));
      return;
    }

    final durMs = ctrl.value.duration.inMilliseconds;
    final ratio = durMs > 0
        ? (targetPos.inMilliseconds / durMs).clamp(0.0, 1.0)
        : 0.0;
    // Commit via parent so progress timer / stall arm stay in sync.
    widget.onSeekEnd(ratio);
  }

  /// Gesture arena lost — the drag never "ends". Clear drag state and let the
  /// parent release _seeking, or the progress bar freezes until the next drag.
  void _onHorizontalDragCancel() {
    if (_dragStartX == null && _dragStartPosition == null) return;
    setState(() {
      _dragStartX = null;
      _dragStartPosition = null;
      _dragTargetPosition = null;
      _seekPreviewText = '';
    });
    widget.onSeekEnd(widget.sliderValue.value.clamp(0.0, 1.0));
  }

  void _togglePlayPause() {
    final c = widget.controller;
    if (c == null || !c.value.isInitialized) return;
    if (c.value.isPlaying) {
      c.pause();
    } else {
      c.play();
    }
  }

  void _onTapScreen() {
    final browserLiveUrl = widget.browserLiveUrl;
    if (browserLiveUrl != null && browserLiveUrl.isNotEmpty) {
      widget.onLiveToggle();
      return;
    }
    if (widget.immersive) {
      setState(() {
        _showExitButton = !_showExitButton;
      });
      _hideTimer?.cancel();
      if (_showExitButton) {
        _hideTimer = Timer(const Duration(seconds: 3), () {
          if (mounted && _showExitButton) {
            setState(() {
              _showExitButton = false;
            });
          }
        });
      }
      return;
    }
    // Portrait: single tap toggles play/pause.
    _togglePlayPause();
  }

  void _onDoubleTapScreen() {
    // Double-tap always toggles play/pause (portrait + landscape).
    _togglePlayPause();
  }

  Widget _buildActivePlayer() {
    final browserLiveUrl = widget.browserLiveUrl;
    if (browserLiveUrl != null && browserLiveUrl.isNotEmpty) {
      return ColoredBox(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            IgnorePointer(
              child: StripchatLiveView(
                roomUrl: browserLiveUrl,
                muted: widget.muted,
                stripchatMode: widget.browserIsStripchat,
              ),
            ),
            if (widget.livePaused)
              IgnorePointer(
                child: Center(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 12,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.pause_circle_outline,
                            color: Color(0xCCFFFFFF),
                            size: 24,
                          ),
                          SizedBox(width: 8),
                          Text(
                            '已暂停',
                            style: TextStyle(
                              color: Color(0xCCFFFFFF),
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    }
    final c = widget.controller;
    if (c != null && c.value.isInitialized) {
      final ar = c.value.aspectRatio;
      return ColoredBox(
        color: Colors.black,
        child: Center(
          child: AspectRatio(
            aspectRatio: (ar.isFinite && ar > 0.05) ? ar : (16 / 9),
            child: VideoPlayer(c),
          ),
        ),
      );
    }
    final i = widget.currentIndex;
    final thumb = (i >= 0 && i < widget.items.length)
        ? widget.items[i].thumb
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
              errorWidget: (_, __, ___) => const SizedBox.shrink(),
            ),
          if (widget.pageLoading)
            const Center(
              child: CircularProgressIndicator(color: Color(0xFFFF6B35)),
            ),
        ],
      ),
    );
  }

  /// Portrait: vertical PageView. Landscape: single surface only.
  /// RotatedBox changes viewport height; PageView pixel offset then maps to
  /// page 0 → first video thumb while audio stays on the real controller.
  Widget _buildVideoSurface() {
    if (widget.immersive) {
      return _buildActivePlayer();
    }
    return PageView.builder(
      controller: widget.pageCtrl,
      scrollDirection: Axis.vertical,
      itemCount: widget.items.length,
      onPageChanged: widget.onPageChanged,
      itemBuilder: (_, i) {
        if (i == widget.currentIndex &&
            (widget.browserLiveUrl != null ||
                (widget.controller != null &&
                    widget.controller!.value.isInitialized))) {
          return _buildActivePlayer();
        }
        final thumb = widget.items[i].thumb;
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
                  errorWidget: (_, __, ___) => const SizedBox.shrink(),
                ),
              if (i == widget.currentIndex && widget.pageLoading)
                const Center(
                  child: CircularProgressIndicator(color: Color(0xFFFF6B35)),
                ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final showFullscreenButton =
        defaultTargetPlatform != TargetPlatform.iOS ||
        context.select<AppSettings, bool>((s) => s.showFullscreenButton);
    final showMuteButton =
        defaultTargetPlatform != TargetPlatform.iOS ||
        context.select<AppSettings, bool>((s) => s.showMuteButton);
    final showFFButton =
        defaultTargetPlatform != TargetPlatform.iOS ||
        context.select<AppSettings, bool>((s) => s.showFastForwardButton);
    return Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          onTap: _onTapScreen,
          onDoubleTap: _onDoubleTapScreen,
          // 横屏手势进度预览仅在全屏/横屏启用：竖屏横向滑动不应触发
          // “±Ns →” 预览覆盖在视频上。
          onHorizontalDragStart: widget.immersive ? _onHorizontalDragStart : null,
          onHorizontalDragUpdate: widget.immersive
              ? _onHorizontalDragUpdate
              : null,
          onHorizontalDragEnd: widget.immersive ? _onHorizontalDragEnd : null,
          onHorizontalDragCancel: widget.immersive
              ? _onHorizontalDragCancel
              : null,
          child: _buildVideoSurface(),
        ),
        // 横屏手势进度预览
        if (_seekPreviewText.isNotEmpty)
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
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
        if (widget.immersive) ...[
          // 横屏：点击屏幕显示/隐藏控制栏
          if (_showExitButton) ...[
            // 退出按钮
            if (showFullscreenButton)
              Positioned(
                right: 16,
                top: 16,
                child: SafeArea(
                  child: GestureDetector(
                    onTap: widget.onFullscreen,
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
                  onTap: widget.onOpenSettings,
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
            // 横屏：快进 30 秒按钮（左下角）
            if (showFFButton)
              Positioned(
                left: 16,
                bottom: 76,
                child: SafeArea(
                  child: GestureDetector(
                    onTap: widget.onFastForward,
                    child: Icon(
                      Icons.forward_30,
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
                child: RepaintBoundary(
                  child: FeedProgressBar(
                    slider: widget.sliderValue,
                    curTime: widget.currentTime,
                    totalTime: widget.totalTime,
                    onChanged: widget.onSeekPreview,
                    onChangeStart: (_) => widget.onSeekStart(),
                    onChangeEnd: widget.onSeekEnd,
                  ),
                ),
              ),
            ),
          ],
        ] else ...[
          _buildTopBar(showFullscreenButton: showFullscreenButton),
          // 竖屏：设置按钮（上移到标题行，半透明，无背景）
          Positioned(
            right: 10,
            top: 8,
            child: SafeArea(
              child: _MinimalButton(
                storageKey: 'settings_button_normal',
                defaultOffset: const Offset(10, 8),
                icon: Icons.settings,
                onTap: widget.onOpenSettings,
              ),
            ),
          ),
          // 竖屏：全屏按钮（上移到标题行，半透明，无背景）
          Positioned(
            right: 50,
            top: 8,
            child: SafeArea(
              child: showFullscreenButton
                  ? Opacity(
                      opacity: 0.42,
                      child: _MinimalButton(
                        storageKey: 'fullscreen_button_normal',
                        defaultOffset: const Offset(50, 8),
                        icon: Icons.fullscreen,
                        onTap: widget.onFullscreen,
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
          // 竖屏：快进 30 秒按钮（半透明，无背景，左下角）
          Positioned(
            left: 10,
            bottom: 80,
            child: SafeArea(
              child: showFFButton
                  ? _MinimalButton(
                      storageKey: 'ff_button_normal',
                      defaultOffset: const Offset(10, 80),
                      icon: Icons.forward_30,
                      onTap: widget.onFastForward,
                    )
                  : const SizedBox.shrink(),
            ),
          ),
          // 竖屏：音量按钮（半透明，无背景）
          Positioned(
            right: 10,
            bottom: 80,
            child: SafeArea(
              child: showMuteButton
                  ? _MinimalButton(
                      storageKey: 'mute_button_normal',
                      defaultOffset: const Offset(10, 80),
                      icon: widget.muted ? Icons.volume_off : Icons.volume_up,
                      onTap: widget.onMute,
                    )
                  : const SizedBox.shrink(),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              child: RepaintBoundary(
                child: FeedProgressBar(
                  slider: widget.sliderValue,
                  curTime: widget.currentTime,
                  totalTime: widget.totalTime,
                  onChanged: widget.onSeekPreview,
                  onChangeStart: (_) => widget.onSeekStart(),
                  onChangeEnd: widget.onSeekEnd,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildTopBar({required bool showFullscreenButton}) {
    final title = widget.titleText.isNotEmpty
        ? widget.titleText
        : (widget.currentIndex < widget.items.length
              ? widget.items[widget.currentIndex].title
              : '');
    return Positioned(
      left: 10,
      right: showFullscreenButton ? 96 : 56,
      top: 8,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                shadows: [Shadow(color: Colors.black87, blurRadius: 4)],
              ),
            ),
            if (!widget.immersive)
              ValueListenableBuilder<String>(
                valueListenable: widget.speedLabel,
                builder: (_, label, __) {
                  if (label.isEmpty) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black38,
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1,
                        ),
                        child: Text(
                          label,
                          style: const TextStyle(
                            color: Color(0xFF66D9A0),
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }
}

/// 极简按钮：半透明图标，无背景，支持长按拖动
class _MinimalButton extends StatefulWidget {
  const _MinimalButton({
    required this.storageKey,
    required this.defaultOffset,
    required this.icon,
    required this.onTap,
  });

  final String storageKey;
  final Offset defaultOffset;
  final IconData icon;
  final VoidCallback onTap;

  @override
  State<_MinimalButton> createState() => _MinimalButtonState();
}

class _MinimalButtonState extends State<_MinimalButton> {
  Offset? _savedOffset;
  bool _isDragging = false;
  Offset _currentDragOffset = Offset.zero;
  Offset _dragStartOffset = Offset.zero;
  // 拖拽时高频更新，用 ValueNotifier 驱动偏移，避免整棵子树重建。
  final ValueNotifier<Offset> _offsetNotifier = ValueNotifier<Offset>(
    Offset.zero,
  );
  final ValueNotifier<bool> _pressingNotifier = ValueNotifier<bool>(false);
  Size? _viewportSize;
  EdgeInsets? _viewportPadding;

  @override
  void initState() {
    super.initState();
    _loadOffset();
  }

  @override
  void dispose() {
    _offsetNotifier.dispose();
    _pressingNotifier.dispose();
    super.dispose();
  }

  Future<void> _loadOffset() async {
    final prefs = await SharedPreferences.getInstance();
    final x = prefs.getDouble('${widget.storageKey}_offset_x');
    final y = prefs.getDouble('${widget.storageKey}_offset_y');
    if (x != null && y != null && mounted) {
      _savedOffset = Offset(x, y);
      _offsetNotifier.value = _savedOffset!;
    }
  }

  Future<void> _saveOffset(Offset offset) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('${widget.storageKey}_offset_x', offset.dx);
    await prefs.setDouble('${widget.storageKey}_offset_y', offset.dy);
  }

  Offset _clampOffset(Offset o) {
    final size =
        _viewportSize ?? const Size(double.maxFinite, double.maxFinite);
    final pad = _viewportPadding ?? EdgeInsets.zero;
    return Offset(
      o.dx.clamp(
        -widget.defaultOffset.dx,
        size.width - widget.defaultOffset.dx - 40 - pad.right,
      ),
      o.dy.clamp(
        -widget.defaultOffset.dy,
        size.height - widget.defaultOffset.dy - 40 - pad.bottom,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 只在尺寸/padding 真正变化时刷新缓存，拖拽 move 不再触发 MediaQuery/build。
    final mq = MediaQuery.of(context);
    _viewportSize = mq.size;
    _viewportPadding = mq.padding;

    return ValueListenableBuilder<Offset>(
      valueListenable: _offsetNotifier,
      builder: (_, displayOffset, __) => Transform.translate(
        offset: displayOffset,
        child: GestureDetector(
          onTap: _isDragging ? null : widget.onTap,
          onLongPressStart: (details) {
            _isDragging = true;
            _pressingNotifier.value = true;
            _dragStartOffset = _savedOffset ?? Offset.zero;
            _offsetNotifier.value = _dragStartOffset;
          },
          onLongPressMoveUpdate: (details) {
            if (!_isDragging) return;
            _currentDragOffset = _clampOffset(
              _dragStartOffset + details.offsetFromOrigin,
            );
            _offsetNotifier.value = _currentDragOffset;
          },
          onLongPressEnd: (details) {
            _savedOffset = _currentDragOffset;
            _isDragging = false;
            _pressingNotifier.value = false;
            _saveOffset(_currentDragOffset);
          },
          child: ValueListenableBuilder<bool>(
            valueListenable: _pressingNotifier,
            builder: (_, pressing, __) => AnimatedScale(
              scale: pressing ? 1.2 : 1.0,
              duration: const Duration(milliseconds: 150),
              child: Icon(
                widget.icon,
                color: pressing
                    ? Colors.white.withValues(alpha: 0.9)
                    : Colors.white.withValues(alpha: 0.5),
                size: 28,
                shadows: const [Shadow(color: Colors.black45, blurRadius: 4)],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Immersive UI chrome. Landscape is primarily **visual** (RotatedBox) so it
/// still works under iOS Control Center orientation lock. System orientation
/// is still requested when possible for a cleaner native rotate.
class PlayerChrome extends ChangeNotifier {
  bool _immersive = false;

  /// null = portrait; otherwise which way the device is (or was) tilted.
  DeviceOrientation? _landscapeSide;

  bool get immersive => _immersive;

  DeviceOrientation? get landscapeSide => _landscapeSide;

  bool get _isAndroid {
    try {
      return !kIsWeb && Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

  Future<void> enterFullscreen(
      {DeviceOrientation? preferredOrientation}) async {
    final side = preferredOrientation ??
        _landscapeSide ??
        DeviceOrientation.landscapeLeft;
    final sideChanged = _landscapeSide != side;
    _landscapeSide = side;
    if (_immersive) {
      if (sideChanged) notifyListeners();
      if (!_isAndroid) {
        try {
          await SystemChrome.setPreferredOrientations([side]);
        } catch (_) {}
      }
      return;
    }
    _immersive = true;
    notifyListeners();
    try {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } catch (_) {}
    // iOS: request real landscape when lock is off. Android: visual-only
    // (forced orientation historically crashy on some Android 15 hosts).
    if (!_isAndroid) {
      try {
        await SystemChrome.setPreferredOrientations([side]);
      } catch (_) {}
    }
  }

  Future<void> exitFullscreen() async {
    if (!_immersive && _landscapeSide == null) return;
    _immersive = false;
    _landscapeSide = null;
    notifyListeners();
    try {
      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: SystemUiOverlay.values,
      );
    } catch (_) {}
    if (!_isAndroid) {
      try {
        await SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      } catch (_) {}
    }
  }

  Future<void> toggleFullscreen(
      {DeviceOrientation? preferredOrientation}) async {
    if (_immersive) {
      await exitFullscreen();
    } else {
      await enterFullscreen(preferredOrientation: preferredOrientation);
    }
  }

  Future<void> ensurePortraitChrome() async {
    if (_immersive || _landscapeSide != null) {
      await exitFullscreen();
    }
  }

  /// Wraps [child] so the picture is landscape even if the OS stays portrait
  /// (e.g. Control Center portrait lock). If the system already rotated
  /// (width > height), returns [child] as-is to avoid double rotation.
  Widget wrapBody(BuildContext context, Widget child) {
    if (!_immersive) return child;
    final mq = MediaQuery.of(context);
    final size = mq.size;
    // System already landscape — avoid double rotation.
    if (size.width > size.height) return child;

    final turns = _landscapeSide == DeviceOrientation.landscapeRight ? 3 : 1;
    final w = size.height;
    final h = size.width;
    // Remap safe insets for the rotated frame (notch / home indicator).
    final EdgeInsets pad;
    final EdgeInsets viewPad;
    if (turns == 1) {
      // 90° CW: 子树左缘贴物理顶、上缘贴物理右、下缘贴物理左
      pad = EdgeInsets.only(
        left: mq.padding.top,
        top: mq.padding.right,
        right: mq.padding.bottom,
        bottom: mq.padding.left,
      );
      viewPad = EdgeInsets.only(
        left: mq.viewPadding.top,
        top: mq.viewPadding.right,
        right: mq.viewPadding.bottom,
        bottom: mq.viewPadding.left,
      );
    } else {
      // 90° CCW: 子树左缘贴物理底、上缘贴物理左、下缘贴物理右
      pad = EdgeInsets.only(
        left: mq.padding.bottom,
        top: mq.padding.left,
        right: mq.padding.top,
        bottom: mq.padding.right,
      );
      viewPad = EdgeInsets.only(
        left: mq.viewPadding.bottom,
        top: mq.viewPadding.left,
        right: mq.viewPadding.top,
        bottom: mq.viewPadding.right,
      );
    }
    // OverflowBox lets RotatedBox paint a landscape-sized child inside a
    // portrait parent without layout overflow / clipping issues.
    return OverflowBox(
      minWidth: w,
      maxWidth: w,
      minHeight: h,
      maxHeight: h,
      alignment: Alignment.center,
      child: RotatedBox(
        quarterTurns: turns,
        child: SizedBox(
          width: w,
          height: h,
          child: MediaQuery(
            data: mq.copyWith(
              size: Size(w, h),
              padding: pad,
              viewPadding: viewPad,
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

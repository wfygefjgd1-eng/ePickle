import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';

enum AutoRotateAction {
  enterLandscape,
  exitLandscape,

  /// Already landscape; only the left/right side changed.
  switchSide,
}

/// Gravity tilt → landscape enter/exit with hysteresis + dwell + cooldown.
///
/// Enter only when nearly fully landscape; exit only when clearly portrait.
/// Mid band does nothing (no jitter flip-flop).
class AutoRotateController {
  AutoRotateController({
    required this.onAction,
    this.enterDegrees = 78,
    this.exitDegrees = 22,
    this.dwell = const Duration(milliseconds: 700),
    this.cooldown = const Duration(milliseconds: 1800),
    this.sideSwitchDwell = const Duration(milliseconds: 450),
  });

  final void Function(AutoRotateAction action, DeviceOrientation? side)
      onAction;

  /// θ from vertical: 0° ≈ upright, 90° ≈ fully sideways.
  final double enterDegrees;
  final double exitDegrees;
  final Duration dwell;
  final Duration cooldown;
  final Duration sideSwitchDwell;

  bool enabled = true;

  /// When false, ignore tilt (inactive tab / background).
  bool listening = true;

  bool _landscapeMode = false;
  DeviceOrientation? _appliedSide;

  /// Manual fullscreen while upright: block auto-exit until once landscape.
  bool _holdExitUntilLandscape = false;

  StreamSubscription<AccelerometerEvent>? _sub;
  DateTime? _candidateSince;
  bool? _candidateLandscape;
  DeviceOrientation? _candidateSide;
  DateTime? _lastSwitch;

  double _fx = 0;
  double _fy = 0;
  double _fz = 0;
  bool _filterInit = false;

  bool get landscapeMode => _landscapeMode;

  DeviceOrientation? get lastSide {
    if (_appliedSide != null) return _appliedSide;
    if (!_filterInit) return null;
    return _sideFromFiltered();
  }

  DeviceOrientation _sideFromFiltered() {
    // x>0 ≈ home-button-right on most phones → landscapeRight in Flutter terms.
    return _fx >= 0
        ? DeviceOrientation.landscapeRight
        : DeviceOrientation.landscapeLeft;
  }

  void syncLandscapeMode(
    bool value, {
    bool fromUser = false,
    DeviceOrientation? side,
  }) {
    _landscapeMode = value;
    _candidateSince = null;
    _candidateLandscape = null;
    _candidateSide = null;
    if (value) {
      _appliedSide = side ?? _appliedSide ?? lastSide;
      if (fromUser) {
        _holdExitUntilLandscape = true;
        // Cooldown so auto-exit can't fight the tap immediately.
        _lastSwitch = DateTime.now();
      }
    } else {
      _holdExitUntilLandscape = false;
      _appliedSide = null;
      if (fromUser) {
        // Still physically landscape after manual exit → don't snap back in.
        _lastSwitch = DateTime.now();
      }
    }
  }

  void start() {
    if (_sub != null) return;
    _sub = accelerometerEventStream(
      samplingPeriod: SensorInterval.uiInterval,
    ).listen(_onEvent, onError: (_) {});
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    _candidateSince = null;
    _candidateLandscape = null;
    _candidateSide = null;
    // Keep filter state so lastSide stays useful after brief pause.
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
    _candidateSince = null;
    _candidateLandscape = null;
    _candidateSide = null;
    _filterInit = false;
  }

  void _onEvent(AccelerometerEvent e) {
    if (!enabled || !listening) return;

    const alpha = 0.18;
    if (!_filterInit) {
      _fx = e.x;
      _fy = e.y;
      _fz = e.z;
      _filterInit = true;
    } else {
      _fx = alpha * e.x + (1 - alpha) * _fx;
      _fy = alpha * e.y + (1 - alpha) * _fy;
      _fz = alpha * e.z + (1 - alpha) * _fz;
    }

    final mag = math.sqrt(_fx * _fx + _fy * _fy + _fz * _fz);
    if (mag < 7.0 || mag > 12.5) {
      _candidateSince = null;
      return;
    }
    if (_fz.abs() / mag > 0.82) {
      _candidateSince = null;
      return;
    }

    final theta = math.atan2(_fx.abs(), _fy.abs()) * 180 / math.pi;
    final now = DateTime.now();
    final side = _sideFromFiltered();

    if (_holdExitUntilLandscape && theta >= enterDegrees) {
      _holdExitUntilLandscape = false;
    }

    final inCooldown =
        _lastSwitch != null && now.difference(_lastSwitch!) < cooldown;

    // Left ↔ right while already landscape (shorter dwell, no full exit).
    if (_landscapeMode &&
        !_holdExitUntilLandscape &&
        theta >= enterDegrees &&
        _appliedSide != null &&
        side != _appliedSide) {
      if (inCooldown) return;
      if (_candidateLandscape != null || _candidateSide != side) {
        _candidateLandscape = null;
        _candidateSide = side;
        _candidateSince = now;
        return;
      }
      final since = _candidateSince;
      if (since == null) {
        _candidateSince = now;
        return;
      }
      if (now.difference(since) < sideSwitchDwell) return;
      _candidateSince = null;
      _candidateSide = null;
      _lastSwitch = now;
      onAction(AutoRotateAction.switchSide, side);
      return;
    }

    if (inCooldown) return;

    final bool? want;
    if (!_landscapeMode && theta >= enterDegrees) {
      want = true;
    } else if (_landscapeMode &&
        !_holdExitUntilLandscape &&
        theta <= exitDegrees) {
      want = false;
    } else {
      _candidateSince = null;
      _candidateLandscape = null;
      _candidateSide = null;
      return;
    }

    if (_candidateLandscape != want ||
        (want == true && _candidateSide != side)) {
      _candidateLandscape = want;
      _candidateSide = side;
      _candidateSince = now;
      return;
    }

    final since = _candidateSince;
    if (since == null) {
      _candidateSince = now;
      return;
    }
    if (now.difference(since) < dwell) return;

    _candidateSince = null;
    _candidateLandscape = null;
    _candidateSide = null;
    _lastSwitch = now;

    onAction(
      want == true
          ? AutoRotateAction.enterLandscape
          : AutoRotateAction.exitLandscape,
      want == true ? side : null,
    );
  }

  void confirmAction(AutoRotateAction action, {DeviceOrientation? side}) {
    switch (action) {
      case AutoRotateAction.enterLandscape:
        _landscapeMode = true;
        _holdExitUntilLandscape = false;
        if (side != null) _appliedSide = side;
        break;
      case AutoRotateAction.exitLandscape:
        _landscapeMode = false;
        _holdExitUntilLandscape = false;
        _appliedSide = null;
        break;
      case AutoRotateAction.switchSide:
        if (side != null) _appliedSide = side;
        break;
    }
  }

  void rejectAction() {
    _candidateSince = null;
    _candidateLandscape = null;
    _candidateSide = null;
    _lastSwitch = null;
  }
}

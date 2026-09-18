import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// In-app WebView player (Stripchat rooms + generic site fallback).
///
/// Critical Android behavior:
/// - Default [AndroidView] steals ALL pointers → vertical PageView cannot swipe.
/// - We use transparent hit-test + [IgnorePointer] so Flutter owns gestures.
/// - Mute / stall recovery go through MethodChannel + injected JS only.
///
/// Trade-off: users cannot tap age-gate buttons inside the site. Native JS
/// already auto-clicks common 18+/Enter buttons when focusing video.
class StripchatLiveView extends StatelessWidget {
  const StripchatLiveView({
    super.key,
    required this.roomUrl,
    required this.muted,
    this.stripchatMode = true,
  });

  final String roomUrl;
  final bool muted;
  final bool stripchatMode;

  static const _control = MethodChannel('epickle/stripchat_live_control');

  static void _ignorePlatformError(Object _) {}

  /// Native overlay's "跳过" (skip) button invokes 'skip' on [_control].
  /// Without a Dart-side handler the button does nothing — Android fires the
  /// method and the reply silently reports notImplemented.
  ///
  /// Handlers are keyed by owner: SiteFeedPage keeps every tab's
  /// VideoFeedScreen alive in an IndexedStack, so a single global handler
  /// would leave only the last-mounted tab's callback armed (its own guard
  /// no-ops because it is offstage). With the registry, 'skip' is fanned out
  /// to every live screen and each one self-guards on
  /// `_canRun && _browserLiveUrl != null` — only the actually-streaming tab
  /// acts (tab switching stops all other feeds, so at most one matches).
  static final Map<Object, void Function()> _skipHandlers = {};

  static void setSkipHandler(Object owner, void Function()? onSkip) {
    if (onSkip == null) {
      _skipHandlers.remove(owner);
    } else {
      _skipHandlers[owner] = onSkip;
    }
    _control.setMethodCallHandler(
      _skipHandlers.isEmpty
          ? null
          : (call) async {
              if (call.method == 'skip') {
                for (final handler in List.of(_skipHandlers.values)) {
                  handler();
                }
              }
              return null;
            },
    );
  }

  static Future<void> setMuted(bool muted) async {
    try {
      await _control.invokeMethod<void>('setMuted', muted);
    } on PlatformException catch (error) {
      _ignorePlatformError(error);
    } on MissingPluginException catch (error) {
      _ignorePlatformError(error);
    }
  }

  static Future<void> kickPlayback() async {
    try {
      await _control.invokeMethod<void>('kickPlayback');
    } on PlatformException catch (error) {
      _ignorePlatformError(error);
    } on MissingPluginException catch (error) {
      _ignorePlatformError(error);
    }
  }

  static Future<void> pauseLive() async {
    try {
      await _control.invokeMethod<void>('pauseLive');
    } on PlatformException catch (error) {
      _ignorePlatformError(error);
    } on MissingPluginException catch (error) {
      _ignorePlatformError(error);
    }
  }

  static Future<void> resumeLive() async {
    try {
      await _control.invokeMethod<void>('resumeLive');
    } on PlatformException catch (error) {
      _ignorePlatformError(error);
    } on MissingPluginException catch (error) {
      _ignorePlatformError(error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final viewType = 'epickle/stripchat_live';
    final params = <String, dynamic>{
      'url': roomUrl,
      'muted': muted,
      'stripchatMode': stripchatMode,
    };

    if (Platform.isIOS) {
      return UiKitView(
          key: ValueKey(roomUrl),
          viewType: viewType,
          layoutDirection: TextDirection.ltr,
          creationParams: params,
          creationParamsCodec: const StandardMessageCodec(),
      );
    }

    return AndroidView(
      key: ValueKey(roomUrl),
      viewType: viewType,
      layoutDirection: TextDirection.ltr,
      creationParams: params,
      creationParamsCodec: const StandardMessageCodec(),
      // Taps go to WebView; vertical drags can still be claimed by PageView.
      gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
    );
  }
}

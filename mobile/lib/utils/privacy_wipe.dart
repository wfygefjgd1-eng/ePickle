import 'package:flutter/services.dart';

/// Native privacy wipe: clears WebView data, cookies, cache, prefs, keychain.
class PrivacyWipe {
  static const _channel = MethodChannel('privacy_browser/engine');

  static Future<void> nuclearWipe() async {
    try {
      await _channel.invokeMethod<void>('nuclearWipe');
    } on PlatformException {
      // channel may be unavailable on some platforms; ignore
    } on MissingPluginException {
      // not registered; ignore
    } catch (_) {
      // A non-conforming channel reply (TypeError etc.) must never interrupt
      // the wipe flow mid-exit.
    }
  }

  /// Lightweight per-launch wipe: clears WebView caches and URLCache only.
  /// Cookies, localStorage, preferences, history and keychain are preserved.
  static Future<void> clearLaunchCache() async {
    try {
      await _channel.invokeMethod<void>('clearLaunchCache');
    } on PlatformException {
      // channel may be unavailable on some platforms; ignore
    } on MissingPluginException {
      // not registered; ignore
    } catch (_) {
      // See nuclearWipe.
    }
  }

  static Future<void> exitApp() async {
    try {
      await _channel.invokeMethod<void>('exitApp');
    } on PlatformException {
      // ignore
    } on MissingPluginException {
      // ignore
    } catch (_) {
      // See nuclearWipe.
    }
  }
}

import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_player.dart';
import 'services/app_settings.dart';
import 'services/cache_manager.dart';
import 'services/layout_settings.dart';
import 'services/watch_history.dart';
import 'utils/http_client.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Smoother scrolling on high-refresh displays (paired with native mode pick).
  if (Platform.isAndroid) {
    // ignore: unawaited_futures
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  // Android: Dio must learn system HTTP proxy before first feed request.
  // WebView already follows system proxy; Dart HttpClient does not.
  await AppHttpClient.refreshSystemProxy();

  final settings = AppSettings();
  final layout = LayoutSettings();
  final history = WatchHistory();

  // Load prefs in parallel: they are independent, and cold start pays only the
  // slowest of the three platform-channel/disk latencies instead of their sum.
  await Future.wait([
    settings.load(),
    layout.load(),
    history.load(),
  ]);

  runApp(PlayerApp(
    settings: settings,
    layout: layout,
    history: history,
  ));

  // Wipe transient caches on every cold start so disk usage never grows
  // unbounded (the app has no download feature). Deferred to after the first
  // frame so the recursive temp-dir scan never competes with first paint.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    // ignore: unawaited_futures
    CacheManager.clearOnLaunch();
  });
}

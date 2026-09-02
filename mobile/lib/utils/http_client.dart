import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import 'http_headers.dart';
import 'system_proxy.dart';

/// Shared Dio factory.
///
/// Android note: Dart HttpClient does NOT follow system proxy/VPN UI the way
/// WebView does. We therefore:
/// 1) use user manual proxy if set
/// 2) else use Android system proxy (Clash/V2Ray 系统代理)
/// 3) else DIRECT (TUN mode / no proxy)
class AppHttpClient {
  AppHttpClient._();

  static bool proxyEnabled = false;
  static String proxyHost = '';
  static int proxyPort = 0;
  static String proxyType = 'http';

  /// Auto-detected system proxy (Android/iOS). Used when no manual proxy.
  static String? _systemHost;
  static int _systemPort = 0;
  static String _systemType = 'http';
  static DateTime? _lastSystemProxyRefresh;

  /// In-flight detection future so concurrent callers join the same native
  /// lookup instead of each triggering (or skipping) a separate one.
  static Future<void>? _detecting;

  /// Cached detection result for UIs that only need to display it.
  static String? get systemHost => _systemHost;
  static int get systemPort => _systemPort;

  static void applyProxyConfig({
    required bool enabled,
    required String host,
    required int port,
    required String type,
  }) {
    proxyHost = host.trim();
    proxyPort = (port > 0 && port < 65536) ? port : 0;
    proxyType = type == 'socks5' ? 'socks5' : 'http';
    proxyEnabled = enabled && proxyHost.isNotEmpty && proxyPort > 0;
  }

  /// Refresh Android/iOS system proxy for Dio. Safe to call often; throttled
  /// to at most one native lookup every 3 seconds. Concurrent callers wait on
  /// the same in-flight detection, so the first request that needs the proxy
  /// (or awaits this) never races a stale value. [markProxySuspect] clears the
  /// throttle so a stale proxy is re-detected on the very next call.
  static Future<void> refreshSystemProxy() {
    final last = _lastSystemProxyRefresh;
    final detecting = _detecting;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 3) &&
        detecting == null) {
      return Future<void>.value();
    }
    if (detecting != null) return detecting;
    final future = _detectSystemProxy();
    _detecting = future;
    return future.whenComplete(() {
      _detecting = null;
      _lastSystemProxyRefresh = DateTime.now();
    });
  }

  static Future<void> _detectSystemProxy() async {
    try {
      final info = await SystemProxy.detect();
      if (info != null) {
        _systemHost = info.host;
        _systemPort = info.port;
        _systemType = info.type;
      } else {
        _systemHost = null;
        _systemPort = 0;
        _systemType = 'http';
      }
    } catch (_) {
      _systemHost = null;
      _systemPort = 0;
    }
  }

  /// Requests failing with connect/receive timeouts often mean the cached
  /// proxy went stale (proxy app restarted, port changed). Clear the throttle
  /// timestamp so the next [refreshSystemProxy] re-detects immediately.
  static void markProxySuspect() {
    _lastSystemProxyRefresh = null;
  }

  // Dart's HttpClient understands only PROXY (HTTP CONNECT) and DIRECT
  // entries; a "SOCKS5 host:port" entry makes it throw FormatException on
  // EVERY request (dart:io has no SOCKS support). So a detected/manual SOCKS
  // proxy must degrade to DIRECT — in VPN/TUN mode the traffic still rides
  // the proxy tool transparently, and a format exception would otherwise
  // look exactly like "the proxy tool is not connected at all".
  static String _findProxy(Uri uri) {
    // 1) Manual proxy wins.
    if (proxyEnabled && proxyHost.isNotEmpty && proxyPort > 0) {
      if (proxyType == 'socks5') return 'DIRECT';
      return 'PROXY ${proxyHost}:${proxyPort}; DIRECT';
    }
    // 2) Android/iOS system proxy (browser works; Dio must be told explicitly).
    final sh = _systemHost;
    if (sh != null && sh.isNotEmpty && _systemPort > 0) {
      if (_systemType == 'socks5') return 'DIRECT';
      return 'PROXY $sh:$_systemPort; DIRECT';
    }
    // 3) TUN / clean device.
    return 'DIRECT';
  }

  static Dio create({
    Map<String, dynamic>? headers,
    Duration connectTimeout = const Duration(seconds: 18),
    Duration receiveTimeout = const Duration(seconds: 28),
    CancelToken? cancelToken,
  }) {
    // Re-detect system proxy on every client creation so proxy app restarts /
    // config changes are picked up promptly (throttled inside refreshSystemProxy).
    // ignore: discarded_futures
    refreshSystemProxy();

    final dio = Dio(
      BaseOptions(
        connectTimeout: connectTimeout,
        receiveTimeout: receiveTimeout,
        headers: {
          ...AppHttpHeaders.browser,
          if (headers != null) ...headers,
        },
        followRedirects: true,
        maxRedirects: 8,
        validateStatus: (s) => s != null && s < 500,
        responseType: ResponseType.plain,
      ),
    );

    if (cancelToken != null) {
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            options.cancelToken = cancelToken;
            handler.next(options);
          },
        ),
      );
    }

    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.connectionTimeout = connectTimeout;
        client.idleTimeout = const Duration(seconds: 30);
        client.autoUncompress = true;
        client.userAgent = AppHttpHeaders.userAgent;
        // Critical on Android: without this, Dio ignores system HTTP proxy
        // while WebView still works → "browser OK, app lists fail".
        client.findProxy = _findProxy;
        return client;
      },
    );

    return dio;
  }
}

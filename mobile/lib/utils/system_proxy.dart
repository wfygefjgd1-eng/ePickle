import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Detected system / environment proxy. No hardcoded vendor ports.
class SystemProxyInfo {
  const SystemProxyInfo({
    required this.host,
    required this.port,
    required this.type,
    required this.source,
  });

  final String host;
  final int port;

  /// http | socks5
  final String type;
  final String source;

  @override
  String toString() => '$type $host:$port ($source)';
}

class SystemProxy {
  SystemProxy._();

  static const _channel = MethodChannel('epickle/system_proxy');

  /// Android: read system HTTP proxy (Clash/V2Ray 系统代理).
  /// iOS: read system HTTP proxy (Shadowrocket/Quantumult X 系统代理).
  /// Other platforms: only env vars. TUN mode usually has no proxy → null → DIRECT.
  static Future<SystemProxyInfo?> detect() async {
    if (kIsWeb) return null;

    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      try {
        final raw = await _channel.invokeMethod<dynamic>('getSystemProxy');
        if (raw is Map) {
          final host = raw['host']?.toString();
          final port = int.tryParse('${raw['port']}');
          final type = raw['type']?.toString() == 'socks5' ? 'socks5' : 'http';
          final source = raw['source']?.toString() ?? 'system';
          if (host != null &&
              host.isNotEmpty &&
              port != null &&
              port > 0 &&
              port < 65536 &&
              source != 'none') {
            return SystemProxyInfo(
              host: host,
              port: port,
              type: type,
              source: source,
            );
          }
        }
      } catch (_) {}
    }

    try {
      final env = Platform.environment;
      for (final key in [
        'https_proxy',
        'HTTPS_PROXY',
        'http_proxy',
        'HTTP_PROXY',
        'all_proxy',
        'ALL_PROXY',
      ]) {
        final v = env[key];
        if (v == null || v.trim().isEmpty) continue;
        final parsed = _parseProxyUri(v.trim());
        if (parsed != null) return parsed;
      }
    } catch (_) {}

    return null;
  }

  static SystemProxyInfo? _parseProxyUri(String raw) {
    try {
      var s = raw;
      if (!s.contains('://')) s = 'http://$s';
      final u = Uri.parse(s);
      final host = u.host;
      if (host.isEmpty) return null;
      if (!u.hasPort || u.port <= 0 || u.port > 65535) return null;
      final scheme = u.scheme.toLowerCase();
      final type = scheme.contains('socks') ? 'socks5' : 'http';
      return SystemProxyInfo(
        host: host,
        port: u.port,
        type: type,
        source: 'env',
      );
    } catch (_) {
      return null;
    }
  }
}

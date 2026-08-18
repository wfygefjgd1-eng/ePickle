import 'package:flutter/services.dart';

class NativeBrowserHttpResponse {
  const NativeBrowserHttpResponse({
    required this.statusCode,
    required this.body,
    required this.finalUrl,
    required this.cookies,
  });

  final int statusCode;
  final String body;
  final String finalUrl;
  final Map<String, String> cookies;
}

/// Native HTTP fallback (URLSession on iOS, HttpURLConnection on Android)
/// for sites that reject Dart HttpClient's TLS stack.
/// Keeps native redirect/cookie session used by subsequent fallback requests.
class NativeBrowserHttp {
  NativeBrowserHttp._();

  static const _channel = MethodChannel('epickle/browser_http');
  static bool _renderBusy = false;

  static Future<NativeBrowserHttpResponse?> get(
    String url, {
    required Map<String, String> headers,
    required Duration timeout,
  }) async {
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>('get', {
        'url': url,
        'headers': headers,
        'timeoutMs': timeout.inMilliseconds,
      });
      if (raw == null) return null;
      return _parse(url, raw);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Uses the app's real WebView engine when a page needs JavaScript or a
  /// browser challenge before its final DOM becomes available.
  static Future<NativeBrowserHttpResponse?> render(
    String url, {
    required Map<String, String> headers,
    required Duration timeout,
  }) async {
    if (_renderBusy) return null;
    _renderBusy = true;
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>('renderGet', {
        'url': url,
        'headers': headers,
        'timeoutMs': timeout.inMilliseconds,
      });
      if (raw == null) return null;
      return _parse(url, raw);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    } finally {
      _renderBusy = false;
    }
  }

  /// Native GET returning raw binary bytes (URLSession), for image/CDN hosts
  /// that reject Dart HttpClient's TLS stack. Same cookie/session as `get`.
  /// When [aesKeyHex]/[aesIvHex] are given the native side decrypts the body
  /// (AES-128-CBC, no padding) before returning — used by HuangGuo media
  /// whose "images" are ciphertext until decrypted with the site's keys.
  static Future<Uint8List?> getBytes(
    String url, {
    required Map<String, String> headers,
    required Duration timeout,
    String? aesKeyHex,
    String? aesIvHex,
  }) async {
    try {
      final raw = await _channel
          .invokeMethod<Uint8List>('getBytes', {
            'url': url,
            'headers': headers,
            'timeoutMs': timeout.inMilliseconds,
            if (aesKeyHex != null) 'aesKeyHex': aesKeyHex,
            if (aesIvHex != null) 'aesIvHex': aesIvHex,
          });
      return raw;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  static NativeBrowserHttpResponse _parse(String url, Map<String, dynamic> raw) {
    final cookieMap = <String, String>{};
    final cookies = raw['cookies'];
    if (cookies is Map) {
      for (final entry in cookies.entries) {
        cookieMap[entry.key.toString()] = entry.value.toString();
      }
    }
    return NativeBrowserHttpResponse(
      statusCode: (raw['statusCode'] as num?)?.toInt() ?? 0,
      body: raw['body']?.toString() ?? '',
      finalUrl: raw['finalUrl']?.toString() ?? url,
      cookies: cookieMap,
    );
  }
}

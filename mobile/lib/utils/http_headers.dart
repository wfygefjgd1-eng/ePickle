/// Shared browser-like headers for CDN / site requests.
class AppHttpHeaders {
  /// Match the iOS Safari engine used by the app's browser fallback.
  static const String userAgent =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 '
      'Mobile/15E148 Safari/604.1';

  static const Map<String, String> browser = {
    'User-Agent': userAgent,
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,'
        'image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7',
    'Accept-Language': 'en-US,en;q=0.9,zh-CN;q=0.8,zh;q=0.7',
    'Accept-Encoding': 'gzip, deflate',
    'Cache-Control': 'no-cache',
    'Pragma': 'no-cache',
    'Upgrade-Insecure-Requests': '1',
  };

  /// Headers for a page fetch with correct site origin/referer.
  static Map<String, String> forSite(String baseUrl) {
    final base = baseUrl.replaceAll(RegExp(r'/$'), '');
    final origin = _origin(base) ?? base;
    return {
      ...browser,
      'Referer': '$origin/',
    };
  }

  /// Thumb / stream headers by media URL host (or page host).
  static Map<String, String> forMediaUrl(String? url, {String? pageUrl}) {
    final pageOrigin = _origin(pageUrl ?? '');
    final u = (url ?? '').toLowerCase();

    String? siteOrigin;
    if (u.contains('xvideos') ||
        u.contains('xvideos-cdn') ||
        u.contains('xnxx')) {
      siteOrigin = 'https://www.xvideos.com';
    } else if (u.contains('mitao') ||
        u.contains('mitaohk') ||
        u.contains('jipinvipplay')) {
      siteOrigin = 'https://mitaohk.com';
    } else if (u.contains('huangguoai') ||
        u.contains('yd-hls') ||
        u.contains('yrfmba')) {
      siteOrigin = 'https://huangguoai.com';
    } else if (u.contains('pornhub') ||
        u.contains('phncdn') ||
        u.contains('porncdn')) {
      siteOrigin = 'https://www.pornhub.com';
    } else if (u.contains('youporn') || u.contains('ypncdn')) {
      siteOrigin = 'https://www.youporn.com';
    } else if (u.contains('redtube') || u.contains('rdtcdn')) {
      siteOrigin = 'https://www.redtube.com';
    } else if (u.contains('eporner')) {
      siteOrigin = 'https://www.eporner.com';
    } else if (u.contains('spankbang')) {
      siteOrigin = 'https://spankbang.com';
    } else if (u.contains('xhamster')) {
      siteOrigin = 'https://xhamster.com';
    } else if (u.contains('chaturbate') ||
        u.contains('highwebmedia') ||
        u.contains('live.mmcdn')) {
      siteOrigin = 'https://chaturbate.com';
    } else if (u.contains('stripchat') ||
        u.contains('doppiocdn') ||
        u.contains('stripcdn')) {
      siteOrigin = 'https://stripchat.com';
    } else if (u.contains('jable')) {
      siteOrigin = 'https://jable.tv';
    } else if (u.contains('missav')) {
      siteOrigin = 'https://missav.ai';
    } else if (u.contains('bestjavporn') || u.contains('pornfhd')) {
      siteOrigin = 'https://www.bestjavporn.com';
    }

    siteOrigin ??= pageOrigin ?? _origin(url);

    if (siteOrigin != null && siteOrigin.isNotEmpty) {
      final pageUri = Uri.tryParse(pageUrl ?? '');
      final referer =
          pageUri != null && pageUri.hasScheme && pageUri.host.isNotEmpty
              ? pageUri.toString()
              : '$siteOrigin/';
      return {
        ...browser,
        'Referer': referer,
        'Origin': pageOrigin ?? siteOrigin,
        'Accept': '*/*',
      };
    }
    return {
      ...browser,
      'Accept': '*/*',
    };
  }

  static String? _origin(String? url) {
    if (url == null || url.isEmpty) return null;
    try {
      final uri = Uri.parse(url);
      if (uri.hasScheme && uri.host.isNotEmpty) {
        return uri.origin;
      }
    } catch (_) {}
    return null;
  }
}

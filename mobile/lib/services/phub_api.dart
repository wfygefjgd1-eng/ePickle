import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import '../models/video_item.dart';
import '../utils/http_client.dart';
import '../utils/http_headers.dart';

/// Pure-client API: scrapes site HTML (no backend, no built-in nodes).
/// Uses system route by default; optional local proxy via [AppHttpClient].
class PhubApi {
  static const _singleRequestTimeout = Duration(seconds: 10);
  PhubApi({Dio? dio, CancelToken? cancelToken})
      : _cancelToken = cancelToken ?? CancelToken(),
        _dio = dio ??
            AppHttpClient.create(
              headers: {
                ...AppHttpHeaders.browser,
                'Accept':
                    'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
                'Accept-Language': 'en-US,en;q=0.9',
              },
            ) {
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          options.headers['Cookie'] = _cookieHeader();
          options.cancelToken ??= _cancelToken;
          handler.next(options);
        },
        onResponse: (response, handler) {
          _storeCookies(response);
          handler.next(response);
        },
      ),
    );
  }

  void cancelRequests([String reason = 'cancelled']) {
    final token = _cancelToken;
    _cancelToken = CancelToken();
    if (!token.isCancelled) token.cancel(reason);
  }

  final Dio _dio;
  CancelToken _cancelToken;
  final Map<String, String> _cookies = {
    'accessAgeDisclaimerPH': '1',
    'accessAgeDisclaimerUK': '1',
    'accessPH': '1',
    'age_verified': '1',
    'cookieBannerState': '1',
    'platform': 'pc',
  };

  static final _flashvarsRe =
      RegExp(r'var\s+flashvars_\d+\s*=\s*(\{.*?\});', dotAll: true);
  // Site occasionally omits `var` or uses different spacing.
  static final _flashvarsReAlt =
      RegExp(r'flashvars_\d+\s*=\s*(\{.*?\});', dotAll: true);
  static final _flashvarsReQuoted =
      RegExp(r'''["']flashvars_\d+["']\s*[:=]\s*(\{.*?\})''', dotAll: true);
  static final _viewkeyRe = RegExp(r'viewkey=([a-f0-9]+)');
  static final _durationRe = RegExp(
    r'class="[^"]*duration[^"]*"[^>]*>\s*(\d+:\d+(?::\d+)?)\s*<',
  );
  static final _durRe = RegExp(
    r'class="[^"]*dur[^"]*"[^>]*>\s*(\d+:\d+(?::\d+)?)\s*<',
  );

  String _cookieHeader() =>
      _cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

  void _storeCookies(Response response) {
    final raw = response.headers.map['set-cookie'];
    if (raw == null) return;
    for (final line in raw) {
      final part = line.split(';').first;
      final i = part.indexOf('=');
      if (i <= 0) continue;
      final k = part.substring(0, i).trim();
      final v = part.substring(i + 1).trim();
      if (k.isNotEmpty) _cookies[k] = v;
    }
  }

  Future<String> _getHtml(String url) async {
    // Single-request budget so a hanging proxy/socket can never hold a feed,
    // search, or detail open beyond 10s. On timeout we cancel the underlying
    // request AND flag the proxy cache suspect (it may have gone stale).
    final token = CancelToken();
    // Cascade the instance-level cancel (page exit / tab switch) into this
    // per-request token.
    if (!_cancelToken.isCancelled) {
      // ignore: discarded_futures
      _cancelToken.whenCancel.then((_) {
        if (!token.isCancelled) token.cancel();
      });
    }
    final Response<String> res;
    try {
      res = await _dio.get<String>(url, cancelToken: token).timeout(
            _singleRequestTimeout,
          );
    } on TimeoutException {
      if (!token.isCancelled) token.cancel('request timeout');
      AppHttpClient.markProxySuspect();
      rethrow;
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        AppHttpClient.markProxySuspect();
      }
      rethrow;
    }
    final status = res.statusCode ?? 0;
    if (status == 401 || status == 403) {
      throw PhubException('访问被拒绝 (403)，请检查网络环境');
    }
    if (status == 404) {
      throw PhubException('页面不存在 (404)');
    }
    if (status == 408) throw PhubException('源站请求超时 (408)');
    if (status == 429) throw PhubException('请求过于频繁 (429)，请稍后重试');
    if (status < 200 || status >= 400) {
      throw PhubException('源站返回异常状态 ($status)');
    }
    if (res.data == null || res.data!.isEmpty) {
      throw PhubException('空响应');
    }
    return res.data!;
  }

  /// Hot / trending feed ("热闹").
  Future<List<VideoItem>> fetchRecommend({
    int limit = 50,
    Set<String>? exclude,
    int maxUrls = 5,
  }) =>
      _fetchListFeed(
        limit: limit,
        exclude: exclude,
        maxUrls: maxUrls,
        primary: const [
          'https://www.pornhub.com/video?o=ht',
          'https://www.pornhub.com/video?o=mr',
          'https://www.pornhub.com/video',
          'https://www.pornhub.com/recommended',
          'https://www.pornhub.com/',
        ],
        categoryId: null,
      );

  /// Asian category feed (`c=1`). Fully shuffled like 热闹 (random order + pages).
  Future<List<VideoItem>> fetchAsian({
    int limit = 50,
    Set<String>? exclude,
    int maxUrls = 5,
  }) {
    final rng = Random();
    // Fewer primary URLs → faster first paint; expand only if needed.
    final orders = ['ht', 'mr', 'tr', 'cm']..shuffle(rng);
    final primary = <String>[
      for (final o in orders.take(3))
        'https://www.pornhub.com/video?c=1&o=$o&page=${1 + rng.nextInt(15)}',
      'https://www.pornhub.com/video?c=1&page=${1 + rng.nextInt(12)}',
    ];
    return _fetchListFeed(
      limit: limit,
      exclude: exclude,
      maxUrls: maxUrls,
      primary: primary,
      categoryId: 1,
      shuffleAll: true,
    );
  }

  Future<List<VideoItem>> _fetchListFeed({
    required int limit,
    Set<String>? exclude,
    required int maxUrls,
    required List<String> primary,
    int? categoryId,
    bool shuffleAll = false,
  }) async {
    final rng = Random();
    // Keep secondary pool small; first paint should not hit 10+ list pages.
    final baseOrders = ['ht', 'cm', 'mr', 'tr']..shuffle(rng);
    final urls = <String>[...primary];
    for (final order in baseOrders.take(3)) {
      final page = 1 + rng.nextInt(20);
      if (categoryId != null) {
        urls.add(
          'https://www.pornhub.com/video?c=$categoryId&o=$order&page=$page',
        );
      } else {
        urls.add('https://www.pornhub.com/video?o=$order&page=$page');
      }
    }
    final List<String> ordered;
    if (shuffleAll) {
      ordered = [...urls]..shuffle(rng);
    } else {
      final keep = primary.length.clamp(1, urls.length);
      final rest = urls.sublist(keep)..shuffle(rng);
      ordered = [...urls.take(keep), ...rest];
    }

    final seen = <String>{};
    if (exclude != null) seen.addAll(exclude);
    final results = <VideoItem>[];
    var tried = 0;
    var failCount = 0;
    // Cold start uses small maxUrls → fewer parallel + shorter timeout.
    final concurrency = maxUrls <= 2 ? 2 : 3;
    final hardTimeout = maxUrls <= 2
        ? const Duration(seconds: 16)
        : const Duration(seconds: 28);

    Future<List<VideoItem>> runBatches() async {
      for (var i = 0; i < ordered.length && tried < maxUrls;) {
        if (results.length >= limit) break;
        final batchUrls = <String>[];
        while (batchUrls.length < concurrency &&
            i < ordered.length &&
            tried < maxUrls) {
          batchUrls.add(ordered[i]);
          i++;
          tried++;
        }
        final pages = await Future.wait(
          batchUrls.map((u) async {
            try {
              return await _getHtml(u);
            } catch (e) {
              if (e is DioException && CancelToken.isCancel(e)) rethrow;
              failCount++;
              return null;
            }
          }),
        );
        for (final html in pages) {
          if (html == null) continue;
          results.addAll(_parseVideoListHtml(html, seen));
          if (results.length >= limit) break;
        }
        // Enough for first paint — stop early.
        if (results.length >= (limit < 12 ? limit : 8)) break;
      }
      return results;
    }

    try {
      await runBatches().timeout(hardTimeout);
    } on TimeoutException {
      if (results.isEmpty) {
        throw PhubException(
          '加载超时。可：设置→重新检测代理，或开 TUN/VPN',
        );
      }
    }

    if (results.isEmpty) {
      if (failCount > 0 || tried > 0) {
        throw PhubException(
          '无法访问源站（$failCount/$tried 失败）。'
          '系统未代理时请开 TUN，或设置里填写/检测代理',
        );
      }
      return [];
    }

    results.shuffle(rng);
    if (results.length > limit) {
      return results.sublist(0, limit);
    }
    return results;
  }

  Future<List<VideoItem>> search(String query, {int page = 1}) async {
    final q = Uri.encodeQueryComponent(query.trim());
    if (q.isEmpty) return [];
    final url = 'https://www.pornhub.com/video/search?search=$q&page=$page';
    final html = await _getHtml(url);
    return _parseVideoListHtml(html, <String>{});
  }

  Future<VideoDetail> getVideoDetail(String url) async {
    final normalized = _normalizeVideoUrl(url);
    final html = await _getHtml(normalized);
    final flash = _parseFlashvarsMap(html);
    if (flash == null) {
      throw PhubException('无法解析视频数据（可能被地区限制或页面结构变更）');
    }

    final title = (flash['video_title'] ?? '').toString();
    var desc = flash['video_description']?.toString();
    // Fallback: extract description from HTML meta tags
    if (desc == null || desc.isEmpty) {
      final ogDesc = RegExp(
              r'<meta\s+property="og:description"\s+content="([^"]+)"',
              caseSensitive: false)
          .firstMatch(html);
      desc = ogDesc?.group(1);
    }
    if (desc == null || desc.isEmpty) {
      final metaDesc = RegExp(r'<meta\s+name="description"\s+content="([^"]+)"',
              caseSensitive: false)
          .firstMatch(html);
      desc = metaDesc?.group(1);
    }
    // Strip HTML tags
    if (desc != null) {
      desc = desc.replaceAll(RegExp(r'<[^>]+>'), '');
      desc = desc
          .replaceAll('&amp;', '&')
          .replaceAll('&#039;', "'")
          .replaceAll('&quot;', '"')
          .replaceAll('&nbsp;', ' ');
      // Filter generic site taglines that are not real descriptions
      if (_isGenericDesc(desc)) desc = null;
    }
    final durationSec = int.tryParse('${flash['video_duration']}') ?? 0;
    final thumb = flash['image_url']?.toString();
    final unavailable = '${flash['video_unavailable']}' != 'false';
    final countryBlocked = '${flash['video_unavailable_country']}' == 'true';
    final isVertical = '${flash['isVertical']}' == 'true';

    final streams = <StreamQuality>[];
    final defs = flash['mediaDefinitions'];
    if (defs is List) {
      for (final raw in defs) {
        if (raw is! Map) continue;
        final q = Map<String, dynamic>.from(raw);
        final videoUrl = q['videoUrl']?.toString() ?? '';
        if (videoUrl.isEmpty) continue;
        final low = videoUrl.toLowerCase();
        // Skip trailers / short teasers that only play ~9s
        if (low.contains('trailer') ||
            low.contains('preview') ||
            low.contains('mediabook') ||
            RegExp(r'[_-](9|10|15)s[_.-]').hasMatch(low)) {
          continue;
        }
        final format = '${q['format'] ?? ''}'.toLowerCase();
        // Prefer HLS; still allow mp4 full videos if no quality flag is trailer
        if (format.isNotEmpty &&
            format != 'hls' &&
            format != 'mp4' &&
            !low.contains('.m3u8') &&
            !low.contains('.mp4')) {
          continue;
        }

        var width = int.tryParse('${q['width'] ?? 0}') ?? 0;
        var height = int.tryParse('${q['height'] ?? 0}') ?? 0;
        if (height <= 0) {
          height = _parseQuality(q['quality']) ??
              _parseQualityFromUrl(videoUrl) ??
              0;
        }
        if (width <= 0 && height > 0) {
          width = isVertical
              ? (height * 9 / 16).round()
              : (height * 16 / 9).round();
        }
        if (width <= 0 && height <= 0) {
          height = low.contains('m3u8') ? 720 : 480;
          width = (height * 16 / 9).round();
        }
        streams.add(StreamQuality(width: width, height: height, url: videoUrl));
      }
    }

    // Prefer HLS full streams first
    streams.sort((a, b) {
      final ah = a.url.contains('m3u8') ? 1 : 0;
      final bh = b.url.contains('m3u8') ? 1 : 0;
      if (ah != bh) return bh.compareTo(ah);
      return b.pixels.compareTo(a.pixels);
    });

    return VideoDetail(
      url: normalized,
      title: title.isEmpty ? normalized : title,
      description: desc,
      durationSec: durationSec,
      thumb: thumb,
      streams: streams,
      unavailable: unavailable,
      countryBlocked: countryBlocked,
    );
  }

  /// Fetch a single video's page just to retrieve its thumbnail URL.
  Future<String?> fetchThumbnail(String viewkey) async {
    try {
      final html = await _getHtml(
          'https://www.pornhub.com/view_video.php?viewkey=$viewkey');
      final m = _flashvarsRe.firstMatch(html);
      if (m != null) {
        final flash = jsonDecode(m.group(1)!) as Map<String, dynamic>;
        final t = flash['image_url']?.toString();
        if (t != null && t.startsWith('http')) return t;
      }
      final og = RegExp(r'<meta\s+property="og:image"\s+content="([^"]+)"')
          .firstMatch(html);
      if (og != null) return og.group(1);
      // fallback: first img with http src in the page
      final imgM = RegExp(
              r'<img[^>]+src="(https?://[^"]+\.(?:jpg|jpeg|png|webp))"',
              caseSensitive: false)
          .firstMatch(html);
      return imgM?.group(1);
    } catch (_) {
      return null;
    }
  }

  List<VideoItem> _parseVideoListHtml(String html, Set<String> seen) {
    // Run both parsers: chunk-based (fast, comprehensive) + DOM (fallback).
    // Merge results so items missing thumb from one pass get it from the other.
    final results = _parseViaViewkeyChunks(html, seen);
    final domItems = _parseViaDom(html, seen);
    for (final item in domItems) {
      if (!seen.contains(item.viewkey)) {
        results.add(item);
      }
    }
    return results;
  }

  /// Splits HTML by every occurrence of "view_video.php?viewkey=" so that
  /// no video entry is missed, regardless of its CSS class.
  List<VideoItem> _parseViaViewkeyChunks(String html, Set<String> seen) {
    final results = <VideoItem>[];
    final chunks =
        html.split(RegExp(r'(?=view_video\.php\?viewkey=[a-f0-9]+)'));
    if (chunks.length < 2) return results;

    for (var i = 1; i < chunks.length; i++) {
      final chunk = chunks[i];
      final vkM = _viewkeyRe.firstMatch(chunk);
      if (vkM == null) continue;
      final vk = vkM.group(1)!;
      if (!seen.add(vk)) continue;

      final title = _extractTitle(chunk);
      if (title == null) continue;

      final dur = _extractDuration(chunk);
      if (dur != '-') {
        final secs = _durationToSeconds(dur);
        if (secs != null && secs < 30) continue;
      }

      final thumb = _extractThumbFromChunk(chunk);

      results.add(VideoItem(
        url: 'https://www.pornhub.com/view_video.php?viewkey=$vk',
        title: title,
        duration: dur,
        thumb: thumb,
      ));
    }
    return results;
  }

  String? _extractTitle(String chunk) {
    // Prefer explicit video titles; skip UI / promo noise.
    final candidates = <String>[];
    for (final m in RegExp(r'title="([^"]{4,200})"').allMatches(chunk)) {
      candidates.add(m.group(1)!);
    }
    final alt = RegExp(r'alt="([^"]{4,200})"').firstMatch(chunk);
    if (alt != null) candidates.add(alt.group(1)!);
    String? best;
    for (var t in candidates) {
      t = t
          .replaceAll('&#039;', "'")
          .replaceAll('&amp;', '&')
          .replaceAll('&quot;', '"')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (t.length < 4) continue;
      final low = t.toLowerCase();
      if (low.contains('toggle') ||
          low.contains('logo') ||
          low.contains('pornhub') ||
          low.contains('award') ||
          low.contains('winner') ||
          t.contains('奖得主') ||
          t.contains('广告')) {
        continue;
      }
      if (best == null || t.length > best.length) best = t;
    }
    // Cap absurdly long meta titles
    if (best != null && best.length > 160) {
      best = best.substring(0, 160);
    }
    return best;
  }

  String _extractDuration(String chunk) {
    final m = _durationRe.firstMatch(chunk) ?? _durRe.firstMatch(chunk);
    return m?.group(1)!.trim() ?? '-';
  }

  String? _extractThumbFromChunk(String chunk) {
    final m = RegExp(r'data-src="(https?://[^"]+)"').firstMatch(chunk) ??
        RegExp(r'data-thumb="(https?://[^"]+)"').firstMatch(chunk) ??
        RegExp(r'data-thumb_url="(https?://[^"]+)"').firstMatch(chunk) ??
        RegExp(r'data-mediumthumb="(https?://[^"]+)"').firstMatch(chunk) ??
        RegExp(r'data-image="(https?://[^"]+)"').firstMatch(chunk) ??
        RegExp(r'data-original="(https?://[^"]+)"').firstMatch(chunk) ??
        RegExp(r'data-lazy-src="(https?://[^"]+)"').firstMatch(chunk) ??
        RegExp(r'data-srcset="[^"]*(https?://[^"\s,]+)"').firstMatch(chunk) ??
        RegExp(r'img[^>]+src="(https?://[^"]+)"').firstMatch(chunk) ??
        RegExp(r'poster="(https?://[^"]+)"').firstMatch(chunk) ??
        RegExp(r'data-preview_url="(https?://[^"]+)"').firstMatch(chunk) ??
        RegExp(r'data-thumb_url_v3="(https?://[^"]+)"').firstMatch(chunk) ??
        RegExp(r'data-mediabook="(https?://[^"]+)"').firstMatch(chunk) ??
        RegExp(r"""background(?:-image)?:\s*url\(['"]?(https?://[^'" )]+)""")
            .firstMatch(chunk);
    if (m != null) return m.group(1);
    // Ultra fallback: any PH CDN image URL anywhere in the chunk
    final ph = RegExp(
            r"""https?://[a-z0-9]+\.phncdn\.com/[^"'\s<>)]+\.(?:jpg|jpeg|png|webp)""",
            caseSensitive: false)
        .firstMatch(chunk);
    return ph?.group(0);
  }

  List<VideoItem> _parseViaDom(String html, Set<String> seen) {
    final doc = html_parser.parse(html);
    final results = <VideoItem>[];
    final anchors = doc.querySelectorAll('a[href*="view_video.php?viewkey="]');

    for (final a in anchors) {
      final href = a.attributes['href'] ?? '';
      final vkM = _viewkeyRe.firstMatch(href);
      if (vkM == null) continue;
      final vk = vkM.group(1)!;
      if (!seen.add(vk)) continue;

      var title = a.attributes['title'] ??
          a.querySelector('img')?.attributes['alt'] ??
          a.text.trim();
      title = title.replaceAll('&#039;', "'").replaceAll('&amp;', '&').trim();
      if (title.length < 3) continue;

      var dur = '-';
      final parent = a.parent;
      final durNode = parent?.querySelector('.duration') ??
          parent?.querySelector('var.duration');
      if (durNode != null) {
        dur = durNode.text.trim();
      }

      final thumb = _extractThumbFromDom(a);

      results.add(VideoItem(
        url: 'https://www.pornhub.com/view_video.php?viewkey=$vk',
        title: title,
        duration: dur,
        thumb: (thumb != null && thumb.startsWith('http')) ? thumb : null,
      ));
    }
    return results;
  }

  String? _extractThumbFromDom(Element a) {
    final img = a.querySelector('img');
    if (img != null) {
      final t = img.attributes['data-src'] ??
          img.attributes['src'] ??
          img.attributes['data-thumb'] ??
          img.attributes['data-thumb_url'] ??
          img.attributes['data-mediumthumb'] ??
          img.attributes['data-image'] ??
          img.attributes['data-preview_url'] ??
          img.attributes['data-thumb_url_v3'] ??
          img.attributes['data-original'] ??
          img.attributes['data-lazy-src'];
      if (t != null && t.startsWith('http')) return t;
    }
    // Walk up to find a container with a thumb attribute or background-image
    var el = a.parent;
    while (el != null) {
      for (final attr in el.attributes.keys.cast<String>()) {
        final val = el.attributes[attr]!;
        if ((attr.startsWith('data-') && val.startsWith('http')) ||
            (attr == 'poster' && val.startsWith('http'))) {
          // Prefer CDN images over generic URLs
          if (val.contains('phncdn.com')) return val;
        }
      }
      final style = el.attributes['style'] ?? '';
      final bg =
          RegExp(r"""background-image:\s*url\(['"]?(https?://[^'" )]+)""")
              .firstMatch(style);
      if (bg != null) {
        final u = bg.group(1)!;
        if (u.contains('phncdn.com')) return u;
      }
      el = el.parent;
    }
    return null;
  }

  String _normalizeVideoUrl(String url) {
    final t = url.trim();
    if (t.startsWith('http')) return t;
    if (t.contains('viewkey=')) {
      return 'https://www.pornhub.com/view_video.php?$t';
    }
    // bare viewkey
    if (RegExp(r'^[a-f0-9]+$').hasMatch(t)) {
      return 'https://www.pornhub.com/view_video.php?viewkey=$t';
    }
    return t;
  }

  int? _durationToSeconds(String dur) {
    try {
      final parts = dur.split(':').map(int.parse).toList();
      if (parts.length == 2) return parts[0] * 60 + parts[1];
      if (parts.length == 3) {
        return parts[0] * 3600 + parts[1] * 60 + parts[2];
      }
    } catch (_) {}
    return null;
  }

  /// Multi-strategy flashvars parse (site HTML changes often).
  Map<String, dynamic>? _parseFlashvarsMap(String html) {
    for (final re in [_flashvarsRe, _flashvarsReAlt, _flashvarsReQuoted]) {
      final match = re.firstMatch(html);
      if (match == null) continue;
      final raw = match.group(1);
      if (raw == null || raw.isEmpty) continue;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) return decoded;
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {
        // try next pattern
      }
    }
    return null;
  }

  int? _parseQuality(dynamic value) {
    if (value is int) return value;
    if (value is String) {
      final digits = value.replaceAll(RegExp(r'[^0-9]'), '');
      if (digits.isNotEmpty) return int.tryParse(digits);
    }
    return null;
  }

  static bool _isGenericDesc(String? text) {
    if (text == null || text.trim().isEmpty) return true;
    final s = text.toLowerCase();
    if (s.contains('最好的') ||
        s.contains('免费硬色情') ||
        s.contains('免费色情影片') ||
        s.contains('the best free') ||
        s.contains("best free porn") ||
        s.contains('pornhub.com')) {
      return true;
    }
    return false;
  }

  int? _parseQualityFromUrl(String url) {
    for (final part in url.split('/')) {
      if (part.toLowerCase().contains('p_')) {
        final prefix = part.split(RegExp(r'[Pp]_')).first;
        return _parseQuality(prefix);
      }
    }
    return null;
  }
}

class PhubException implements Exception {
  final String message;
  PhubException(this.message);
  @override
  String toString() => message;
}

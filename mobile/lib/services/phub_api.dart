import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import '../models/video_item.dart';
import '../utils/http_client.dart';
import '../utils/http_headers.dart';
import 'mirror_ranker.dart';
import 'scrape_exception.dart';
import 'source_catalog.dart';

export 'scrape_exception.dart';

/// Pure-client API: scrapes site HTML (no backend, no built-in nodes).
/// Uses system route by default; optional local proxy via [AppHttpClient].
class PhubApi {
  static const _singleRequestTimeout = Duration(seconds: 10);
  static const _primaryHost = 'https://www.pornhub.com';
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
          options.cancelToken ??= _cancelToken;
          // Every hardcoded www.pornhub.com URL is transparently rerouted to
          // the fastest-ranked mirror (feed/search/thumbnail/detail all pass
          // through here). No-op when www is still the best.
          final p = options.path;
          if (p.startsWith(_primaryHost)) {
            options.path =
                '$_base${p.substring(_primaryHost.length)}';
          }
          // Cookie header is computed AFTER the rewrite so set-cookie from the
          // actual mirror host is sent back to that same host.
          options.headers['Cookie'] = _cookieHeaderFor(options.path);
          handler.next(options);
        },
        onResponse: (response, handler) {
          _storeCookies(response);
          handler.next(response);
        },
      ),
    );
  }

  /// Fastest mirror base for pornhub (persistent cross-session ranking).
  String get _base =>
      MirrorRanker.instance.preferredBase(SourceCatalog.pornhub);

  /// 手动换域名（长按卡片）时，所有发往 PH 家域名的请求改写到该域名。
  static const Set<String> _phFamilyHosts = {
    'www.pornhub.com', 'pornhub.com', 'www.pornhub.org', 'pornhub.org',
    'cn.pornhub.com', 'rt.pornhub.com', 'de.pornhub.com', 'fr.pornhub.com',
  };

  /// [url] 指向 PH 家域名且用户手动钉住了新域名时，返回改写到该域名后的
  /// URL（保留 path 与 query）；其余情况（未钉域名 / 解析失败 / 非家域名）
  /// 原样返回。
  String _rewriteBase(String url) {
    final override = MirrorRanker.instance.manualBase('pornhub');
    if (override == null || override.isEmpty) return url;
    final uri = Uri.tryParse(url);
    if (uri == null || !_phFamilyHosts.contains(uri.host.toLowerCase())) {
      return url;
    }
    final base = override.replaceAll(RegExp(r'/$'), '');
    final query = uri.hasQuery && uri.query.isNotEmpty ? '?${uri.query}' : '';
    return '$base${uri.path}$query';
  }

  /// Swap in a fresh cancel token, then cancel the old one. New requests
  /// read [_cancelToken] after the swap (so they are never cancelled by this
  /// call) while in-flight ones hold the old token and abort.
  void cancelRequests([String reason = 'cancelled']) {
    final old = _cancelToken;
    final next = CancelToken();
    _cancelToken = next;
    if (!old.isCancelled) old.cancel(reason);
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

  /// Per-mirror set-cookie jar (keyed by response host) so one mirror's
  /// cookies never poison the others — flat last-writer-wins across mirrors
  /// could let a restrictive cookie (age_verified=0, locale) silently break
  /// every other mirror for the whole session.
  final Map<String, Map<String, String>> _dynamicCookies = {};

  static final _flashvarsRe =
      RegExp(r'var\s+flashvars_\d+\s*=\s*(\{.*?\});', dotAll: true);
  // Site occasionally omits `var` or uses different spacing.
  static final _flashvarsReAlt =
      RegExp(r'flashvars_\d+\s*=\s*(\{.*?\});', dotAll: true);
  static final _flashvarsReQuoted =
      RegExp(r'''["']flashvars_\d+["']\s*[:=]\s*(\{.*?\})''', dotAll: true);
  // viewkey 域名段不只有纯 hex：现代 key 带 "ph" 前缀（ph63dc…），
  // 收窄到 [a-f0-9] 会漏抓整页视频并把 key 截断。
  static final _viewkeyRe = RegExp(r'viewkey=([a-z0-9]+)');
  static final _durRe = RegExp(
    r'class="[^"]*dur[^"]*"[^>]*>\s*(\d+:\d+(?::\d+)?)\s*<',
  );
  static final _titleAttrRe = RegExp(r'title="([^"]{4,200})"');
  static final _altAttrRe = RegExp(r'alt="([^"]{4,200})"');
  static final _thumbDataSrcRe = RegExp(r'data-src="(https?://[^"]+)"');
  static final _thumbDataThumbRe = RegExp(r'data-thumb="(https?://[^"]+)"');
  static final _thumbDataThumbUrlRe =
      RegExp(r'data-thumb_url="(https?://[^"]+)"');
  static final _thumbDataMediumRe =
      RegExp(r'data-mediumthumb="(https?://[^"]+)"');
  static final _thumbDataImageRe = RegExp(r'data-image="(https?://[^"]+)"');
  static final _thumbDataOriginalRe =
      RegExp(r'data-original="(https?://[^"]+)"');
  static final _thumbDataLazyRe = RegExp(r'data-lazy-src="(https?://[^"]+)"');
  static final _thumbDataSrcsetRe =
      RegExp(r'data-srcset="[^"]*(https?://[^"\s,]+)"');
  static final _thumbImgSrcRe = RegExp(r'img[^>]+src="(https?://[^"]+)"');
  static final _thumbPosterRe = RegExp(r'poster="(https?://[^"]+)"');
  static final _thumbDataPreviewRe =
      RegExp(r'data-preview_url="(https?://[^"]+)"');
  static final _thumbDataV3Re =
      RegExp(r'data-thumb_url_v3="(https?://[^"]+)"');
  static final _thumbDataMediabookRe =
      RegExp(r'data-mediabook="(https?://[^"]+)"');
  static final _thumbBgImageRe =
      RegExp(r"""background(?:-image)?:\s*url\(['"]?(https?://[^'" )]+)""");
  static final _thumbPhncdnRe = RegExp(
    r"""https?://[a-z0-9]+\.phncdn\.com/[^"'\s<>)]+\.(?:jpg|jpeg|png|webp)""",
    caseSensitive: false,
  );

  String _cookieHeaderFor(String url) {
    final host = Uri.tryParse(url)?.host;
    final dynamicPart = host == null ? null : _dynamicCookies[host];
    final entries = <String, String>{
      ..._cookies,
      ...?dynamicPart,
    };
    return entries.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  void _storeCookies(Response response) {
    final raw = response.headers.map['set-cookie'];
    final host = response.realUri.host;
    if (raw == null || raw.isEmpty || host.isEmpty) return;
    final jar = _dynamicCookies.putIfAbsent(host, () => <String, String>{});
    for (final line in raw) {
      final part = line.split(';').first;
      final i = part.indexOf('=');
      if (i <= 0) continue;
      final k = part.substring(0, i).trim();
      final v = part.substring(i + 1).trim();
      if (k.isEmpty) continue;
      if (v.isEmpty) {
        jar.remove(k);
      } else {
        jar[k] = v;
      }
    }
  }

  Future<String> _getHtml(String url) async {
    // 手动换域名：发往 PH 家域名的请求先改写到用户钉住的域名。未钉域名时
    // rewritten 与 url 相同，以下行为完全不变。
    final rewritten = _rewriteBase(url);
    // Failover ladder: fastest-ranked mirror first, then the next mirrors —
    // every mirror stays in play. Each attempt gets its own 10s budget, the
    // ladder as a whole is bounded so a dead top mirror can't hold a request
    // open for minutes. Live outcomes feed the ranker so a dead mirror sinks
    // in future order instead of being re-chosen forever.
    final mirrors = MirrorRanker.instance.rankedMirrors(SourceCatalog.pornhub);
    final bases = <String>[
      for (final m in mirrors.take(3))
        m.replaceAll(RegExp(r'/$'), ''),
    ];
    if (bases.isEmpty) bases.add(_primaryHost);
    final ladderStarted = DateTime.now();
    Object? lastError;
    // 主域名 URL 仍按候选 base 逐个改写（手动钉住的域名由 rankedMirrors
    // 排在首位，天然先试）；其余 PH 家域名（cn/rt/de/…）改写后已经是唯一
    // 的目标 URL，没有可换的 base —— 只发一次请求，成败也只记在实际访问
    // 的那个域名上。此前会把同一次失败记到 3 个候选域名头上，污染排名，
    // 还把同一个 URL 白白重试 3 遍。
    final isPrimaryUrl = url.startsWith(_primaryHost);
    final attempts = isPrimaryUrl
        ? [
            for (final base in bases)
              (base, '$base${url.substring(_primaryHost.length)}'),
          ]
        : [(_baseOfUrl(rewritten), rewritten)];
    for (final (outcomeBase, attemptUrl) in attempts) {
      final budget = DateTime.now().difference(ladderStarted) +
          _singleRequestTimeout;
      if (budget > const Duration(seconds: 24)) break;
      final watch = Stopwatch()..start();
      try {
        final html = await _getHtmlOnce(attemptUrl);
        MirrorRanker.instance.onFetchOutcome(
          SourceCatalog.pornhub.id,
          outcomeBase,
          ok: true,
          ms: watch.elapsedMilliseconds,
        );
        return html;
      } catch (e) {
        if (e is DioException && CancelToken.isCancel(e)) {
          rethrow;
        }
        lastError = e;
        MirrorRanker.instance.onFetchOutcome(
          SourceCatalog.pornhub.id,
          outcomeBase,
          ok: false,
          ms: watch.elapsedMilliseconds,
        );
      }
    }
    throw lastError ?? PhubException('所有镜像均不可用');
  }

  /// The mirror base (scheme://host[:port]) of [url] for ranker stats.
  String _baseOfUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return _primaryHost;
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '${uri.scheme}://${uri.host}$port';
  }

  /// Single-mirror fetch with a 10s budget; on timeout it cancels the
  /// underlying request AND flags the proxy cache suspect (it may be stale).
  Future<String> _getHtmlOnce(String url) async {
    final token = CancelToken();
    // Cascade the instance-level cancel (page exit / tab switch) into this
    // per-request token.
    if (_cancelToken.isCancelled) {
      token.cancel();
    } else {
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
      throw PhubException('访问被拒绝 ($status)，请检查网络环境');
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
        // primary 恰好占满默认 maxUrls=5，固定顺序会导致 load-more 每次都
        // 抓同样的 5 页、看完后永远无新内容。随机化后每次调用覆盖不同页面。
        shuffleAll: true,
      );

  /// Newest feed（"新" tab）— o=cm = most recently uploaded, distinct from
  /// the trending 热闹 feed.
  Future<List<VideoItem>> fetchNewest({
    int limit = 50,
    Set<String>? exclude,
    int maxUrls = 5,
  }) =>
      _fetchListFeed(
        limit: limit,
        exclude: exclude,
        maxUrls: maxUrls,
        primary: const [
          'https://www.pornhub.com/video?o=cm',
          'https://www.pornhub.com/video?o=cm&page=2',
          'https://www.pornhub.com/video?o=cm&page=3',
          'https://www.pornhub.com/video?o=cm&page=4',
          'https://www.pornhub.com/video?o=cm&page=5',
        ],
        categoryId: null,
        // 同 fetchRecommend：固定顺序会让 load-more 永远只抓这 5 页。
        shuffleAll: true,
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
      // tried 对每个发过的 URL 都 +1，"tried > 0" 恒真 —— 空结果不一定是
      // 源站不可达，也可能只是抓到的全是已看过的条目（信息流失速）。只有
      // 全部请求都失败时才报"无法访问源站"，否则静默返回空列表。
      if (tried > 0 && failCount == tried) {
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
    // Missing field must NOT be treated as "unavailable" (would skip
    // playable videos on pages that omit the key entirely).
    final dynamic unavRaw = flash['video_unavailable'];
    final unavailable = unavRaw == true || unavRaw == 'true';
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
    // Chunk-based parser is the fast primary; the DOM pass backfills thumbs
    // the chunk pass missed (data-* attributes change often) and adds items
    // only it could see.
    final results = _parseViaViewkeyChunks(html, seen);
    // Skip the costly full-DOM parse when the chunk path already produced
    // well-formed entries with thumbnails — DOM parse is a heavy
    // html_parser pass over the entire page and is only useful to (a)
    // backfill missing thumbs, (b) discover entries the chunk regex split
    // missed. Both are exceptional; the fast path covers the vast majority.
    final needsDom = results.isEmpty || results.any((e) => e.thumb == null);
    if (!needsDom) return results;
    final domItems = _parseViaDom(html, <String>{});
    final byVk = <String, VideoItem>{for (final d in domItems) d.viewkey: d};
    for (var i = 0; i < results.length; i++) {
      final item = results[i];
      if (item.thumb != null) continue;
      final d = byVk[item.viewkey];
      if (d != null &&
          d.thumb != null &&
          d.thumb!.startsWith('http') &&
          !identical(d, item)) {
        results[i] = item.copyWith(thumb: d.thumb);
      }
    }
    // DOM 独有的条目（chunk 正则切漏的）补进结果，并登记进 seen 保持
    // 与调用方共享的去重口径一致。
    for (final item in domItems) {
      if (seen.add(item.viewkey)) {
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
        html.split(RegExp(r'(?=view_video\.php\?viewkey=[a-z0-9]+)'));
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
    for (final m in _titleAttrRe.allMatches(chunk)) {
      candidates.add(m.group(1)!);
    }
    final alt = _altAttrRe.firstMatch(chunk);
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
    final m = _durRe.firstMatch(chunk);
    return m?.group(1)!.trim() ?? '-';
  }

  String? _extractThumbFromChunk(String chunk) {
    final m = _thumbDataSrcRe.firstMatch(chunk) ??
        _thumbDataThumbRe.firstMatch(chunk) ??
        _thumbDataThumbUrlRe.firstMatch(chunk) ??
        _thumbDataMediumRe.firstMatch(chunk) ??
        _thumbDataImageRe.firstMatch(chunk) ??
        _thumbDataOriginalRe.firstMatch(chunk) ??
        _thumbDataLazyRe.firstMatch(chunk) ??
        _thumbDataSrcsetRe.firstMatch(chunk) ??
        _thumbImgSrcRe.firstMatch(chunk) ??
        _thumbPosterRe.firstMatch(chunk) ??
        _thumbDataPreviewRe.firstMatch(chunk) ??
        _thumbDataV3Re.firstMatch(chunk) ??
        _thumbDataMediabookRe.firstMatch(chunk) ??
        _thumbBgImageRe.firstMatch(chunk);
    if (m != null) return m.group(1);
    // Ultra fallback: any PH CDN image URL anywhere in the chunk
    final ph = _thumbPhncdnRe.firstMatch(chunk);
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
      // Extract only the query portion — the input may be a bare path like
      // "pornhub.com/view_video.php?viewkey=x" that must not be re-embedded.
      final query = t.substring(t.indexOf('viewkey='));
      return 'https://www.pornhub.com/view_video.php?$query';
    }
    // bare viewkey
    if (RegExp(r'^[a-z0-9]+$').hasMatch(t)) {
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

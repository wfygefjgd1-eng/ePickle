import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/video_item.dart';
import '../utils/des_ecb.dart';
import '../utils/http_client.dart';
import '../utils/http_headers.dart';
import '../utils/native_browser_http.dart';
import 'phub_api.dart';
import 'source_catalog.dart';

/// Keeps the HTTP status available after native/browser fallback attempts.
/// A plain error string is too easy to lose or misclassify.
class _MirrorHttpException implements Exception {
  const _MirrorHttpException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => message;
}

/// Generic HTML scraper with mirror failover for tube / JAV-style sites.
class GenericSiteApi {
  static const _requestTimeout = Duration(seconds: 10);
  static const _feedResolveTimeout = Duration(seconds: 16);
  static const _searchResolveTimeout = Duration(seconds: 14);
  static const _detailResolveTimeout = Duration(seconds: 20);

  GenericSiteApi({Dio? dio})
      : _dio = dio ??
            AppHttpClient.create(
              headers: {
                ...AppHttpHeaders.browser,
                'Accept':
                    'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
                'Accept-Language': 'en-US,en;q=0.9,zh-CN;q=0.8',
              },
              connectTimeout: const Duration(seconds: 14),
              receiveTimeout: const Duration(seconds: 22),
            );

  final Dio _dio;

  /// Requests are short-lived, but keeping their individual tokens lets the
  /// feed screen stop every mirror/API probe as soon as iOS backgrounds it.
  final Set<CancelToken> _activeRequests = <CancelToken>{};

  void cancelRequests([String reason = 'cancelled']) {
    final tokens = List<CancelToken>.from(_activeRequests);
    _activeRequests.clear();
    for (final token in tokens) {
      if (!token.isCancelled) token.cancel(reason);
    }
  }

  /// Per-site last working mirror index (in-memory).
  final Map<String, int> _mirrorIndex = {};
  final Map<String, Map<String, MirrorHealth>> _mirrorHealth = {};
  final Map<String, String> _liveStreamNames = {};

  List<MirrorHealth> mirrorHealthFor(String siteId) => List.unmodifiable(
        _mirrorHealth[siteId]?.values ?? const <MirrorHealth>[],
      );

  /// Minimal per-origin cookie store for age gates and session redirects.
  final Map<String, Map<String, String>> _cookies = {};

  Duration _requestBudget(DateTime? deadline) {
    if (deadline == null) return _requestTimeout;
    final remaining = deadline.difference(DateTime.now());
    if (remaining.inMilliseconds <= 0) {
      throw TimeoutException('站点解析超时');
    }
    return remaining < _requestTimeout ? remaining : _requestTimeout;
  }

  Future<String> _getHtml(
    String url, {
    Map<String, String>? headers,
    Duration timeout = _requestTimeout,
    CancelToken? cancelToken,
    void Function(int statusCode)? onStatus,
  }) async {
    final origin = _originOf(url);
    final cookieHeader = origin == null ? null : _cookieHeader(origin);
    final requestHeaders = <String, String>{
      ...AppHttpHeaders.forSite(origin ?? url),
      if (cookieHeader != null) 'Cookie': cookieHeader,
      if (headers != null) ...headers,
    };
    final token = cancelToken ?? CancelToken();
    _activeRequests.add(token);
    late final Response<String> res;
    try {
      res = await _dio
          .get<String>(
            url,
            cancelToken: token,
            options: Options(
              responseType: ResponseType.plain,
              headers: requestHeaders,
              followRedirects: true,
              validateStatus: (s) => s != null && s < 500,
            ),
          )
          .timeout(timeout);
    } on TimeoutException {
      if (!token.isCancelled) token.cancel('request timeout');
      // A hanging request usually means the cached proxy went stale or the
      // connection is dead; re-detect the system proxy before the next try.
      AppHttpClient.markProxySuspect();
      rethrow;
    } on DioException catch (error) {
      if (error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.receiveTimeout) {
        AppHttpClient.markProxySuspect();
      }
      if (!CancelToken.isCancel(error) && _shouldUseNativeFallback(error)) {
        final native = await _nativeGetHtml(
          url,
          origin: origin,
          headers: requestHeaders,
          timeout: timeout,
        );
        if (native != null) return native;
      }
      rethrow;
    } finally {
      _activeRequests.remove(token);
    }
    _storeCookies(origin, res.headers);
    final status = res.statusCode ?? 0;
    onStatus?.call(status);
    if (res.statusCode == 403 || res.statusCode == 404) {
      // Browser often still works: soft-block / bot 404 / age gate.
      final native = await _nativeGetHtml(
        url,
        origin: origin,
        headers: requestHeaders,
        timeout: timeout,
      );
      if (native != null && native.trim().isNotEmpty) return native;
      if (res.statusCode == 403) {
        throw PhubException('抓取请求被拦截 (403；不代表网站失效)');
      }
      throw PhubException('页面不存在 (404)');
    }
    if (status < 200 || status >= 400) {
      final native = await _nativeGetHtml(
        url,
        origin: origin,
        headers: requestHeaders,
        timeout: timeout,
      );
      if (native != null && native.trim().isNotEmpty) return native;
      throw PhubException('站点返回异常状态 ($status)');
    }
    if (res.data == null || res.data!.isEmpty) {
      final native = await _nativeGetHtml(
        url,
        origin: origin,
        headers: requestHeaders,
        timeout: timeout,
      );
      if (native != null && native.trim().isNotEmpty) return native;
      throw PhubException('空响应');
    }
    final body = res.data!;
    if (_isBlockedHtml(body)) {
      final native = await _nativeGetHtml(
        url,
        origin: origin,
        headers: requestHeaders,
        timeout: timeout,
      );
      if (native != null &&
          native.trim().isNotEmpty &&
          !_isBlockedHtml(native)) {
        return native;
      }
    }
    return body;
  }

  bool _shouldUseNativeFallback(DioException error) {
    final message = error.toString().toLowerCase();
    return message.contains('handshake') ||
        message.contains('certificate') ||
        message.contains('connection reset') ||
        error.response?.statusCode == 403;
  }

  Future<String?> _nativeGetHtml(
    String url, {
    required String? origin,
    required Map<String, String> headers,
    required Duration timeout,
  }) async {
    var response = await NativeBrowserHttp.get(
      url,
      headers: headers,
      timeout: timeout,
    );
    // Soft 404/403 bodies may still be useful; challenge pages need WK render.
    final first = response;
    final needRender = first == null ||
        first.body.isEmpty ||
        first.statusCode == 403 ||
        first.statusCode >= 500 ||
        _isBlockedHtml(first.body);
    if (needRender) {
      response = await NativeBrowserHttp.render(
        url,
        headers: headers,
        timeout: timeout,
      );
    }
    if (response == null || response.body.isEmpty) {
      return null;
    }
    // Soft-block pages still return 200/403/404 with challenge HTML.
    if (response.statusCode >= 500) return null;
    if (_isBlockedHtml(response.body) && response.statusCode >= 400) {
      return null;
    }
    if (origin != null && response.cookies.isNotEmpty) {
      _cookies.putIfAbsent(origin, () => <String, String>{}).addAll(
            response.cookies,
          );
    }
    return response.body;
  }

  Future<String?> _nativeRenderHtml(
    String url, {
    required String? origin,
    required Map<String, String> headers,
    required Duration timeout,
  }) async {
    final response = await NativeBrowserHttp.render(
      url,
      headers: headers,
      timeout: timeout,
    );
    if (response == null ||
        response.statusCode < 200 ||
        response.statusCode >= 400 ||
        response.body.isEmpty) {
      return null;
    }
    if (origin != null && response.cookies.isNotEmpty) {
      _cookies.putIfAbsent(origin, () => <String, String>{}).addAll(
            response.cookies,
          );
    }
    final finalOrigin = _originOf(response.finalUrl);
    if (finalOrigin != null && response.cookies.isNotEmpty) {
      _cookies.putIfAbsent(finalOrigin, () => <String, String>{}).addAll(
            response.cookies,
          );
    }
    return response.body;
  }

  String? _cookieHeader(String origin) {
    final values = _cookies[origin];
    if (values == null || values.isEmpty) return null;
    return values.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  void _storeCookies(String? origin, Headers headers) {
    if (origin == null) return;
    final raw = headers.map['set-cookie'];
    if (raw == null || raw.isEmpty) return;
    final jar = _cookies.putIfAbsent(origin, () => <String, String>{});
    for (final value in raw) {
      final pair = value.split(';').first.trim();
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      final name = pair.substring(0, eq).trim();
      final cookieValue = pair.substring(eq + 1).trim();
      if (cookieValue.isEmpty) {
        jar.remove(name);
      } else {
        jar[name] = cookieValue;
      }
    }
  }

  bool _isBlockedHtml(String html) {
    final low = html.toLowerCase();
    final trim = html.trimLeft();
    if (trim.startsWith('{') || trim.startsWith('[')) return false;
    if (html.length < 350) return true;
    if (low.contains('just a moment') && low.contains('cloudflare')) {
      return true;
    }
    if (low.contains('cf-browser-verification')) return true;
    if (low.contains('attention required') && low.contains('cloudflare')) {
      return true;
    }
    if (low.contains('服务暂不可用') || low.contains('正在跳转到发布页')) {
      return true;
    }
    // Age-gate only landing with no video cards
    if (low.contains('已满18') &&
        html.length < 8000 &&
        !low.contains('vod') &&
        !RegExp(r'/video').hasMatch(low)) {
      return true;
    }
    return false;
  }

  MirrorFailureKind _failureKind(Object error) {
    final message = error.toString().toLowerCase();
    if (error is _MirrorHttpException) {
      return error.statusCode == 403
          ? MirrorFailureKind.forbidden
          : MirrorFailureKind.network;
    }
    if (error is DioException && error.response?.statusCode == 403) {
      return MirrorFailureKind.forbidden;
    }
    if (error is TimeoutException ||
        message.contains('timeout') ||
        message.contains('timed out')) {
      return MirrorFailureKind.timeout;
    }
    if (message.contains('403') || message.contains('forbidden')) {
      return MirrorFailureKind.forbidden;
    }
    if (message.contains('cloudflare') ||
        message.contains('验证') ||
        message.contains('拦截')) {
      return MirrorFailureKind.blocked;
    }
    if (message.contains('failed host lookup') ||
        message.contains('name not resolved') ||
        message.contains('nodename nor servname') ||
        message.contains('dns')) {
      return MirrorFailureKind.dns;
    }
    if (message.contains('结构不匹配') || message.contains('解析不到')) {
      return MirrorFailureKind.structureChanged;
    }
    if (message.contains('cancel')) return MirrorFailureKind.cancelled;
    return MirrorFailureKind.network;
  }

  void _recordMirror(
    SiteDef site,
    String base,
    Stopwatch watch, {
    Object? error,
  }) {
    final previous = _mirrorHealth[site.id]?[base];
    final failure = error == null ? null : _failureKind(error);
    // A later fallback path must not hide a stronger HTTP failure recorded
    // for the same mirror during this fetch cycle.
    if (previous?.failure == MirrorFailureKind.forbidden &&
        failure == MirrorFailureKind.network) {
      return;
    }
    final status = MirrorHealth(
      url: base,
      checkedAt: DateTime.now(),
      latency: watch.elapsed,
      failure: failure,
      detail: error?.toString(),
    );
    _mirrorHealth.putIfAbsent(site.id, () => {})[base] = status;
  }

  List<String> _mirrorsFor(SiteDef site) {
    if (site.mirrors.isNotEmpty) return List<String>.from(site.mirrors);
    return [site.primaryHost];
  }

  String _abs(String base, String path) {
    final p = path.trim();
    if (p.isEmpty) return base;
    if (p.startsWith('http://') || p.startsWith('https://')) return p;
    if (p.startsWith('//')) return 'https:$p';
    final baseUri = Uri.tryParse(base);
    if (baseUri == null || !baseUri.hasScheme) return p;
    return baseUri.resolve(p).toString();
  }

  Future<String> _fetchWithMirrors(
    SiteDef site,
    String Function(String base) pathBuilder, {
    Map<String, String>? extraHeaders,
    DateTime? deadline,
  }) async {
    final page = await _fetchPageWithMirrors(
      site,
      pathBuilder,
      extraHeaders: extraHeaders,
      deadline: deadline,
    );
    return page.html;
  }

  Future<_FetchedPage> _fetchPageWithMirrors(
    SiteDef site,
    String Function(String base) pathBuilder, {
    Map<String, String>? extraHeaders,
    bool Function(String html, String base)? accept,
    DateTime? deadline,
  }) async {
    final mirrors = _mirrorsFor(site);
    final preferred = _mirrorIndex[site.id];

    Future<_MirrorProbe> probe(int i, [CancelToken? cancelToken]) async {
      final base = mirrors[i].replaceAll(RegExp(r'/$'), '');
      final url = pathBuilder(base);
      final watch = Stopwatch()..start();
      try {
        final headers = <String, String>{
          ...AppHttpHeaders.browser,
          'Referer': '$base/',
          if (extraHeaders != null) ...extraHeaders,
        };
        var html = await _getHtml(
          url,
          headers: headers,
          timeout: _requestBudget(deadline),
          cancelToken: cancelToken,
          onStatus: (status) {
            if (status == 403) {
              _recordMirror(
                site,
                base,
                watch,
                error: const _MirrorHttpException(403, 'HTTP 403 Forbidden'),
              );
            }
          },
        );
        final staticBlocked = _isBlockedHtml(html);
        final staticRejected = accept != null && !accept(html, base);
        if (staticBlocked || staticRejected) {
          final rendered = await _nativeRenderHtml(
            url,
            origin: _originOf(url),
            headers: headers,
            timeout: _requestBudget(deadline),
          );
          if (rendered != null) html = rendered;
        }
        if (_isBlockedHtml(html)) {
          throw PhubException('Cloudflare / Cookie 验证页拦截');
        }
        if (accept != null && !accept(html, base)) {
          throw PhubException('${site.name} 页面结构不匹配');
        }
        _recordMirror(site, base, watch);
        return _MirrorProbe(
          index: i,
          page: _FetchedPage(html: html, url: url, base: base),
        );
      } catch (e) {
        _recordMirror(site, base, watch, error: e);
        return _MirrorProbe(index: i, error: e);
      }
    }

    final failures = <Object>[];
    final indices = <int>[
      if (preferred != null && preferred >= 0 && preferred < mirrors.length)
        preferred,
      for (var i = 0; i < mirrors.length; i++)
        if (i != preferred) i,
    ];
    if (indices.isNotEmpty) {
      // Mirrors are independent hosts. Probe all of them together, including
      // the last-known-good one, so a stale preferred mirror cannot consume
      // most of the shared deadline before alternatives even start.
      final completer = Completer<_MirrorProbe>();
      final tokens = <int, CancelToken>{
        for (final index in indices) index: CancelToken(),
      };
      var remaining = indices.length;
      for (final index in indices) {
        unawaited(probe(index, tokens[index]).then((result) {
          if (result.page != null && !completer.isCompleted) {
            completer.complete(result);
            return;
          }
          if (result.error != null) failures.add(result.error!);
          remaining--;
          if (remaining == 0 && !completer.isCompleted) {
            completer.complete(
              _MirrorProbe(index: -1, error: _bestMirrorError(failures)),
            );
          }
        }));
      }
      final result = await completer.future;
      if (result.page != null) {
        _mirrorIndex[site.id] = result.index;
        return result.page!;
      }
      if (result.error != null && !failures.contains(result.error)) {
        failures.add(result.error!);
      }
    }

    final best = _bestMirrorError(failures);
    throw best ?? PhubException('${site.name} 的所有镜像均不可用');
  }

  Object? _bestMirrorError(List<Object> errors) {
    if (errors.isEmpty) return null;
    const priority = <MirrorFailureKind, int>{
      // Cancellation is a control-flow signal, not a mirror failure. Keep it
      // ahead of earlier HTTP failures so callers stop their fallback loops.
      MirrorFailureKind.cancelled: -1,
      MirrorFailureKind.forbidden: 0,
      MirrorFailureKind.blocked: 1,
      MirrorFailureKind.structureChanged: 2,
      MirrorFailureKind.dns: 3,
      MirrorFailureKind.timeout: 4,
      MirrorFailureKind.network: 5,
    };
    errors.sort((a, b) => (priority[_failureKind(a)] ?? 99)
        .compareTo(priority[_failureKind(b)] ?? 99));
    return errors.first;
  }

  /// Feed list for a site tag (hot/new/asian/best).
  Future<List<VideoItem>> fetchFeed(
    SiteDef site, {
    String tagId = 'hot',
    int page = 1,
    int limit = 40,
    Set<String>? exclude,
  }) async {
    final deadline = DateTime.now().add(_feedResolveTimeout);
    final seen = <String>{...?exclude};
    final results = <VideoItem>[];
    Object? lastError;
    final safePage = page < 1 ? 1 : page;

    // Site-specific API first (more reliable than HTML scrape).
    try {
      final api = await _fetchViaApi(
        site,
        tagId: tagId,
        page: safePage,
        limit: limit,
        seen: seen,
        deadline: deadline,
      );
      results.addAll(api);
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) rethrow;
      lastError = e;
    }

    final shouldTryHtml = results.isEmpty ||
        (site.kind == SiteKind.video && results.length < limit);
    if (shouldTryHtml) {
      final paths = _listPaths(site, tagId, safePage);
      for (final pathFn in paths) {
        if (results.length >= limit) break;
        try {
          final fetched = await _fetchPageWithMirrors(
            site,
            pathFn,
            deadline: deadline,
            accept: (html, base) => _parseFeedResponse(
              html,
              base,
              <String>{
                ...seen,
              },
              site,
              tagId: tagId,
            ).isNotEmpty,
          );
          results.addAll(
            _parseFeedResponse(
              fetched.html,
              fetched.base,
              seen,
              site,
              tagId: tagId,
            ),
          );
        } catch (e) {
          if (e is DioException && CancelToken.isCancel(e)) rethrow;
          lastError = e;
          continue;
        }
      }
    }

    if (results.isEmpty) {
      if (DateTime.now().isAfter(deadline)) {
        throw PhubException('${site.name} 列表解析超时，请重试或切换网络');
      }
      if (lastError != null) throw lastError;
      throw PhubException('${site.name} 页面已返回，但解析不到视频列表（页面结构可能已改版）');
    }
    if (results.length > limit) return results.sublist(0, limit);
    return results;
  }

  List<VideoItem> _parseFeedResponse(
      String body, String base, Set<String> seen, SiteDef site,
      {String? tagId}) {
    final trim = body.trimLeft();
    if (trim.startsWith('{') || trim.startsWith('[')) {
      return [
        if (site.kind == SiteKind.live)
          ..._parseLiveJson(body, base, seen, site, tagId: tagId),
        if (site.kind == SiteKind.video)
          ..._parseGenericJsonList(body, base, seen, site),
      ];
    }
    return _parseList(body, base, seen, site);
  }

  /// Prefer official/public JSON APIs when available.
  Future<List<VideoItem>> _fetchViaApi(
    SiteDef site, {
    required String tagId,
    required int page,
    required int limit,
    required Set<String> seen,
    required DateTime deadline,
  }) async {
    switch (site.parserId ?? site.id) {
      case 'eporner':
        return _fetchEpornerApi(
          site,
          tagId: tagId,
          page: page,
          limit: limit,
          seen: seen,
          deadline: deadline,
        );
      case 'chaturbate':
        return _fetchChaturbateApi(
          site,
          tagId: tagId,
          page: page,
          limit: limit,
          seen: seen,
          deadline: deadline,
        );
      case 'stripchat':
        return _fetchStripchatApi(
          site,
          tagId: tagId,
          page: page,
          limit: limit,
          seen: seen,
          deadline: deadline,
        );
      default:
        return const [];
    }
  }

  Future<List<VideoItem>> _fetchEpornerApi(
    SiteDef site, {
    required String tagId,
    required int page,
    required int limit,
    required Set<String> seen,
    required DateTime deadline,
  }) async {
    final q = switch (tagId) {
      'asian' => 'asian',
      'new' => 'all',
      'best' => 'all',
      _ => 'all',
    };
    final order = switch (tagId) {
      'new' => 'latest',
      'best' => 'top-rated',
      'asian' => 'top-weekly',
      _ => 'top-weekly',
    };
    final out = <VideoItem>[];
    for (final base in _mirrorsFor(site)) {
      final b = base.replaceAll(RegExp(r'/$'), '');
      final url = '$b/api/v2/video/search/?query=${Uri.encodeQueryComponent(q)}'
          '&per_page=${limit.clamp(1, 60)}&page=$page&thumbsize=big'
          '&order=$order&gay=0&lq=1&format=json';
      try {
        final raw = await _getHtml(
          url,
          headers: {
            ...AppHttpHeaders.forSite(b),
            'Accept': 'application/json,text/plain,*/*',
          },
          timeout: _requestBudget(deadline),
        );
        // Prefer structured JSON (url/title/default_thumb.src).
        try {
          final decoded = jsonDecode(raw);
          final list = decoded is Map
              ? (decoded['videos'] as List? ?? const [])
              : (decoded is List ? decoded : const []);
          for (final entry in list) {
            if (entry is! Map) continue;
            final map = entry.map((k, v) => MapEntry('$k', v));
            final u = (map['url'] ?? '').toString().replaceAll(r'\/', '/');
            if (u.isEmpty || !seen.add(u)) continue;
            final title = _cleanTitle((map['title'] ?? 'Eporner').toString());
            String? thumb;
            final dt = map['default_thumb'];
            if (dt is Map && dt['src'] != null) {
              thumb = dt['src'].toString().replaceAll(r'\/', '/');
            }
            final lengthMin = (map['length_min'] ?? '-').toString();
            out.add(
              VideoItem(
                url: u,
                title: title.isEmpty ? 'Eporner' : title,
                duration: lengthMin,
                thumb: thumb,
              ),
            );
            if (out.length >= limit) break;
          }
          if (out.isNotEmpty) {
            _mirrorIndex[site.id] = _mirrorsFor(site).indexOf(base);
            return out;
          }
        } catch (_) {}
        final videos = RegExp(
          r'"url"\s*:\s*"(https?:[^"]+eporner[^"]+)"',
          caseSensitive: false,
        ).allMatches(raw);
        final titles = RegExp(
          r'"title"\s*:\s*"([^"]+)"',
        ).allMatches(raw).toList();
        final thumbs = RegExp(
          r'"src"\s*:\s*"(https?:[^"]+)"',
        ).allMatches(raw).toList();
        var i = 0;
        for (final m in videos) {
          final u = m.group(1)!.replaceAll(r'\/', '/');
          if (!seen.add(u)) {
            i++;
            continue;
          }
          String title = 'Eporner';
          if (i < titles.length) {
            title = _cleanTitle(titles[i].group(1)!.replaceAll(r'\/', '/'));
          }
          String? thumb;
          if (i < thumbs.length) {
            thumb = thumbs[i].group(1)!.replaceAll(r'\/', '/');
          }
          out.add(VideoItem(url: u, title: title, duration: '-', thumb: thumb));
          i++;
          if (out.length >= limit) break;
        }
        if (out.isNotEmpty) {
          _mirrorIndex[site.id] = _mirrorsFor(site).indexOf(base).clamp(0, 99);
          return out;
        }
      } catch (e) {
        if (e is DioException && CancelToken.isCancel(e)) rethrow;
        continue;
      }
    }
    return out;
  }

  Future<List<VideoItem>> _fetchChaturbateApi(
    SiteDef site, {
    required String tagId,
    required int page,
    required int limit,
    required Set<String> seen,
    required DateTime deadline,
  }) async {
    final out = <VideoItem>[];
    final offset = (page - 1) * limit;
    final categoryQueries = switch (tagId) {
      'couples' => const ['&genders=c'],
      'new' => const ['&genders=f&sort_order=new'],
      'asian' => const ['&genders=f&tags=asian'],
      // Chaturbate has used each of these aliases in different room-list APIs.
      'outdoor' => const [
          '&genders=f&tags=outdoors',
          '&genders=f&tags=outdoor',
          '&genders=f&tags=outside',
        ],
      'hd' => const [
          '&genders=f&tags=hd',
          '&genders=f&tags=high-definition',
          '&genders=f&tags=high_definition',
        ],
      'male' => const ['&genders=m'],
      'trans' => const ['&genders=t'],
      'female' || 'popular' => const ['&genders=f'],
      _ => ['&genders=f&tags=${Uri.encodeQueryComponent(tagId)}'],
    };
    final legacyQueries = switch (tagId) {
      'couples' => const ['&gender=c'],
      'new' => const ['&gender=f&sort=new'],
      'asian' => const ['&gender=f&tag=asian'],
      'outdoor' => const [
          '&gender=f&tag=outdoors',
          '&gender=f&tag=outdoor',
          '&gender=f&tag=outside',
        ],
      'hd' => const [
          '&gender=f&tag=hd',
          '&gender=f&tag=high-definition',
          '&gender=f&tag=high_definition',
        ],
      'male' => const ['&gender=m'],
      'trans' => const ['&gender=t'],
      'female' || 'popular' => const ['&gender=f'],
      _ => ['&gender=f&tag=${Uri.encodeQueryComponent(tagId)}'],
    };
    final endpoints = <String Function(String)>[
      for (final query in categoryQueries)
        (b) =>
            '$b/api/ts/roomlist/room-list/?limit=${limit.clamp(20, 90)}&offset=$offset$query',
      for (final query in legacyQueries)
        (b) =>
            '$b/affiliates/api/onlinerooms/?format=json&limit=$limit&offset=$offset$query',
    ];
    for (final pathFn in endpoints) {
      try {
        final html = await _fetchWithMirrors(
          site,
          pathFn,
          deadline: deadline,
        );
        final base = _mirrorsFor(
          site,
        )[_mirrorIndex[site.id] ?? 0]
            .replaceAll(RegExp(r'/$'), '');
        out.addAll(_parseLiveJson(html, base, seen, site, tagId: tagId));
        if (out.isNotEmpty) return out;
      } catch (e) {
        if (e is DioException && CancelToken.isCancel(e)) rethrow;
      }
    }
    return out;
  }

  Future<List<VideoItem>> _fetchStripchatApi(
    SiteDef site, {
    required String tagId,
    required int page,
    required int limit,
    required Set<String> seen,
    required DateTime deadline,
  }) async {
    final out = <VideoItem>[];
    final offset = (page - 1) * limit + (tagId == 'more' ? 60 : 0);
    final primaryTag = switch (tagId) {
      'couples' => 'couples',
      'girls' || 'female' || 'new' || 'popular' || 'more' => 'girls',
      _ => tagId,
    };
    final sortBy = tagId == 'new' ? 'newModels' : 'stripRanking';
    final endpoints = <String Function(String)>[
      (b) =>
          '$b/api/front/models?limit=${limit.clamp(20, 80)}&offset=$offset&primaryTag=$primaryTag&sortBy=$sortBy',
      (b) =>
          '$b/api/models?limit=$limit&offset=$offset&primaryTag=$primaryTag&sortBy=$sortBy',
      (b) =>
          '$b/api/front/v2/models?limit=$limit&offset=$offset&primaryTag=$primaryTag&sortBy=$sortBy',
    ];
    for (final pathFn in endpoints) {
      try {
        final html = await _fetchWithMirrors(
          site,
          pathFn,
          deadline: deadline,
        );
        final base = _mirrorsFor(
          site,
        )[_mirrorIndex[site.id] ?? 0]
            .replaceAll(RegExp(r'/$'), '');
        out.addAll(_parseLiveJson(html, base, seen, site, tagId: tagId));
        if (out.isNotEmpty) return out;
      } catch (e) {
        if (e is DioException && CancelToken.isCancel(e)) rethrow;
      }
    }
    return out;
  }

  List<VideoItem> _parseGenericJsonList(
    String raw,
    String base,
    Set<String> seen,
    SiteDef site,
  ) {
    final out = <VideoItem>[];
    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return out;
    }

    String? firstString(Map<String, dynamic> map, List<String> keys) {
      for (final key in keys) {
        final value = map[key];
        if (value is String && value.trim().isNotEmpty) return value.trim();
        if (value is Map) {
          final nested = Map<String, dynamic>.from(value);
          for (final nestedKey in const ['url', 'src', 'path']) {
            final nestedValue = nested[nestedKey];
            if (nestedValue is String && nestedValue.trim().isNotEmpty) {
              return nestedValue.trim();
            }
          }
        }
      }
      return null;
    }

    void visit(dynamic node) {
      if (out.length >= 80) return;
      if (node is List) {
        for (final child in node) {
          visit(child);
          if (out.length >= 80) break;
        }
        return;
      }
      if (node is! Map) return;
      final map = Map<String, dynamic>.from(node);
      var href = firstString(map, const [
        'path',
        'url',
        'link',
        'permalink',
        'videoUrl',
        'video_url',
      ]);
      final slug = firstString(map, const ['slug']);
      href ??= slug;
      if (href != null) {
        href = href.replaceAll(r'\/', '/');
        if (slug == href && !href.contains('/') && site.id == 'av01') {
          href = '/v/$href';
        }
        final title = firstString(map, const [
          'title',
          'name',
          'videoTitle',
          'video_title',
        ]);
        if (title != null &&
            title.length >= 2 &&
            !_isJunkTitle(title) &&
            _looksLikeVideoPath(href, site)) {
          final abs = _abs(base, href);
          final key = abs.split('#').first.split('?').first;
          if (seen.add(key)) {
            final thumb = firstString(map, const [
              'thumbnail',
              'thumb',
              'image',
              'poster',
              'cover',
            ]);
            final duration = firstString(map, const [
                  'duration',
                  'durationText',
                  'duration_text',
                ]) ??
                '-';
            out.add(
              VideoItem(
                url: abs,
                title: _cleanTitle(title),
                duration: duration,
                thumb: thumb == null ? null : _abs(base, thumb),
              ),
            );
          }
        }
      }
      for (final value in map.values) {
        if (value is Map || value is List) visit(value);
        if (out.length >= 80) break;
      }
    }

    visit(decoded);
    return out;
  }

  Future<List<VideoItem>> search(
    SiteDef site,
    String query, {
    int page = 1,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return [];
    final deadline = DateTime.now().add(_searchResolveTimeout);
    final enc = Uri.encodeQueryComponent(q);
    final paths = _searchPaths(site, enc, page);
    final seen = <String>{};
    for (final pathFn in paths) {
      try {
        final fetched = await _fetchPageWithMirrors(
          site,
          pathFn,
          deadline: deadline,
          accept: (html, base) =>
              _parseSearchResponse(html, base, <String>{}, site).isNotEmpty,
        );
        final list = _parseSearchResponse(
          fetched.html,
          fetched.base,
          seen,
          site,
        );
        if (list.isNotEmpty) return list;
      } catch (e) {
        if (e is DioException && CancelToken.isCancel(e)) rethrow;
        if (DateTime.now().isAfter(deadline)) break;
        continue;
      }
    }
    return [];
  }

  List<VideoItem> _parseSearchResponse(
    String body,
    String base,
    Set<String> seen,
    SiteDef site,
  ) {
    final trim = body.trimLeft();
    if (trim.startsWith('{') || trim.startsWith('[')) {
      return _parseGenericJsonList(body, base, seen, site);
    }
    return _parseList(body, base, seen, site);
  }

  Future<VideoDetail> getVideoDetail(SiteDef site, String url) async {
    final deadline = DateTime.now().add(_detailResolveTimeout);
    if (site.isStripchat) {
      throw PhubException('Stripchat 使用房间 WebRTC 实时播放，不使用预览 HLS');
    }
    if (site.kind == SiteKind.live) {
      final fast = await _getLiveDetailFast(site, url, deadline);
      if (fast != null) return fast;
    }
    final parsed = Uri.tryParse(url);
    final suffix = parsed == null
        ? url
        : '${parsed.path}${parsed.hasQuery ? '?${parsed.query}' : ''}';
    final candidates = <({String url, String base, int? mirrorIndex})>[];
    final originalBase = _originOf(url);
    if (originalBase != null) {
      candidates.add((url: url, base: originalBase, mirrorIndex: null));
    }
    final mirrors = _mirrorsFor(site);
    final start = (_mirrorIndex[site.id] ?? 0).clamp(0, mirrors.length - 1);
    for (var n = 0; n < mirrors.length; n++) {
      final i = (start + n) % mirrors.length;
      final base = mirrors[i].replaceAll(RegExp(r'/$'), '');
      final candidateUrl = _abs(
        base,
        suffix.startsWith('/') ? suffix : '/$suffix',
      );
      if (candidates.any((e) => e.url == candidateUrl)) continue;
      candidates.add((url: candidateUrl, base: base, mirrorIndex: i));
    }

    Object? lastError;
    for (final candidate in candidates) {
      try {
        final remaining = deadline.difference(DateTime.now());
        if (remaining.inMilliseconds <= 0) break;
        final pageHeaders = AppHttpHeaders.forSite(candidate.base);
        var html = await _getHtml(
          candidate.url,
          headers: pageHeaders,
          timeout: remaining < _requestTimeout ? remaining : _requestTimeout,
        );
        if (_isBlockedHtml(html)) {
          final renderBudget = deadline.difference(DateTime.now());
          if (renderBudget.inMilliseconds > 0) {
            final rendered = await _nativeRenderHtml(
              candidate.url,
              origin: _originOf(candidate.url),
              headers: pageHeaders,
              timeout: renderBudget,
            );
            if (rendered != null) html = rendered;
          }
          if (_isBlockedHtml(html)) {
            throw PhubException('页面被拦截或无效');
          }
        }
        final parseBudget = deadline.difference(DateTime.now());
        if (parseBudget.inMilliseconds <= 0) break;
        late VideoDetail detail;
        try {
          detail = await _parseVideoDetail(
            site,
            candidate.url,
            html,
            candidate.base,
          ).timeout(parseBudget);
        } catch (parseError) {
          if (parseError is DioException && CancelToken.isCancel(parseError)) {
            rethrow;
          }
          final renderBudget = deadline.difference(DateTime.now());
          if (renderBudget.inMilliseconds <= 0) rethrow;
          final rendered = await _nativeRenderHtml(
            candidate.url,
            origin: _originOf(candidate.url),
            headers: pageHeaders,
            timeout: renderBudget,
          );
          if (rendered == null || rendered == html) rethrow;
          html = rendered;
          final renderedParseBudget = deadline.difference(DateTime.now());
          if (renderedParseBudget.inMilliseconds <= 0) rethrow;
          detail = await _parseVideoDetail(
            site,
            candidate.url,
            html,
            candidate.base,
          ).timeout(renderedParseBudget);
        }
        if (candidate.mirrorIndex != null) {
          _mirrorIndex[site.id] = candidate.mirrorIndex!;
        }
        // Plan A: real streams first; if empty, keep page URL for in-app WebView.
        if (detail.streams.isEmpty && site.kind == SiteKind.video) {
          return VideoDetail(
            url: detail.url,
            title: detail.title,
            description: detail.description,
            durationSec: detail.durationSec,
            thumb: detail.thumb,
            streams: const [],
            browserPlaybackUrl: candidate.url,
          );
        }
        return detail;
      } catch (e) {
        if (e is DioException && CancelToken.isCancel(e)) rethrow;
        lastError = e;
      }
    }
    // Last resort: open the original page in App WebView (not system browser).
    if (site.kind == SiteKind.video && url.startsWith('http')) {
      return VideoDetail(
        url: url,
        title: site.name,
        durationSec: 0,
        streams: const [],
        browserPlaybackUrl: url,
      );
    }
    if (DateTime.now().isAfter(deadline)) {
      throw PhubException('${site.name} 播放地址解析超时');
    }
    throw lastError ?? PhubException('无法解析播放地址：${site.name}');
  }

  Future<VideoDetail?> _getLiveDetailFast(
    SiteDef site,
    String pageUrl,
    DateTime deadline,
  ) async {
    final room = _usernameFromUrl(pageUrl);
    if (room == null || room.isEmpty) return null;

    if (site.isStripchat) {
      // Its public HLS path can redirect to a 20-second CPA VOD. The feed
      // screen therefore uses the room's real WebRTC player in WKWebView and
      // must never hand this preview URL to AVPlayer.
      return null;
    }

    if (site.isChaturbate) {
      final cached = _liveStreamNames['chaturbate:${room.toLowerCase()}'];
      if (cached != null && cached.contains('.m3u8')) {
        return VideoDetail(
          url: pageUrl,
          title: room,
          durationSec: 0,
          streams: [
            StreamQuality(
              width: 1280,
              height: 720,
              url: cached,
              referer: pageUrl,
            ),
          ],
        );
      }
      try {
        final fetched = await _fetchPageWithMirrors(
          site,
          (base) => '$base/api/chatvideocontext/$room/',
          deadline: deadline,
          extraHeaders: const {
            'Accept': 'application/json,text/plain,*/*',
            'X-Requested-With': 'XMLHttpRequest',
          },
          accept: (body, _) => body.toLowerCase().contains('.m3u8'),
        );
        final streams = await _extractLiveStreams(
          site,
          pageUrl,
          fetched.html,
          fetched.base,
        );
        if (streams.isNotEmpty) {
          return VideoDetail(
            url: pageUrl,
            title: room,
            durationSec: 0,
            streams: streams,
          );
        }
      } catch (e) {
        if (e is DioException && CancelToken.isCancel(e)) rethrow;
      }
    }
    return null;
  }

  Future<VideoDetail> _parseVideoDetail(
    SiteDef site,
    String url,
    String html,
    String base,
  ) async {
    // Live rooms: try HLS from room page / API snippets
    if (site.kind == SiteKind.live) {
      if (site.isStripchat) {
        throw PhubException('Stripchat 使用房间 WebRTC 实时播放，不使用预览 HLS');
      }
      final live = await _extractLiveStreams(site, url, html, base);
      if (live.isNotEmpty) {
        return VideoDetail(
          url: url,
          title: _extractTitle(html) ?? _usernameFromUrl(url) ?? site.name,
          durationSec: 0,
          thumb: _resolvedThumb(html, url),
          streams: live,
        );
      }
      throw PhubException('无法获取直播流：${site.name}（主播可能离线）');
    }

    // Eporner: dedicated AJAX/download endpoints
    if (site.id == 'eporner') {
      final ep = await _extractEpornerStreams(url, html, base);
      if (ep.isNotEmpty) {
        return VideoDetail(
          url: url,
          title: _extractTitle(html) ?? url,
          durationSec: _extractDurationSec(html),
          thumb: _resolvedThumb(html, url),
          streams: ep,
        );
      }
    }

    // MindGeek family (YouPorn / RedTube): mediaDefinitions like Pornhub
    if (site.id == 'youporn' || site.id == 'redtube') {
      final mg = _extractMindGeekStreams(html, pageUrl: url);
      if (mg.isNotEmpty) {
        return VideoDetail(
          url: url,
          title: _extractTitle(html) ?? url,
          durationSec: _extractDurationSec(html),
          thumb: _resolvedThumb(html, url),
          streams: mg,
        );
      }
    }

    var title = _extractTitle(html) ?? url;
    // MissAV / JAV list pages often leak wrong og:title — prefer code in URL
    if (site.id == 'missav' ||
        site.id == 'javmix' ||
        site.id == 'javgg' ||
        site.id == 'jable' ||
        site.id == '7mmtv') {
      final code = _javCodeFromUrl(url);
      if (code != null) {
        final tLow = title.toLowerCase();
        if (!tLow.contains(code.toLowerCase()) ||
            title.length < 4 ||
            _isJunkTitle(title)) {
          title = code;
        }
      }
    }

    final thumb = _resolvedThumb(html, url);
    // Resolve site-specific player formats before broad URL matching. This
    // avoids mistaking hover previews and ad assets for the full video.
    var streams = <StreamQuality>[];
    // Our55 / 88XQQ: DES-encrypted player payload (video.id + data[]).
    if (site.id == 'our55' || site.id == 'xqq88') {
      streams = _extractEncryptedSiteStreams(html, url);
    }
    if (site.id == 'javmix' || site.id == 'javgg') {
      // Current JAVMix pages expose a fresh signed JSON-LD contentUrl while
      // their player video_url may already be stale. Older KVS pages need the
      // embed page, so only prefer the main page when contentUrl is present.
      final hasContentUrl = RegExp(
        r'''["']contentUrl["']\s*:''',
        caseSensitive: false,
      ).hasMatch(html);
      streams = hasContentUrl
          ? _extractKvsStreams(html, url)
          : await _followEmbeds(html, url, url, depth: 2);
    }
    if (streams.isEmpty) {
      streams = <StreamQuality>[
        ..._extractEncryptedSiteStreams(html, url),
        ..._extractKvsStreams(html, url),
      ];
    }
    if (streams.isEmpty) {
      streams = _extractVideoInitialDataStreams(html, url);
    }
    if (streams.isEmpty) {
      streams = _extractStreams(html, url);
    }

    // MissAV / Jable often put m3u8 in packed JS or data-src
    if (streams.isEmpty) {
      streams = _extractStreamsLoose(html, url);
    }
    if (streams.isEmpty) {
      streams = await _resolveMacCmsPlayer(html, url, url);
    }
    // Follow embed iframe (up to 2 levels)
    if (streams.isEmpty) {
      streams = await _followEmbeds(html, url, url, depth: 2);
    }
    // SpankBang stream_url / stream_data
    if (streams.isEmpty && site.id == 'spankbang') {
      streams = _extractSpankbang(html, base);
    }
    // BestJAVPorn data-mediabook / encrypted player (best-effort)
    if (streams.isEmpty && site.id == 'bestjavporn') {
      streams = _extractBestJav(html, base);
    }

    streams = _filterPreviewStreams(streams);
    if (streams.isEmpty) {
      // Do not throw: caller attaches browserPlaybackUrl for in-app WebView.
      return VideoDetail(
        url: url,
        title: title,
        durationSec: _extractDurationSec(html),
        thumb: thumb,
        streams: const [],
        browserPlaybackUrl: url,
      );
    }
    streams.sort((a, b) {
      final ah = a.url.toLowerCase().contains('.m3u8') ? 1 : 0;
      final bh = b.url.toLowerCase().contains('.m3u8') ? 1 : 0;
      if (ah != bh) return bh.compareTo(ah);
      return b.pixels.compareTo(a.pixels);
    });
    return VideoDetail(
      url: url,
      title: title,
      durationSec: _extractDurationSec(html),
      thumb: thumb,
      streams: streams,
    );
  }

  String? _usernameFromUrl(String url) {
    final parts = Uri.tryParse(url)?.pathSegments ?? const [];
    for (final p in parts.reversed) {
      if (p.isEmpty) continue;
      if (RegExp(r'^[a-zA-Z0-9_-]{3,60}$').hasMatch(p)) return p;
    }
    return null;
  }

  String? _javCodeFromUrl(String url) {
    final m = RegExp(r'([a-zA-Z]{2,12}-?\d{2,5}[a-zA-Z]?)').firstMatch(url);
    return m?.group(1)?.toUpperCase();
  }

  int _extractDurationSec(String html) {
    final iso = _metaContent(html, {'duration'});
    if (iso != null) {
      final match = RegExp(
        r'^P(?:(\d+)D)?T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?$',
        caseSensitive: false,
      ).firstMatch(iso);
      if (match != null) {
        final days = int.tryParse(match.group(1) ?? '') ?? 0;
        final hours = int.tryParse(match.group(2) ?? '') ?? 0;
        final minutes = int.tryParse(match.group(3) ?? '') ?? 0;
        final seconds = int.tryParse(match.group(4) ?? '') ?? 0;
        final total = days * 86400 + hours * 3600 + minutes * 60 + seconds;
        if (total > 0) return total;
      }
    }
    final meta = RegExp(
      r'<meta[^>]*(?:property|name)=["'
      '](?:video:)?duration["'
      '][^>]*content=["'
      '](\\d+)["'
      ']',
      caseSensitive: false,
    ).firstMatch(html);
    if (meta != null) return int.tryParse(meta.group(1)!) ?? 0;
    final flash = RegExp(
      r'''["']video_duration["']\s*:\s*["']?(\d+)''',
    ).firstMatch(html);
    if (flash != null) return int.tryParse(flash.group(1)!) ?? 0;
    final seconds = RegExp(
      r'''["'](?:length_sec|duration_sec)["']\s*:\s*["']?(\d+)''',
      caseSensitive: false,
    ).firstMatch(html);
    if (seconds != null) return int.tryParse(seconds.group(1)!) ?? 0;
    final minutes = RegExp(
      r'''(?:class=["'][^"']*vid-length[^"']*["'][^>]*>|Duration:\s*)(\d+)\s*min''',
      caseSensitive: false,
    ).firstMatch(html);
    if (minutes != null) return (int.tryParse(minutes.group(1)!) ?? 0) * 60;
    final fallback = _durationSecondsFromText(html);
    if (fallback != null) return fallback;
    return 0;
  }

  String? _macCmsPlayerBlob(String html) {
    for (final re in [
      RegExp(
        r'player_aaaa\s*=\s*(\{[\s\S]*?\})\s*;?\s*</script>',
        caseSensitive: false,
      ),
      RegExp(r'player_aaaa\s*=\s*(\{[\s\S]*?\})\s*;', caseSensitive: false),
      RegExp(r'player_data\s*=\s*(\{[\s\S]*?\})\s*;', caseSensitive: false),
    ]) {
      final match = re.firstMatch(html);
      if (match != null) return match.group(1);
    }
    return null;
  }

  String _decodeMacCmsUrl(String value, int encrypt) {
    var decoded = value.replaceAll(r'\/', '/');
    try {
      if (encrypt == 2) decoded = utf8.decode(base64.decode(decoded));
      if (encrypt == 1 || encrypt == 2) decoded = Uri.decodeFull(decoded);
    } catch (_) {}
    return decoded;
  }

  bool _looksLikeMediaUrl(String url) {
    final low = url.toLowerCase();
    return low.contains('.m3u8') ||
        low.contains('.mp4') ||
        low.contains('.flv') ||
        low.contains('.webm');
  }

  Future<List<StreamQuality>> _resolveMacCmsPlayer(
    String html,
    String pageUrl,
    String base,
  ) async {
    final blob = _macCmsPlayerBlob(html);
    if (blob == null) return const [];
    final urlMatch = RegExp(
      r'''["']url["']\s*:\s*["']([^"']+)["']''',
    ).firstMatch(blob);
    if (urlMatch == null) return const [];
    final encrypt = int.tryParse(
          RegExp(
                r'''["']encrypt["']\s*:\s*["']?(\d+)''',
              ).firstMatch(blob)?.group(1) ??
              '',
        ) ??
        0;
    final playerUrl = _decodeMacCmsUrl(urlMatch.group(1)!, encrypt);
    if (_looksLikeMediaUrl(playerUrl)) {
      return _extractStreams('"file":"$playerUrl"', base);
    }

    final parse = RegExp(
      r'''["']parse["']\s*:\s*["']([^"']+)["']''',
    ).firstMatch(blob)?.group(1)?.replaceAll(r'\/', '/');
    String target;
    if (parse != null && parse.isNotEmpty) {
      final resolver = _abs(base, parse);
      final encoded = Uri.encodeQueryComponent(playerUrl);
      if (resolver.contains('{url}')) {
        target = resolver.replaceAll('{url}', encoded);
      } else if (resolver.endsWith('=') || resolver.endsWith('/')) {
        target = '$resolver$encoded';
      } else {
        target = '$resolver${resolver.contains('?') ? '&' : '?'}url=$encoded';
      }
    } else {
      target = _abs(base, playerUrl);
    }

    try {
      final resolvedHtml = await _getHtml(
        target,
        headers: {
          ...AppHttpHeaders.forSite(_originOf(target) ?? base),
          'Referer': pageUrl,
        },
      );
      var streams = _extractStreams(resolvedHtml, _originOf(target) ?? base);
      if (streams.isEmpty) {
        streams = _extractStreamsLoose(resolvedHtml, _originOf(target) ?? base);
      }
      if (streams.isEmpty) {
        streams = await _followEmbeds(
          resolvedHtml,
          target,
          target,
          depth: 1,
        );
      }
      return _filterPreviewStreams(streams);
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) rethrow;
      return const [];
    }
  }

  Future<List<StreamQuality>> _followEmbeds(
    String html,
    String pageUrl,
    String base, {
    int depth = 1,
  }) async {
    if (depth <= 0) return const [];
    final re = RegExp(
      r'''<iframe[^>]+(?:src|data-src|data-lazy-src|data-embed)=["']([^"']+)["']''',
      caseSensitive: false,
    );
    for (final emb in re.allMatches(html)) {
      try {
        final embUrl = _abs(pageUrl, emb.group(1)!);
        if (embUrl.contains('google') ||
            embUrl.contains('facebook') ||
            embUrl.contains('twitter')) {
          continue;
        }
        final embHtml = await _getHtml(
          embUrl,
          headers: {
            ...AppHttpHeaders.forSite(_originOf(embUrl) ?? base),
            'Referer': pageUrl,
          },
        );
        var streams = <StreamQuality>[
          ..._extractEncryptedSiteStreams(embHtml, embUrl),
          ..._extractKvsStreams(embHtml, embUrl),
        ];
        if (streams.isEmpty) {
          streams = _extractStreams(embHtml, embUrl);
        }
        if (streams.isEmpty) {
          streams = _extractStreamsLoose(embHtml, embUrl);
        }
        if (streams.isEmpty) {
          streams = await _followEmbeds(
            embHtml,
            embUrl,
            embUrl,
            depth: depth - 1,
          );
        }
        streams = _filterPreviewStreams(streams);
        if (streams.isNotEmpty) return streams;
      } catch (e) {
        if (e is DioException && CancelToken.isCancel(e)) rethrow;
      }
    }
    return const [];
  }

  Future<List<StreamQuality>> _extractEpornerStreams(
    String pageUrl,
    String html,
    String base,
  ) async {
    final out = <StreamQuality>[];
    // Direct in page (gvideo.eporner.com / static mp4)
    out.addAll(_extractStreams(html, base));
    out.addAll(_extractStreamsLoose(html, base));
    for (final m in RegExp(
      r'''(https?://(?:gvideo|static)[^"'<\s]+\.mp4[^"'<\s]*)''',
      caseSensitive: false,
    ).allMatches(html)) {
      final u = m.group(1)!.replaceAll(r'\/', '/');
      if (!_isPreviewUrl(u)) {
        out.add(
          StreamQuality(
            width: 1280,
            height: 720,
            url: u,
            referer: pageUrl,
          ),
        );
      }
    }

    // /xhr/video/ID or download hash links
    final idm = RegExp(r'/video-([A-Za-z0-9]+)/').firstMatch(pageUrl) ??
        RegExp(r'/hd-porn/([A-Za-z0-9]+)/').firstMatch(pageUrl) ??
        RegExp(r'/video-([A-Za-z0-9]+)/').firstMatch(html) ??
        RegExp(r'/embed/([A-Za-z0-9]+)/').firstMatch(pageUrl);
    final vid = idm?.group(1);
    if (vid != null) {
      // Public progressive URL often works without xhr auth.
      final progressive = 'https://gvideo.eporner.com/$vid/$vid.mp4';
      out.add(
        StreamQuality(
          width: 1280,
          height: 720,
          url: progressive,
          referer: pageUrl,
        ),
      );
      for (final path in [
        '/api/v2/video/id/?id=$vid&format=json',
        '/xhr/video/$vid/',
        '/download-video/$vid/',
      ]) {
        try {
          final raw = await _getHtml(
            '$base$path',
            headers: {
              ...AppHttpHeaders.forSite(base),
              'Referer': pageUrl,
              'X-Requested-With': 'XMLHttpRequest',
              'Accept': 'application/json,text/plain,*/*',
            },
          );
          out.addAll(_extractStreams(raw, base));
          out.addAll(_extractStreamsLoose(raw, base));
          // eporner sources array
          for (final m in RegExp(
            r'''"(?:src|url)"\s*:\s*"(https?:[^"]+)"''',
          ).allMatches(raw)) {
            final u = m.group(1)!.replaceAll(r'\/', '/');
            if ((u.contains('.mp4') || u.contains('.m3u8')) &&
                !_isPreviewUrl(u)) {
              out.add(
                StreamQuality(
                  width: 1280,
                  height: 720,
                  url: u,
                  referer: pageUrl,
                ),
              );
            }
          }
        } catch (e) {
          if (e is DioException && CancelToken.isCancel(e)) rethrow;
        }
      }
    }
    return _filterPreviewStreams(out);
  }

  List<StreamQuality> _extractMindGeekStreams(String html, {String? pageUrl}) {
    final streams = <StreamQuality>[];
    final seen = <String>{};
    final origin = pageUrl == null ? null : _originOf(pageUrl);

    // mediaDefinitions JSON array (Pornhub / YouPorn / RedTube)
    final block = RegExp(
      r'''mediaDefinitions\s*[:=]\s*(\[[\s\S]*?\])\s*[,;}]''',
    ).firstMatch(html);
    final blob = block?.group(1) ?? html;

    // Absolute or relative videoUrl (RedTube often uses /media/hls?s=...)
    for (final m in RegExp(
      r'''\{[^{}]*?"videoUrl"\s*:\s*"((?:https?:)?[^"]+)"[^{}]*?\}''',
      caseSensitive: false,
    ).allMatches(blob)) {
      final obj = m.group(0)!;
      var url = RegExp(
        r'''"videoUrl"\s*:\s*"((?:https?:)?[^"]+)"''',
      ).firstMatch(obj)?.group(1)?.replaceAll(r'\/', '/');
      if (url == null || url.isEmpty) continue;
      if (url.startsWith('//')) url = 'https:$url';
      if (url.startsWith('/') && origin != null) url = '$origin$url';
      if (!url.startsWith('http')) continue;
      if (_isPreviewUrl(url)) continue;
      // Prefer full streams; HLS ordering is applied after all candidates parse.
      var height = int.tryParse(
            RegExp(r'''"height"\s*:\s*(\d+)''').firstMatch(obj)?.group(1) ?? '',
          ) ??
          0;
      if (height <= 0) {
        height = int.tryParse(
              RegExp(
                    r'''"quality"\s*:\s*"?(\d+)''',
                  ).firstMatch(obj)?.group(1) ??
                  '',
            ) ??
            0;
      }
      if (height <= 0) {
        height = url.contains('m3u8') ? 720 : 480;
      }
      if (!seen.add(url)) continue;
      final width = (height * 16 / 9).round();
      streams.add(StreamQuality(width: width, height: height, url: url));
    }

    // qualityItems (YouPorn)
    for (final m in RegExp(
      r'''"quality_(\d+p)"\s*:\s*"((?:https?:)?[^"]+)"''',
    ).allMatches(html)) {
      var url = m.group(2)!.replaceAll(r'\/', '/');
      if (url.startsWith('//')) url = 'https:$url';
      if (url.startsWith('/') && origin != null) url = '$origin$url';
      if (!url.startsWith('http')) continue;
      if (_isPreviewUrl(url)) continue;
      if (!seen.add(url)) continue;
      final h = int.tryParse(m.group(1)!.replaceAll('p', '')) ?? 720;
      streams.add(
        StreamQuality(width: (h * 16 / 9).round(), height: h, url: url),
      );
    }

    // Loose videoUrl / media path scan for RedTube-style pages
    for (final m in RegExp(
      r'''["']videoUrl["']\s*:\s*["']((?:https?:)?[^"']+)["']''',
      caseSensitive: false,
    ).allMatches(html)) {
      var url = m.group(1)!.replaceAll(r'\/', '/');
      if (url.startsWith('//')) url = 'https:$url';
      if (url.startsWith('/') && origin != null) url = '$origin$url';
      if (!url.startsWith('http')) continue;
      if (_isPreviewUrl(url)) continue;
      if (!seen.add(url)) continue;
      final isHls = url.contains('hls') || url.contains('m3u8');
      streams.add(
        StreamQuality(
          width: isHls ? 1280 : 854,
          height: isHls ? 720 : 480,
          url: url,
          referer: pageUrl,
        ),
      );
    }

    return streams;
  }

  List<StreamQuality> _extractSpankbang(String html, String base) {
    final out = <StreamQuality>[];
    final streamData = RegExp(
      r'''stream_data\s*=\s*(\{[\s\S]*?\})\s*;''',
    ).firstMatch(html);
    final blob = streamData?.group(1) ?? html;
    for (final m in RegExp(
      r'''["'](\d+p)["']\s*:\s*\[\s*["'](https?[^"']+)["']''',
    ).allMatches(blob)) {
      final h = int.tryParse(m.group(1)!.replaceAll('p', '')) ?? 720;
      final u = m.group(2)!.replaceAll(r'\/', '/');
      if (!_isPreviewUrl(u)) {
        out.add(StreamQuality(width: (h * 16 / 9).round(), height: h, url: u));
      }
    }
    for (final key in [
      'm3u8',
      'stream_url_240p',
      'stream_url_320p',
      'stream_url_480p',
      'stream_url_720p',
      'stream_url_1080p',
    ]) {
      final m = RegExp(
        '''['"]$key['"]\\s*:\\s*['"](https?[^"']+)['"]''',
      ).firstMatch(html);
      if (m != null) {
        final u = m.group(1)!.replaceAll(r'\/', '/');
        if (!_isPreviewUrl(u)) {
          out.add(StreamQuality(width: 1280, height: 720, url: u));
        }
      }
    }
    out.addAll(_extractStreams(html, base));
    return _filterPreviewStreams(out);
  }

  /// Kernel Video Sharing player used by current JavMix/JavGG mirrors.
  List<StreamQuality> _extractKvsStreams(String html, String base) {
    final out = <StreamQuality>[];
    final seen = <String>{};
    final origin = _originOf(base);
    final cookie = origin == null ? null : _cookieHeader(origin);
    for (final match in RegExp(
      r'''(?:["']contentUrl["']\s*:|video_url\s*:|event_reporting2\s*:|video_alt_url\d*\s*:)[\s]*["']([^"']+)["']''',
      caseSensitive: false,
    ).allMatches(html)) {
      var value = match.group(1)!.replaceAll(r'\/', '/').trim();
      final absoluteAt = value.indexOf('http');
      if (absoluteAt > 0 && value.startsWith('function/')) {
        value = value.substring(absoluteAt);
      }
      if (!value.startsWith('http')) value = _abs(base, value);
      final low = value.toLowerCase();
      if (!low.contains('/get_file/') &&
          !low.contains('.mp4') &&
          !low.contains('.m3u8')) {
        continue;
      }
      if (RegExp(r'''\.(?:jpe?g|png|webp|gif)(?:[?#]|$)''').hasMatch(low)) {
        continue;
      }
      if (_isPreviewUrl(value) || !seen.add(value)) continue;
      out.add(
        StreamQuality(
          width: low.contains('1080p')
              ? 1920
              : low.contains('720p')
                  ? 1280
                  : 854,
          height: low.contains('1080p')
              ? 1080
              : low.contains('720p') || low.contains('m3u8')
                  ? 720
                  : 480,
          url: value,
          referer: base,
          headers: {if (cookie != null) 'Cookie': cookie},
        ),
      );
    }
    final embedded = out.where((stream) => stream.url.contains('embed=true'));
    return embedded.isNotEmpty ? embedded.toList() : out;
  }

  /// Our55/88XQQ family encrypts `label$hlsUrl` with DES-ECB-PKCS7. The key
  /// is the first eight UTF-8 bytes of the video id, matching CryptoJS DES.
  List<StreamQuality> _extractEncryptedSiteStreams(
    String html,
    String pageUrl,
  ) {
    // Prefer structured video:{ id, data:[] }; also accept decrypt_req(data, id).
    final config = RegExp(
      r'''video\s*:\s*\{[\s\S]{0,800}?id\s*:\s*["']([^"']+)["'][\s\S]{0,800}?data\s*:\s*\[([^\]]+)\]''',
      caseSensitive: false,
    ).firstMatch(html);
    String? id = config?.group(1);
    String encodedBlob = config?.group(2) ?? '';
    if (id == null || encodedBlob.isEmpty) {
      final alt = RegExp(
        r'''decrypt_req\s*\(\s*["']([A-Za-z0-9+/=]{24,})["']\s*,\s*["']([a-f0-9]{16,})["']\s*\)''',
        caseSensitive: false,
      ).firstMatch(html);
      if (alt != null) {
        encodedBlob = '"${alt.group(1)!}"';
        id = alt.group(2);
      }
    }
    if (id == null || utf8.encode(id).length < 8) return const [];

    final out = <StreamQuality>[];
    final seen = <String>{};
    final encodedValues = encodedBlob.replaceAll(r'\/', '/');
    for (final encodedMatch in RegExp(
      r'''["']([A-Za-z0-9+/]{24,}={0,2})["']''',
    ).allMatches(encodedValues)) {
      try {
        final clear = DesEcbPkcs7.decryptBase64Utf8(
          encodedMatch.group(1)!,
          id,
        );
        // Payload is usually "清晰度$https://...m3u8" (may have multiple $ parts).
        for (final part in clear.split(r'$').map((e) => e.trim())) {
          if (!part.startsWith('http')) continue;
          final low = part.toLowerCase();
          if (!low.contains('.m3u8') && !low.contains('.mp4')) continue;
          if (_isPreviewUrl(part) || !seen.add(part)) continue;
          final origin = _originOf(pageUrl);
          final cookie = origin == null ? null : _cookieHeader(origin);
          final isHls = low.contains('.m3u8');
          out.add(
            StreamQuality(
              width: isHls ? 1280 : 854,
              height: isHls ? 720 : 480,
              url: part,
              referer: pageUrl,
              headers: {
                if (cookie != null) 'Cookie': cookie,
                // Some CDNs check Origin for these Chinese tube mirrors.
                if (origin != null) 'Origin': origin,
              },
            ),
          );
        }
      } catch (_) {}
    }
    return out;
  }

  /// Some Chinese-drama / JS-player sites embed a <script id="videoInitialData">
  /// JSON block with per-episode HLS URLs (epPlaySrcs) or a single videoSrc.
  List<StreamQuality> _extractVideoInitialDataStreams(String html, String url) {
    final m = RegExp(
      r'''<script[^>]*id=["']videoInitialData["'][^>]*>(.*?)</script>''',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(html);
    if (m == null) return const [];
    Object? data;
    try {
      data = jsonDecode(m.group(1)!.trim());
    } catch (_) {
      return const [];
    }
    if (data is! Map<String, dynamic>) return const [];
    final candidates = <String>{};
    void absorb(Object? v) {
      if (v is String && v.trim().isNotEmpty) candidates.add(v.trim());
      if (v is List) {
        for (final e in v) {
          absorb(e);
        }
      }
      if (v is Map) {
        for (final e in v.values) {
          absorb(e);
        }
      }
    }

    absorb(data['epPlaySrcs']);
    absorb(data['videoSrc']);
    final out = <StreamQuality>[];
    final base =
        Uri.tryParse(url)?.hasScheme == true ? Uri.parse(url).origin : '';
    final checked = <String>{};
    for (final c in candidates) {
      final resolved =
          c.startsWith('/') && base.isNotEmpty ? '$base$c' : c;
      if (!checked.add(resolved)) continue;
      final low = resolved.toLowerCase();
      if (low.contains('.m3u8') || low.contains('.mp4')) {
        out.add(
          StreamQuality(
            width: 1280,
            height: low.contains('m3u8') ? 720 : 480,
            url: resolved,
          ),
        );
      }
    }
    return out;
  }

  List<StreamQuality> _extractBestJav(String html, String base) {
    final out = <StreamQuality>[];
    // Hover previews are short — skip data-mediabook unless nothing else
    for (final m in RegExp(
      r'''["'](https?://[^"']+\.(?:m3u8|mp4)[^"']*)["']''',
      caseSensitive: false,
    ).allMatches(html)) {
      final u = m.group(1)!;
      if (_isPreviewUrl(u)) continue;
      out.add(
        StreamQuality(
          width: 1280,
          height: u.contains('m3u8') ? 720 : 480,
          url: u,
        ),
      );
    }
    // source tags
    out.addAll(_extractStreams(html, base));
    if (out.isEmpty) {
      // last resort: mediabook previews (may be short)
      for (final m in RegExp(
        r'''data-mediabook=["'](https?://[^"']+)["']''',
        caseSensitive: false,
      ).allMatches(html)) {
        out.add(StreamQuality(width: 640, height: 360, url: m.group(1)!));
      }
    }
    return _filterPreviewStreams(out);
  }

  bool _isPreviewUrl(String url) {
    final low = url.toLowerCase();
    if (low.contains('trailer')) return true;
    if (low.contains('preview')) return true;
    if (low.contains('thumb')) return true;
    if (low.contains('sample') && !low.contains('m3u8')) return true;
    if (low.contains('mediabook')) return true;
    if (low.contains('static.eporner.com/na.mp4')) return true;
    if (RegExp(r'''/(?:na|unavailable|not[-_]?found)\.mp4(?:[?#/]|$)''')
        .hasMatch(low)) {
      return true;
    }
    if (low.contains('/preview.')) return true;
    // MindGeek 9s teaser segments often under get_media with very short tokens
    if (RegExp(r'[_-](9|10|15)s[_.-]').hasMatch(low)) return true;
    return false;
  }

  List<StreamQuality> _filterPreviewStreams(List<StreamQuality> input) {
    final seen = <String>{};
    final full = <StreamQuality>[];
    for (final s in input) {
      if (s.url.isEmpty || !seen.add(s.url)) continue;
      if (!_isPreviewUrl(s.url)) full.add(s);
    }
    return full;
  }

  /// Custom user URL: treat host as one-off site.
  Future<List<VideoItem>> fetchCustomHost(
    String baseUrl, {
    int limit = 40,
    Set<String>? exclude,
  }) async {
    final base = baseUrl.replaceAll(RegExp(r'/$'), '');
    final host = Uri.tryParse(base)?.host ?? base;
    final fake = SiteDef(
      id: 'custom_$host',
      name: host,
      kind: SiteKind.video,
      color: 0xFF607D8B,
      letter: host.isNotEmpty ? host[0].toUpperCase() : '?',
      mirrors: [base],
      tags: const [],
      ready: true,
    );
    return fetchFeed(fake, limit: limit, exclude: exclude);
  }

  Future<VideoDetail> getCustomDetail(String pageUrl) async {
    final origin = _originOf(pageUrl) ?? pageUrl;
    final host = Uri.tryParse(origin)?.host ?? 'custom';
    final fake = SiteDef(
      id: 'custom_$host',
      name: host,
      kind: SiteKind.video,
      color: 0xFF607D8B,
      letter: 'C',
      mirrors: [origin],
      tags: const [],
      ready: true,
    );
    return getVideoDetail(fake, pageUrl);
  }

  String? _originOf(String url) {
    final u = Uri.tryParse(url);
    if (u == null || u.host.isEmpty) return null;
    return u.origin;
  }

  List<String Function(String base)> _listPaths(
    SiteDef site,
    String tagId,
    int page,
  ) {
    final id = site.parserId ?? site.id;
    final p = page < 1 ? 1 : page;
    // Site-specific first paths
    switch (id) {
      case 'xnxx':
        return [
          if (tagId == 'new') (b) => '$b/search/new/$p',
          if (tagId == 'asian') (b) => '$b/?k=asian&p=$p',
          if (tagId == 'best') (b) => '$b/best/$p',
          if (tagId == 'hot') (b) => '$b/hits/$p',
          (b) => '$b/search/hot/$p',
        ];
      case 'xhamster':
        return [
          if (tagId == 'new') (b) => '$b/newest/$p',
          if (tagId == 'asian') (b) => '$b/categories/asian/$p',
          if (tagId == 'best') (b) => '$b/best/$p',
          if (tagId == 'hot') (b) => '$b/hottest/$p',
          (b) => '$b/?page=$p',
        ];
      case 'eporner':
        return [
          if (tagId == 'new') (b) => '$b/recent/$p/',
          if (tagId == 'asian') (b) => '$b/cat/asian/$p/',
          if (tagId == 'best') (b) => '$b/top-rated/$p/',
          if (tagId == 'hot') (b) => '$b/best-videos/$p/',
          (b) => '$b/popular-videos/$p/',
          (b) => '$b/',
        ];
      case 'jable':
        return [
          if (tagId == 'new') (b) => '$b/latest-updates/$p/',
          if (tagId == 'asian') (b) => '$b/categories/chinese-subtitle/$p/',
          if (tagId == 'best') (b) => '$b/hot/$p/',
          if (tagId == 'hot') (b) => '$b/categories/hot/$p/',
          (b) => '$b/latest-updates/$p/',
          (b) => '$b/new-release/$p/',
          (b) => '$b/',
        ];
      case 'missav':
        return [
          if (tagId == 'new') (b) => '$b/dm22/new?page=$p',
          if (tagId == 'asian') (b) => '$b/dm247/cn?page=$p',
          if (tagId == 'best') (b) => '$b/dm13/release?page=$p',
          if (tagId == 'hot') (b) => '$b/en?page=$p',
          (b) => '$b/dm22/new?page=$p',
          (b) => '$b/dm1/release?page=$p',
          (b) => '$b/en/release?page=$p',
          (b) => '$b/',
        ];
      case 'javgg':
        return [
          if (tagId == 'new' || tagId == 'hot')
            (b) => '$b/latest-updates/${p > 1 ? '$p/' : ''}',
          if (tagId == 'asian')
            (b) => '$b/categories/asian/${p > 1 ? '$p/' : ''}',
          if (tagId == 'best') (b) => '$b/most-popular/${p > 1 ? '$p/' : ''}',
          (b) => '$b/latest-updates/${p > 1 ? '$p/' : ''}',
          if (p == 1) (b) => '$b/',
          (b) => '$b/page/$p/',
        ];
      case 'javmix':
        return [
          if (tagId == 'new') (b) => '$b/latest-updates/${p > 1 ? '$p/' : ''}',
          if (tagId == 'asian')
            (b) => '$b/categories/asian/${p > 1 ? '$p/' : ''}',
          if (tagId == 'best') (b) => '$b/top-rated/${p > 1 ? '$p/' : ''}',
          if (tagId == 'hot') (b) => '$b/most-popular/${p > 1 ? '$p/' : ''}',
        ];
      case '7mmtv':
        return [
          if (tagId == 'new') (b) => '$b/zh/chinese_list/all/$p.html',
          if (tagId == 'asian') (b) => '$b/zh/censored_list/all/$p.html',
          if (tagId == 'best') (b) => '$b/zh/chinese_list/all/$p.html',
          if (tagId == 'hot') (b) => '$b/zh/uncensored_list/all/$p.html',
          (b) => '$b/zh/chinese_list/all/$p.html',
          (b) => '$b/zh/new_list/all/$p.html',
          (b) => '$b/zh/amateurjav_list/all/$p.html',
          (b) => '$b/zh?page=$p',
        ];
      case 'bestjavporn':
        return [
          if (p == 1) (b) => '$b/',
          if (tagId == 'new') (b) => '$b/new/page/$p/',
          if (tagId == 'asian') (b) => '$b/censored/page/$p/',
          if (tagId == 'best') (b) => '$b/best/page/$p/',
          if (tagId == 'hot') (b) => '$b/page/$p/',
          (b) => '$b/zh/page/$p/',
          (b) => '$b/page/$p/',
        ];
      case 'av01':
        return [
          if (tagId == 'new')
            (b) => '$b/api/v1/videos?page=$p&limit=40&sort=new',
          if (tagId == 'asian')
            (b) => '$b/api/v1/videos?page=$p&limit=40&category=jp',
          if (tagId == 'best')
            (b) => '$b/api/v1/videos?page=$p&limit=40&sort=rating',
          if (tagId == 'hot')
            (b) => '$b/api/v1/videos?page=$p&limit=40&sort=hot',
          (b) => '$b/api/v1/videos?page=$p&limit=40',
          (b) => '$b/api/videos?page=$p&limit=40',
          (b) => '$b/jp?page=$p',
          (b) => '$b/',
        ];
      case 'redtube':
        return [
          if (tagId == 'new') (b) => '$b/?page=$p&ordering=newest',
          if (tagId == 'asian') (b) => '$b/?search=asian&page=$p',
          if (tagId == 'best') (b) => '$b/most-favorited/?page=$p',
          if (tagId == 'hot') (b) => '$b/?page=$p',
          (b) => '$b/?page=$p',
          (b) => '$b/',
        ];
      case 'youporn':
        return [
          if (tagId == 'new') (b) => '$b/browse/time/?page=$p',
          if (tagId == 'asian') (b) => '$b/category/asian/?page=$p',
          if (tagId == 'best') (b) => '$b/browse/rating/?page=$p',
          if (tagId == 'hot') (b) => '$b/?page=$p',
          (b) => '$b/popular/?page=$p',
          (b) => '$b/',
        ];
      case 'spankbang':
        return [
          if (tagId == 'new') (b) => '$b/new_videos/$p/',
          if (tagId == 'asian') (b) => '$b/s/asian/$p/',
          if (tagId == 'best') (b) => '$b/trending_videos/$p/',
          if (tagId == 'hot') (b) => '$b/trending_videos/$p/',
          (b) => '$b/new_videos/$p/',
          (b) => '$b/',
        ];
      case 'freeporn':
        // Directory of outbound tube links — scrape those as playable entries.
        return [
          (b) => '$b/',
          if (tagId == 'new') (b) => '$b/videos?sort=new&page=$p',
          if (tagId == 'asian') (b) => '$b/search/asian?page=$p',
          if (tagId == 'best') (b) => '$b/videos?sort=rating&page=$p',
          if (tagId == 'hot') (b) => '$b/videos?sort=popular&page=$p',
          (b) => '$b/videos?page=$p',
        ];
      case 'tnaflix':
        return [
          if (tagId == 'new') (b) => '$b/new/?page=$p',
          if (tagId == 'asian') (b) => '$b/search.php?what=asian&page=$p',
          if (tagId == 'best') (b) => '$b/toprated/?page=$p',
          if (tagId == 'hot') (b) => '$b/?page=$p',
          (b) => '$b/popular/?page=$p',
          (b) => '$b/',
        ];
      case 'our55':
      case 'xqq88':
        // Hash-path CMS: /video/{md5}.html list cards; category via /type/{md5}.html
        // Stable category hashes from live homepage (Our55 / 88XQQ family).
        final typeHot = id == 'xqq88'
            ? '2d2ad6019f04f0babc490e1d7e5407b0'
            : '6ab222795552b5f2a80d08e054eb6eb2'; // 主播网红 / default hot
        final typeAsian = id == 'xqq88'
            ? '33aa1830f9e40d2da6188b4f089426e4'
            : 'e2d833626ebb2fcc1f34b4b768ba75ac'; // 中文字幕
        final typeNew = id == 'xqq88'
            ? '4038d7e28ac4296f5563e130a16570b4'
            : '05e63492cd2898bd6fa1c7cf36d5cd8a'; // 国产厂牌
        final typeBest = id == 'xqq88'
            ? '076fdd6d986ec12bb88d5128c5353fff'
            : 'efc9a244d59a9d510b84644f2fa79b88'; // 日本无码
        final typeId = switch (tagId) {
          'asian' => typeAsian,
          'new' => typeNew,
          'best' => typeBest,
          _ => typeHot,
        };
        return [
          if (p == 1) (b) => '$b/',
          (b) => '$b/type/$typeId.html${p > 1 ? '?page=$p' : ''}',
          (b) => '$b/?page=$p',
        ];
      case 'stripchat':
        final primaryTag = tagId == 'couples' ? tagId : 'girls';
        final sortBy = tagId == 'new' ? 'newModels' : 'stripRanking';
        final offset = (p - 1) * 60 + (tagId == 'more' ? 60 : 0);
        return [
          (b) =>
              '$b/api/front/models?limit=60&offset=$offset&primaryTag=$primaryTag&sortBy=$sortBy',
        ];
      case 'chaturbate':
        final categoryQuery = switch (tagId) {
          'couples' => '&genders=c',
          'new' => '&genders=f&sort_order=new',
          'asian' => '&genders=f&tags=asian',
          'outdoor' => '&genders=f&tags=outdoors',
          'hd' => '&genders=f&tags=hd',
          _ => '&genders=f',
        };
        return [
          (b) =>
              '$b/api/ts/roomlist/room-list/?limit=90&offset=${(p - 1) * 90}$categoryQuery',
        ];
      default:
        return [
          (b) => '$b/videos?page=$p&sort=$tagId',
          (b) => '$b/?page=$p&sort=$tagId',
        ];
    }
  }

  List<String Function(String base)> _searchPaths(
    SiteDef site,
    String enc,
    int page,
  ) {
    final p = page < 1 ? 1 : page;
    switch (site.parserId ?? site.id) {
      case 'xnxx':
        return [
          (b) => '$b/search/$enc${p > 1 ? '/$p' : ''}',
          (b) => '$b/?k=$enc',
        ];
      case 'xhamster':
        return [(b) => '$b/search/$enc${p > 1 ? '?page=$p' : ''}'];
      case 'eporner':
        return [(b) => '$b/search/$enc/${p > 1 ? '$p/' : ''}'];
      case 'freeporn':
        return [
          (b) => '$b/search/$enc?page=$p',
          (b) => '$b/videos?search=$enc&page=$p',
        ];
      case 'spankbang':
        return [(b) => '$b/s/$enc/${p > 1 ? '$p/' : ''}'];
      case 'jable':
        return [(b) => '$b/search/$enc/${p > 1 ? '$p/' : ''}'];
      case 'missav':
        return [(b) => '$b/search/$enc?page=$p'];
      case 'youporn':
        return [(b) => '$b/search/?query=$enc&page=$p'];
      case 'redtube':
        return [(b) => '$b/?search=$enc&page=$p'];
      case 'tnaflix':
        return [
          (b) => '$b/search?what=$enc&page=$p',
          (b) => '$b/search/$enc/$p',
        ];
      case 'javmix':
      case 'javgg':
      case 'bestjavporn':
        return [(b) => '$b/page/$p/?s=$enc', (b) => '$b/?s=$enc&paged=$p'];
      case 'av01':
        return [
          (b) => '$b/api/v1/videos/search?q=$enc&page=$p&limit=40',
          (b) => '$b/search?q=$enc&page=$p',
        ];
      case '7mmtv':
        return [
          (b) => '$b/zh/search?q=$enc&page=$p',
          (b) => '$b/zh/search/$enc/$p.html',
        ];
      case 'our55':
      case 'xqq88':
        return [
          (b) => '$b/search.html?wd=$enc${p > 1 ? '&page=$p' : ''}',
          (b) => '$b/search/?wd=$enc&page=$p',
          (b) => '$b/?wd=$enc&page=$p',
        ];
      default:
        return [
          (b) => '$b/search?q=$enc&page=$p',
          (b) => '$b/search/$enc',
          (b) => '$b/?s=$enc',
          (b) => '$b/search.html?wd=$enc',
        ];
    }
  }

  List<VideoItem> _parseLiveJson(
      String raw, String base, Set<String> seen, SiteDef site,
      {String? tagId}) {
    final out = <VideoItem>[];
    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return out;
    }

    String? stringValue(Map<String, dynamic> map, List<String> keys) {
      for (final key in keys) {
        final value = map[key];
        if (value is String && value.trim().isNotEmpty) return value.trim();
      }
      return null;
    }

    String? nestedStringValue(dynamic value) {
      if (value is String && value.trim().isNotEmpty) return value.trim();
      if (value is Map) {
        final map = Map<String, dynamic>.from(value);
        for (final nestedKey in const [
          'src',
          'url',
          'href',
          'path',
          'image',
          'thumb',
          'thumbnail',
        ]) {
          final nested = nestedStringValue(map[nestedKey]);
          if (nested != null && nested.isNotEmpty) return nested;
        }
        for (final nestedValue in map.values) {
          final nested = nestedStringValue(nestedValue);
          if (nested != null && nested.isNotEmpty) return nested;
        }
      } else if (value is List) {
        for (final nestedValue in value) {
          final nested = nestedStringValue(nestedValue);
          if (nested != null && nested.isNotEmpty) return nested;
        }
      }
      return null;
    }

    String? firstNestedString(Map<String, dynamic> map, List<String> keys) {
      for (final key in keys) {
        final value = nestedStringValue(map[key]);
        if (value != null && value.isNotEmpty) return value;
      }
      return null;
    }

    bool falseValue(dynamic value) =>
        value == false || value == 0 || value == '0' || value == 'false';

    bool trueValue(dynamic value) =>
        value == true || value == 1 || value == '1' || value == 'true';

    String categoryText(Map<String, dynamic> map) {
      final values = <String>[];
      void collect(dynamic value) {
        if (value is String || value is num || value is bool) {
          values.add('$value');
        } else if (value is List) {
          for (final entry in value) {
            collect(entry);
          }
        } else if (value is Map) {
          for (final entry in value.values) {
            collect(entry);
          }
        }
      }

      for (final key in const [
        'tags',
        'tag_list',
        'room_tags',
        'roomTags',
        'categories',
        'category',
        'room_subject',
        'location',
        'country',
        'ethnicity',
      ]) {
        collect(map[key]);
      }
      return values.join(' ').toLowerCase();
    }

    bool matchesChaturbateCategory(Map<String, dynamic> map) {
      if (!site.isChaturbate) return true;
      final requested = tagId ?? 'female';
      final gender = (map['gender'] ?? map['broadcast_gender'] ?? '')
          .toString()
          .toLowerCase();
      if (requested == 'couples') {
        // Do not accept an unclassified room here. Some endpoints silently
        // ignore category parameters; accepting an empty gender would then
        // duplicate the female tab into the couples tab.
        return gender == 'c' ||
            gender.contains('couple') ||
            gender.contains('pair');
      }
      if (requested == 'male') {
        return gender == 'm' || gender == 'male';
      }
      if (requested == 'trans') {
        return gender == 't' || gender.contains('trans');
      }
      if (gender == 'm' ||
          gender == 't' ||
          gender == 'male' ||
          gender.contains('trans') ||
          gender.contains('couple')) {
        return false;
      }
      if (requested == 'new') {
        final secondsOnline = int.tryParse(
              (map['seconds_online'] ?? map['secondsOnline'] ?? '').toString(),
            ) ??
            0;
        return trueValue(map['is_new'] ?? map['isNew'] ?? map['new_model']) ||
            (secondsOnline > 0 && secondsOnline <= 7200) ||
            categoryText(map).contains('new');
      }
      if (requested == 'asian') {
        final text = categoryText(map);
        return text.contains('asian') ||
            text.contains('japanese') ||
            text.contains('korean') ||
            text.contains('chinese');
      }
      if (requested == 'outdoor') {
        final text = categoryText(map);
        return text.contains('outdoor') ||
            text.contains('outdoors') ||
            text.contains('outside') ||
            text.contains('nature') ||
            text.contains('public');
      }
      if (requested == 'hd') {
        final text = categoryText(map);
        return text.contains('hd') ||
            text.contains('high definition') ||
            text.contains('high-definition') ||
            text.contains('1080') ||
            text.contains('720') ||
            trueValue(map['is_hd'] ?? map['isHd'] ?? map['hd']);
      }
      if (requested != 'female' && requested != 'popular') {
        return categoryText(map).contains(requested);
      }
      return true;
    }

    void visit(dynamic node) {
      if (out.length >= 80) return;
      if (node is List) {
        for (final child in node) {
          visit(child);
          if (out.length >= 80) break;
        }
        return;
      }
      if (node is! Map) return;
      final map = Map<String, dynamic>.from(node);
      var username = stringValue(map, const [
        'username',
        'user__username',
        'login',
        'modelName',
      ]);
      final hasModelSignal = map.keys.any(const {
        'current_show',
        'room_status',
        'status',
        'gender',
        'image',
        'image_url',
        'image_url_360x270',
        'previewUrlThumbSmall',
        'avatarUrl',
      }.contains);
      if (username == null && hasModelSignal) {
        username = stringValue(map, const ['room', 'slug']);
      }

      if (username != null &&
          RegExp(r'^[a-zA-Z0-9_-]{3,60}$').hasMatch(username)) {
        if (!matchesChaturbateCategory(map)) return;
        final online = map['is_online'] ?? map['isOnline'] ?? map['online'];
        final status = (stringValue(map, const [
                  'current_show',
                  'room_status',
                  'showStatus',
                  'status',
                ]) ??
                '')
            .toLowerCase();
        const blockedStatuses = [
          'offline',
          'private',
          'away',
          'hidden',
          'password',
          'group',
          'spy',
          'closed',
        ];
        final blocked = falseValue(online) ||
            blockedStatuses.any((value) => status.contains(value));
        final stripchatOnline = site.id != 'stripchat' ||
            online == true ||
            online == 1 ||
            online == '1' ||
            online == 'true';
        if (!blocked && stripchatOnline) {
          final key = username.toLowerCase();
          final streamValue = site.isStripchat
              ? stringValue(map, const [
                  'streamName',
                  'stream_name',
                  'hlsStreamName',
                ])
              : stringValue(map, const [
                  'hlsPlaylist',
                  'hlsStreamUrl',
                  'hls_source',
                  'hlsSource',
                  'streamName',
                  'stream_name',
                  'hlsStreamName',
                ]);
          if (streamValue != null) {
            _liveStreamNames['${site.id}:$key'] = streamValue;
          }
          if (seen.add(key)) {
            final thumb = firstNestedString(map, const [
                  'default_thumb',
                  'defaultThumb',
                  'image_url_360x270',
                  'imageUrl360x270',
                  'previewUrlThumbSmall',
                  'preview_url_thumb_small',
                  'preview_url',
                  'previewUrl',
                  'preview',
                  'image_url_720x540',
                  'imageUrl720x540',
                  'image_url_180x135',
                  'imageUrl180x135',
                  'image_url',
                  'imageUrl',
                  'snapshotUrl',
                  'snapshot_url',
                  'thumbnail_url',
                  'thumbnailUrl',
                  'thumbnail',
                  'thumb',
                  'thumb_url',
                  'thumbUrl',
                  'room_img',
                  'roomImg',
                  'profile_image',
                  'profileImage',
                  'avatarUrl',
                  'avatar_url',
                  'image',
                  'img',
                ]);
            final title = stringValue(
                  map,
                  const ['display_name', 'displayName', 'title'],
                ) ??
                username;
            final fallbackThumb = site.isChaturbate
                ? 'https://roomimg.stream.highwebmedia.com/ri/${Uri.encodeComponent(username.toLowerCase())}.jpg'
                : null;
            out.add(
              VideoItem(
                url: '$base/$username',
                title: title,
                duration: 'LIVE',
                thumb: _normalizeLiveThumb(thumb ?? fallbackThumb, base),
              ),
            );
          }
        }
        // A model object can contain room/chat metadata with more name-like
        // fields. Never recurse into it and accidentally create fake rooms.
        return;
      }

      for (final value in map.values) {
        if (value is Map || value is List) visit(value);
      }
    }

    visit(decoded);
    return out;
  }

  String? _normalizeLiveThumb(String? raw, String base) {
    if (raw == null || raw.trim().isEmpty) return null;
    var value = raw.replaceAll(r'\/', '/').trim();
    if (value.startsWith('//')) value = 'https:$value';
    if (!value.startsWith('http')) value = _abs(base, value);
    return value;
  }

  List<VideoItem> _parseList(
    String html,
    String base,
    Set<String> seen,
    SiteDef site,
  ) {
    final out = <VideoItem>[];
    // Collect href candidates that look like video pages
    final hrefRe = RegExp(
      r'''href\s*=\s*["']([^"']+)["']''',
      caseSensitive: false,
    );
    final titleRe = RegExp(
      r'''(?:title|alt)\s*=\s*["']([^"']{3,200})["']''',
      caseSensitive: false,
    );
    final imgRe = RegExp(
      r'''(?:data-src|data-original|data-thumb|data-poster|src)\s*=\s*["']((?:https?:)?//[^"']+\.(?:jpg|jpeg|png|webp|gif)[^"']*|[^"']+/thumb[^"']*|[^"']+/cover[^"']*)["']''',
      caseSensitive: false,
    );

    // Split into rough cards by common wrappers
    var chunks = html.split(
      RegExp(
        r'(?=<div[^>]+class="[^"]*(?:video|thumb|item|card|post|movie|list-item)[^"]*")',
        caseSensitive: false,
      ),
    );
    if (chunks.length < 3) {
      chunks = html.split(RegExp(r'''(?=href=["'][^"']+["'])'''));
    }

    for (var chunkIndex = 0; chunkIndex < chunks.length; chunkIndex++) {
      final chunk = chunks[chunkIndex];
      if (chunk.length < 40 || chunk.length > 12000) continue;
      String? href;
      for (final m in hrefRe.allMatches(chunk)) {
        final h = m.group(1)!;
        if (_looksLikeVideoPath(h, site)) {
          href = h;
          break;
        }
      }
      if (href == null) continue;
      final abs = _abs(base, href);
      final key = abs.split('#').first.split('?').first;
      if (!seen.add(key)) continue;

      String? title;
      final tm = titleRe.firstMatch(chunk);
      if (tm != null) {
        title = _cleanTitle(tm.group(1)!);
      }
      if (title == null || title.length < 2) {
        final aText = RegExp(r'>\s*([^<>]{4,120})\s*<').firstMatch(chunk);
        if (aText != null) title = _cleanTitle(aText.group(1)!);
      }
      if (title == null || title.length < 2) {
        final slug = key.split('/').where((e) => e.isNotEmpty).last;
        title = Uri.decodeComponent(
          slug,
        ).replaceAll(RegExp(r'[-_]+'), ' ').trim();
      }
      if (title.length < 2) continue;
      if (_isJunkTitle(title)) continue;

      var metadataChunk = chunk;
      if (chunkIndex + 1 < chunks.length &&
          !hrefRe.hasMatch(chunks[chunkIndex + 1])) {
        metadataChunk = '$metadataChunk${chunks[chunkIndex + 1]}';
      }
      String? thumb;
      final im = imgRe.firstMatch(metadataChunk);
      if (im != null) {
        thumb = _normalizeThumbUrl(im.group(1), base);
      }
      thumb ??= _extractThumbFromChunk(metadataChunk, base);
      final duration = _extractDurationLabel(metadataChunk);

      out.add(
        VideoItem(
          url: abs,
          title: title,
          duration: duration ?? '-',
          thumb: thumb,
        ),
      );
      if (out.length >= 80) break;
    }
    return out;
  }

  bool _looksLikeVideoPath(String href, SiteDef site) {
    final h = href.toLowerCase();
    if (h.startsWith('javascript:') ||
        h.startsWith('#') ||
        h.startsWith('mailto:') ||
        h.contains('login') ||
        h.contains('signup') ||
        h.contains('register') ||
        h.contains('/tag/') ||
        h.contains('/tags/') ||
        h.contains('/category/') ||
        h.contains('/categories/') ||
        h.contains('/search') ||
        h.contains('/page/') ||
        h.endsWith('.css') ||
        h.endsWith('.js') ||
        h.endsWith('.xml') ||
        h.endsWith('.jpg') ||
        h.endsWith('.png')) {
      return false;
    }

    // Site-specific positive rules
    switch (site.parserId ?? site.id) {
      case 'jable':
        return RegExp(r'/videos?/[^/]+/?').hasMatch(h) ||
            RegExp(r'/[a-z0-9]+-[a-z0-9-]+/?$').hasMatch(h);
      case 'missav':
        return RegExp(r'/[a-z]{2,12}-?\d{2,5}').hasMatch(h) ||
            (RegExp(r'/(dm\d+/)?[a-z0-9-]+/?$').hasMatch(h) &&
                !h.contains('/dm') &&
                h.split('/').where((e) => e.isNotEmpty).isNotEmpty);
      case 'javgg':
      case 'javmix':
      case 'bestjavporn':
        return RegExp(r'/(jav|video|movie|watch)/').hasMatch(h) ||
            RegExp(r'/[a-z]{2,10}-?\d{2,5}').hasMatch(h);
      case '7mmtv':
        return h.contains('/content/') ||
            h.contains('_content/') ||
            h.contains('/cnplay/') ||
            h.contains('/enplay/') ||
            RegExp(r'chinese_content/\d+/').hasMatch(h) ||
            RegExp(r'_\d+\.html').hasMatch(h);
      case 'av01':
        return h.contains('/v/') ||
            h.contains('/video/') ||
            h.contains('/watch/');
      case 'spankbang':
        return RegExp(r'/[a-z0-9-]+/video/').hasMatch(h) ||
            RegExp(r'/\d+/video/').hasMatch(h) ||
            RegExp(r'/[a-z0-9]{4,12}/play/').hasMatch(h);
      case 'youporn':
        return RegExp(r'/watch/').hasMatch(h) ||
            RegExp(r'/video\?id=').hasMatch(h) ||
            RegExp(r'/\d{5,}').hasMatch(h);
      case 'redtube':
        // Paths are often bare numeric IDs: /251932341
        return RegExp(r'^/\d{6,}$').hasMatch(h) ||
            RegExp(r'/watch/').hasMatch(h) ||
            RegExp(r'/video\?id=').hasMatch(h) ||
            RegExp(r'/\d{6,}').hasMatch(h);
      case 'tnaflix':
        return h.contains('/video') ||
            RegExp(r'/[^/]+/\d+').hasMatch(h) ||
            RegExp(r'/view_video').hasMatch(h);
      case 'eporner':
        return h.contains('/video-') ||
            h.contains('/hd-porn/') ||
            h.contains('/embed/');
      case 'freeporn':
        // Directory of external tubes — accept outbound video-site links.
        return h.contains('xvideos.com') ||
            h.contains('xnxx.com') ||
            h.contains('pornhub.com') ||
            h.contains('xhamster.com') ||
            h.contains('redtube.com') ||
            h.contains('youporn.com') ||
            h.contains('spankbang.com') ||
            RegExp(r'/video[s./]').hasMatch(h);
      case 'our55':
      case 'xqq88':
        // /video/{32-hex}.html detail cards
        return RegExp(r'/video/[a-f0-9]{32}\.html').hasMatch(h);
      case 'xhamster':
        return h.contains('/videos/') || RegExp(r'/movies/\d+').hasMatch(h);
      case 'xnxx':
        return RegExp(r'/video-[a-z0-9]+/').hasMatch(h);
      case 'stripchat':
      case 'chaturbate':
        // room username path
        final parts = h.split('/').where((e) => e.isNotEmpty).toList();
        if (parts.length == 1 &&
            RegExp(r'^[a-zA-Z0-9_-]{3,60}$').hasMatch(parts.first)) {
          return true;
        }
        if (h.contains('/in/?') || h.contains('join')) return false;
        return parts.isNotEmpty &&
            ![
              'female-cams',
              'male-cams',
              'couples',
              'tags',
              'accounts',
              'auth',
            ].contains(parts.first);
    }

    // Generic positive patterns
    if (RegExp(r'/video[s./]').hasMatch(h)) return true;
    if (RegExp(r'/v/\d').hasMatch(h)) return true;
    if (RegExp(r'/watch').hasMatch(h)) return true;
    if (RegExp(r'/view_video').hasMatch(h)) return true;
    if (RegExp(r'/embed/').hasMatch(h)) return true;
    if (RegExp(r'/(movies?|clips?)/').hasMatch(h)) return true;
    if (RegExp(r'/\d{4,}/').hasMatch(h) && h.split('/').length >= 3) {
      return true;
    }
    if (RegExp(r'/[a-z]{2,10}-\d{2,5}').hasMatch(h)) return true;
    if (RegExp(r'/(uncensored|censored)/').hasMatch(h)) return true;
    if (site.kind == SiteKind.live) {
      if (RegExp(r'/[^/]{3,40}/?$').hasMatch(h) && !h.contains('.')) {
        return true;
      }
    }
    return false;
  }

  String _cleanTitle(String t) {
    return t
        .replaceAll('&#039;', "'")
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&nbsp;', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  bool _isJunkTitle(String t) {
    final low = t.toLowerCase();
    if (low.length < 2) return true;
    const junk = [
      'login',
      'sign up',
      'register',
      'cookie',
      'privacy',
      'home',
      'next',
      'prev',
      'logo',
      'menu',
      'search',
      'javascript',
    ];
    for (final j in junk) {
      if (low == j) return true;
    }
    return false;
  }

  String? _metaContent(String html, Set<String> names) {
    final tags =
        RegExp(r'<meta\b[^>]*>', caseSensitive: false).allMatches(html);
    for (final tag in tags) {
      final attrs = <String, String>{};
      for (final attr in RegExp(
        r'''([:\w-]+)\s*=\s*["']([^"']*)["']''',
        caseSensitive: false,
      ).allMatches(tag.group(0)!)) {
        attrs[attr.group(1)!.toLowerCase()] = attr.group(2)!;
      }
      final name =
          (attrs['property'] ?? attrs['name'] ?? attrs['itemprop'] ?? '')
              .toLowerCase();
      if (names.contains(name)) {
        final value = attrs['content']?.trim();
        if (value != null && value.isNotEmpty) return value;
      }
    }
    return null;
  }

  String? _extractTitle(String html) {
    final meta = _metaContent(html, {'og:title', 'twitter:title'});
    if (meta != null) return _cleanTitle(meta);
    final t = RegExp(
      r'<title>([^<]+)</title>',
      caseSensitive: false,
    ).firstMatch(html);
    if (t != null) {
      var s = _cleanTitle(t.group(1)!);
      s = s.split(RegExp(r'\s[-|–—]\s')).first.trim();
      if (s.length >= 2) return s;
    }
    return null;
  }

  String? _extractThumb(String html) {
    return _metaContent(html, {
      'og:image',
      'og:image:url',
      'twitter:image',
      'thumbnailurl',
    });
  }

  String? _resolvedThumb(String html, String pageUrl) {
    final thumb = _extractThumb(html);
    return _normalizeThumbUrl(thumb, pageUrl);
  }

  String? _normalizeThumbUrl(String? raw, String base) {
    if (raw == null) return null;
    var thumb = raw.replaceAll(r'\/', '/').trim();
    if (thumb.isEmpty) return null;
    if (thumb.startsWith('//')) thumb = 'https:$thumb';
    if (!thumb.startsWith('http')) thumb = _abs(base, thumb);
    final low = thumb.toLowerCase();
    if (low.startsWith('data:image/') ||
        low.contains('cover-placeholder') ||
        low.contains('placeholder') ||
        low.contains('blank') ||
        low.contains('spacer') ||
        low.contains('pixel') ||
        low.contains('default') ||
        low.contains('loading') ||
        low.contains('sprite') ||
        low.contains('noimage')) {
      return null;
    }
    return thumb;
  }

  String? _extractThumbFromChunk(String chunk, String base) {
    final candidates = <RegExp>[
      RegExp(
        r'''(?:data-src|data-original|data-thumb|data-poster|data-lazy-src|data-image|src|poster)\s*=\s*["']([^"']+)["']''',
        caseSensitive: false,
      ),
      RegExp(
        r'''(?:data-srcset|srcset)\s*=\s*["']([^"']+)["']''',
        caseSensitive: false,
      ),
      RegExp(
        r'''style\s*=\s*["'][^"']*background(?:-image)?\s*:\s*url\((?:'|")?([^"')]+)(?:'|")?\)[^"']*["']''',
        caseSensitive: false,
      ),
    ];
    for (final pattern in candidates) {
      final match = pattern.firstMatch(chunk);
      if (match == null) continue;
      var raw = match.group(1)!.replaceAll(r'\/', '/').trim();
      if (pattern.pattern.contains('srcset')) {
        raw = raw.split(',').first.trim().split(' ').first.trim();
      }
      var thumb = _normalizeThumbUrl(raw, base);
      if (thumb == null) continue;
      final low = thumb.toLowerCase();
      if (RegExp(r'\.(?:jpg|jpeg|png|webp|gif)(?:[?#]|$)').hasMatch(low) ||
          low.contains('thumb') ||
          low.contains('thumbnail') ||
          low.contains('cover') ||
          low.contains('poster') ||
          low.contains('preview') ||
          low.contains('image') ||
          low.contains('photo') ||
          low.contains('img')) {
        return thumb;
      }
    }
    return null;
  }

  String? _extractDurationLabel(String html) {
    final raw = _durationSecondsFromText(html);
    if (raw != null && raw > 0) return _formatDurationLabel(raw);
    final attr = RegExp(
      r'''(?:data-|aria-)?(?:duration|length|time)\s*=\s*["']([^"']+)["']''',
      caseSensitive: false,
    ).firstMatch(html)?.group(1);
    if (attr != null) {
      final label = _normalizeDurationLabel(attr);
      if (label != null) return label;
    }
    final explicit = RegExp(
      r'''(?<!\d)(\d{1,2}:\d{2}(?::\d{2})?)(?!\d)''',
    ).firstMatch(html)?.group(1);
    if (explicit != null) return explicit;
    return null;
  }

  String? _normalizeDurationLabel(String raw) {
    final seconds = _durationSecondsFromText(raw);
    if (seconds != null && seconds > 0) return _formatDurationLabel(seconds);
    final label = raw
        .replaceAll('&nbsp;', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (RegExp(r'^\d{1,2}:\d{2}(?::\d{2})?$').hasMatch(label)) return label;
    return null;
  }

  int? _durationSecondsFromText(String raw) {
    final text = raw
        .replaceAll(r'\/', '/')
        .replaceAll('&amp;', '&')
        .replaceAll('&nbsp;', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .toLowerCase()
        .trim();
    if (text.isEmpty) return null;

    final hms = RegExp(r'(?<!\d)(\d{1,2}):([0-5]\d):([0-5]\d)(?!\d)')
        .firstMatch(text);
    if (hms != null) {
      final hours = int.tryParse(hms.group(1) ?? '') ?? 0;
      final minutes = int.tryParse(hms.group(2) ?? '') ?? 0;
      final seconds = int.tryParse(hms.group(3) ?? '') ?? 0;
      return hours * 3600 + minutes * 60 + seconds;
    }

    final ms = RegExp(r'(?<!\d)(\d{1,3}):([0-5]\d)(?!\d)').firstMatch(text);
    if (ms != null) {
      final minutes = int.tryParse(ms.group(1) ?? '') ?? 0;
      final seconds = int.tryParse(ms.group(2) ?? '') ?? 0;
      return minutes * 60 + seconds;
    }

    final hMin = RegExp(
      r'(?<!\d)(\d+(?:\.\d+)?)\s*(?:h|hr|hrs|hour|hours)\b(?:\s*(\d+(?:\.\d+)?)\s*(?:m|min|mins|minute|minutes)\b)?',
    ).firstMatch(text);
    if (hMin != null) {
      final hours = double.tryParse(hMin.group(1) ?? '') ?? 0;
      final minutes = double.tryParse(hMin.group(2) ?? '') ?? 0;
      return (hours * 3600 + minutes * 60).round();
    }

    final minOnly = RegExp(
      r'(?<!\d)(\d+(?:\.\d+)?)\s*(?:m|min|mins|minute|minutes)\b',
    ).firstMatch(text);
    if (minOnly != null) {
      final minutes = double.tryParse(minOnly.group(1) ?? '') ?? 0;
      return (minutes * 60).round();
    }

    final secOnly = RegExp(
      r'(?<!\d)(\d+(?:\.\d+)?)\s*(?:s|sec|secs|second|seconds)\b',
    ).firstMatch(text);
    if (secOnly != null) {
      final seconds = double.tryParse(secOnly.group(1) ?? '') ?? 0;
      return seconds.round();
    }

    return null;
  }

  String _formatDurationLabel(int seconds) {
    final safe = seconds < 0 ? 0 : seconds;
    final hours = safe ~/ 3600;
    final minutes = (safe % 3600) ~/ 60;
    final secs = safe % 60;
    if (hours > 0) {
      return '${hours.toString()}:${minutes.toString().padLeft(2, '0')}:'
          '${secs.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString()}:${secs.toString().padLeft(2, '0')}';
  }

  List<StreamQuality> _extractStreams(String html, String base) {
    final streams = <StreamQuality>[];
    final seen = <String>{};

    void add(String? u, {int w = 0, int h = 0}) {
      if (u == null || u.isEmpty) return;
      var url = u
          .replaceAll(r'\/', '/')
          .replaceAll(r'\u002F', '/')
          .replaceAll(r'\u002f', '/')
          .replaceAll(r'\u003A', ':')
          .replaceAll(r'\u003a', ':')
          .replaceAll(r'\u0026', '&')
          .replaceAll('&amp;', '&')
          .trim();
      if (url.startsWith('//')) url = 'https:$url';
      if (!url.startsWith('http')) url = _abs(base, url);
      // Skip obvious non-media / short teasers
      final low = url.toLowerCase();
      if (low.contains('.js') ||
          low.contains('.css') ||
          low.contains('favicon') ||
          RegExp(r'\.(?:jpg|jpeg|png|gif|webp|svg)(?:[?#]|$)').hasMatch(low) ||
          low.contains('trailer') ||
          low.contains('/preview') ||
          low.contains('mediabook') ||
          RegExp(r'[_-](9|10|15)s[_.-]').hasMatch(low)) {
        return;
      }
      if (!seen.add(url)) return;
      if (h <= 0) {
        final hm = RegExp(r'(\d{3,4})p').firstMatch(url);
        if (hm != null) h = int.tryParse(hm.group(1)!) ?? 0;
      }
      if (h <= 0) {
        if (low.contains('.m3u8')) {
          h = 720;
        } else if (low.contains('.mp4')) {
          h = 480;
        } else {
          h = 720;
        }
      }
      if (w <= 0) w = (h * 16 / 9).round();
      streams.add(StreamQuality(width: w, height: h, url: url));
    }

    // HLS absolute
    for (final m in RegExp(
      r'''["'](https?:\\?/\\?/[^"'\s]+\.m3u8[^"'\s]*)["']''',
      caseSensitive: false,
    ).allMatches(html)) {
      add(m.group(1)?.replaceAll(r'\/', '/'), h: 720);
    }
    // HLS relative / escaped
    for (final m in RegExp(
      r'''["']([^"'\s]+\.m3u8[^"'\s]*)["']''',
      caseSensitive: false,
    ).allMatches(html)) {
      final u = m.group(1);
      if (u != null && !u.startsWith('data:')) add(u, h: 720);
    }
    // m3u8 without quotes nearby (packed)
    for (final m in RegExp(
      r'(https?:\\?/\\?/[^\s"'
      '<>]+\\.m3u8[^\\s"'
      '<>]*)',
      caseSensitive: false,
    ).allMatches(html)) {
      add(m.group(1)?.replaceAll(r'\/', '/'), h: 720);
    }

    // mp4
    for (final m in RegExp(
      r'''["'](https?:[^"']+\.mp4[^"']*)["']''',
      caseSensitive: false,
    ).allMatches(html)) {
      add(m.group(1), h: 480);
    }

    // og:video
    add(
      _metaContent(html, {'og:video', 'og:video:url', 'twitter:player:stream'}),
      h: 720,
    );

    for (final m in RegExp(
      r'''<source[^>]+(?:src|data-src|data-lazy-src)=["']([^"']+)["']''',
      caseSensitive: false,
    ).allMatches(html)) {
      add(m.group(1), h: 480);
    }
    for (final m in RegExp(
      r'''<video[^>]+src=["']([^"']+)["']''',
      caseSensitive: false,
    ).allMatches(html)) {
      add(m.group(1), h: 480);
    }

    // XVideos-style helpers
    final hls = RegExp(r"setVideoHLS\('([^']+)'\)").firstMatch(html) ??
        RegExp(r'setVideoHLS\("([^"]+)"\)').firstMatch(html);
    if (hls != null) add(hls.group(1), h: 720);
    final high = RegExp(r"setVideoUrlHigh\('([^']+)'\)").firstMatch(html);
    if (high != null) add(high.group(1), h: 480);
    final low = RegExp(r"setVideoUrlLow\('([^']+)'\)").firstMatch(html);
    if (low != null) add(low.group(1), h: 240);

    // JSON-LD / common keys
    for (final m in RegExp(r'"contentUrl"\s*:\s*"([^"]+)"').allMatches(html)) {
      add(m.group(1), h: 720);
    }
    for (final m in RegExp(
      r'''["'](?:file|videoUrl|video_url|stream|streamUrl|playUrl|hls|hlsUrl|hls_url|m3u8)["']\s*:\s*["']([^"']+)["']''',
      caseSensitive: false,
    ).allMatches(html)) {
      add(m.group(1), h: 720);
    }
    for (final m in RegExp(
      r'''["'](\d{3,4})p?["']\s*:\s*["'](https?[^"']+)["']''',
    ).allMatches(html)) {
      final hh = int.tryParse(m.group(1)!) ?? 0;
      add(m.group(2), h: hh > 0 ? hh : 720);
    }

    // MacCMS / Chinese portals: accept direct media only. Parser endpoints are
    // resolved asynchronously by _resolveMacCmsPlayer.
    final blob = _macCmsPlayerBlob(html);
    if (blob != null) {
      final um = RegExp(
        r'''["']url["']\s*:\s*["']([^"']+)["']''',
      ).firstMatch(blob);
      if (um != null) {
        final encrypt = int.tryParse(
              RegExp(
                    r'''["']encrypt["']\s*:\s*["']?(\d+)''',
                  ).firstMatch(blob)?.group(1) ??
                  '',
            ) ??
            0;
        final u = _decodeMacCmsUrl(um.group(1)!, encrypt);
        if (_looksLikeMediaUrl(u)) add(u, h: 720);
      }
    }
    final urlM = RegExp(
      r'''["']url["']\s*:\s*["'](https?[^"']+\.(?:m3u8|mp4)[^"']*)["']''',
      caseSensitive: false,
    ).firstMatch(html);
    if (urlM != null) add(urlM.group(1), h: 720);

    return streams;
  }

  /// Broader second-pass for packed / unicode-escaped media URLs.
  List<StreamQuality> _extractStreamsLoose(String html, String base) {
    final decoded = html
        .replaceAll(r'\/', '/')
        .replaceAll(r'\u002F', '/')
        .replaceAll(r'\u002f', '/')
        .replaceAll(r'\u003A', ':')
        .replaceAll(r'\u003a', ':')
        .replaceAll(r'\u0026', '&')
        .replaceAll(r'\x2F', '/')
        .replaceAll(r'\x2f', '/')
        .replaceAll('&quot;', '"')
        .replaceAll('&#34;', '"')
        .replaceAll('&#x22;', '"')
        .replaceAll('&amp;', '&');
    return _extractStreams(decoded, base);
  }

  Future<List<StreamQuality>> _extractLiveStreams(
    SiteDef site,
    String pageUrl,
    String html,
    String base,
  ) async {
    final streams = <StreamQuality>[];
    streams.addAll(_extractStreams(html, base));
    streams.addAll(_extractStreamsLoose(html, base));

    final room = _usernameFromUrl(pageUrl) ?? '';

    // Chaturbate: edge HLS + room Dossier API (live only, not VOD shows)
    if (site.isChaturbate) {
      for (final m in RegExp(
        r'''https?:\\?/\\?/[^\s"'<>]*(?:playlist|live|amic|edge)[^\s"'<>]*\.m3u8[^\s"'<>]*''',
        caseSensitive: false,
      ).allMatches(html)) {
        var u = m.group(0)!.replaceAll(r'\/', '/');
        if (u.startsWith('//')) u = 'https:$u';
        // Skip non-live VOD / sex-show replays when possible
        final low = u.toLowerCase();
        if (low.contains('record') || low.contains('/vod/')) continue;
        streams.add(StreamQuality(width: 1280, height: 720, url: u));
      }
      final hlsSrc = RegExp(
        r'''hls_source["']?\s*[:=]\s*["']([^"']+)["']''',
        caseSensitive: false,
      ).firstMatch(html);
      if (hlsSrc != null) {
        var u = hlsSrc.group(1)!.replaceAll(r'\/', '/');
        if (u.startsWith('//')) u = 'https:$u';
        streams.add(StreamQuality(width: 1280, height: 720, url: u));
      }

      if (room.isNotEmpty) {
        final apis = [
          '$base/api/chatvideocontext/$room/',
          '$base/$room/',
          'https://chaturbate.com/api/chatvideocontext/$room/',
        ];
        for (final api in apis) {
          try {
            final raw = await _getHtml(
              api,
              headers: {
                ...AppHttpHeaders.forSite(base),
                'Referer': pageUrl,
                'Accept': 'application/json,text/html,*/*',
                'X-Requested-With': 'XMLHttpRequest',
              },
            );
            for (final m in RegExp(
              r'''https?:\\?/\\?/[^\s"'<>]+\.m3u8[^\s"'<>]*''',
              caseSensitive: false,
            ).allMatches(raw)) {
              var u = m.group(0)!.replaceAll(r'\/', '/');
              streams.add(StreamQuality(width: 1280, height: 720, url: u));
            }
            final hs = RegExp(
              r'''hls_source["']?\s*[:=]\s*["']([^"']+)["']''',
              caseSensitive: false,
            ).firstMatch(raw);
            if (hs != null) {
              var u = hs.group(1)!.replaceAll(r'\/', '/');
              if (u.startsWith('//')) u = 'https:$u';
              streams.add(StreamQuality(width: 1280, height: 720, url: u));
            }
            if (streams.isNotEmpty) break;
          } catch (e) {
            if (e is DioException && CancelToken.isCancel(e)) rethrow;
          }
        }
      }
    }

    // Stripchat / xHamsterLive: doppiocdn HLS by model username
    if (site.isStripchat) {
      // Stripchat embeds 20-second previews beside its live metadata. Keep
      // only the room stream name and derive the rolling live master URL.
      streams.clear();

      void addStripchatStream(String rawValue) {
        final value = rawValue.replaceAll(r'\/', '/');
        final embeddedName = RegExp(
          r'/hls/([^/]+)/',
          caseSensitive: false,
        ).firstMatch(value)?.group(1);
        final name = embeddedName ?? value;
        if (!RegExp(r'^[a-zA-Z0-9_-]{3,100}$').hasMatch(name)) return;
        streams.add(
          StreamQuality(
            width: 1280,
            height: 720,
            url:
                'https://edge-hls.doppiocdn.com/hls/$name/master/${name}_auto.m3u8',
          ),
        );
      }

      for (final m in RegExp(
        r'''https?:\\?/\\?/[^\s"'<>]*\.m3u8[^\s"'<>]*''',
        caseSensitive: false,
      ).allMatches(html)) {
        addStripchatStream(m.group(0)!);
      }
      // streamName in initial state
      final sn = RegExp(
        r'''["'](?:streamName|stream_name|hlsStreamName)["']\s*:\s*["']([^"']+)["']''',
        caseSensitive: false,
      ).firstMatch(html);
      if (sn != null) {
        addStripchatStream(sn.group(1)!);
      }

      // model view API
      if (room.isNotEmpty) {
        try {
          final raw = await _getHtml(
            '$base/api/front/v2/models/username/$room/cam',
            headers: {
              ...AppHttpHeaders.forSite(base),
              'Accept': 'application/json',
              'Referer': pageUrl,
            },
          );
          for (final m in RegExp(
            r'''https?:\\?/\\?/[^\s"'<>]+\.m3u8[^\s"'<>]*''',
            caseSensitive: false,
          ).allMatches(raw)) {
            addStripchatStream(m.group(0)!);
          }
          final apiField = RegExp(
            r'''["'](?:streamName|stream_name|hlsStreamName)["']\s*:\s*["']([^"']+)["']''',
            caseSensitive: false,
          ).firstMatch(raw);
          if (apiField != null) {
            addStripchatStream(apiField.group(1)!);
          }
        } catch (e) {
          if (e is DioException && CancelToken.isCancel(e)) rethrow;
        }
      }
    }

    // Dedup + drop obvious non-live VOD if live candidates exist
    final seen = <String>{};
    final live = <StreamQuality>[];
    final other = <StreamQuality>[];
    for (final s in streams) {
      if (!seen.add(s.url)) continue;
      final low = s.url.toLowerCase();
      if (low.contains('.m3u8') &&
          !low.contains('/vod/') &&
          !low.contains('record')) {
        live.add(s);
      } else {
        other.add(s);
      }
    }
    return live.isNotEmpty ? live : other;
  }
}

enum MirrorFailureKind {
  dns,
  timeout,
  forbidden,
  blocked,
  structureChanged,
  network,
  cancelled,
}

class MirrorHealth {
  const MirrorHealth({
    required this.url,
    required this.checkedAt,
    required this.latency,
    this.failure,
    this.detail,
  });

  final String url;
  final DateTime checkedAt;
  final Duration latency;
  final MirrorFailureKind? failure;
  final String? detail;

  bool get isAvailable => failure == null;
}

class _MirrorProbe {
  const _MirrorProbe({required this.index, this.page, this.error});

  final int index;
  final _FetchedPage? page;
  final Object? error;
}

class _FetchedPage {
  const _FetchedPage({
    required this.html,
    required this.url,
    required this.base,
  });

  final String html;
  final String url;
  final String base;
}

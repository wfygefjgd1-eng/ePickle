import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';

import '../models/video_item.dart';
import '../utils/http_client.dart';
import '../utils/http_headers.dart';
import 'mirror_ranker.dart';
import 'phub_api.dart';
import 'source_catalog.dart';

/// XVideos list + detail (for feed kind "X").
class XvideosApi {
  static const _singleRequestTimeout = Duration(seconds: 10);
  XvideosApi({Dio? dio, CancelToken? cancelToken})
      : _cancelToken = cancelToken ?? CancelToken(),
        _dio = dio ??
            AppHttpClient.create(
              headers: {
                ...AppHttpHeaders.browser,
                // Referer/Origin follow the current fastest mirror; they are
                // set per-request in the interceptor below.
                'Cookie': 'age_confirmed=1',
                'Accept-Language': 'en-US,en;q=0.9',
              },
            ) {
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          options.headers['Referer'] = '$_base/';
          options.headers['Origin'] = _base;
          handler.next(options);
        },
      ),
    );
  }

  /// Fastest mirror base for xvideos (persistent cross-session ranking).
  String get _base => MirrorRanker.instance.preferredBase(SourceCatalog.xvideos);

  final Dio _dio;
  CancelToken _cancelToken;

  void cancelRequests([String reason = 'cancelled']) {
    final token = _cancelToken;
    _cancelToken = CancelToken();
    if (!token.isCancelled) token.cancel(reason);
  }

  Future<String> _getHtml(String url) async {
    // Record live outcomes into the ranker so a dead top mirror sinks instead
    // of being re-chosen on every request; cancellations (another mirror won a
    // race elsewhere) never count as failures.
    final base = Uri.tryParse(url)?.origin ?? _base;
    final watch = Stopwatch()..start();
    try {
      final html = await _getHtmlOnce(url);
      MirrorRanker.instance.onFetchOutcome(
        SourceCatalog.xvideos.id,
        base,
        ok: true,
        ms: watch.elapsedMilliseconds,
      );
      return html;
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) {
        rethrow;
      }
      MirrorRanker.instance.onFetchOutcome(
        SourceCatalog.xvideos.id,
        base,
        ok: false,
        ms: watch.elapsedMilliseconds,
      );
      rethrow;
    }
  }

  Future<String> _getHtmlOnce(String url) async {
    final token = CancelToken();
    // Cascade the instance-level cancel (page exit / tab switch).
    if (!_cancelToken.isCancelled) {
      // ignore: discarded_futures
      _cancelToken.whenCancel.then((_) {
        if (!token.isCancelled) token.cancel();
      });
    }
    final Response<String> res;
    try {
      res = await _dio
          .get<String>(
            url,
            cancelToken: token,
            options: Options(
              responseType: ResponseType.plain,
              headers: {
                'Accept':
                    'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
              },
            ),
          )
          .timeout(_singleRequestTimeout);
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

  /// Keyword search. XVideos uses p=0 for first page.
  Future<List<VideoItem>> search(String query, {int page = 1}) async {
    final raw = query.trim();
    if (raw.isEmpty) return [];
    // Prefer + for spaces (site search form); also try %20.
    final qPlus = Uri.encodeQueryComponent(raw).replaceAll('%20', '+');
    final qPct = Uri.encodeQueryComponent(raw);
    final p = (page - 1).clamp(0, 999);
    // Only ?k= forms work; /search/<kw> currently 404s.
    // Faster mirrors first (persistent ranking; the catalog always supplies
    // at least one, so no hardcoded fallback list is needed here).
    final bases = <String>[
      ...MirrorRanker.instance.rankedMirrors(SourceCatalog.xvideos),
    ];
    if (bases.isEmpty) {
      // Defensive only — the catalog always supplies mirrors.
      bases.addAll(SourceCatalog.xvideos.mirrors);
    }
    final urls = <String>[];
    for (final b in bases) {
      if (p == 0) {
        urls.addAll([
          '$b/?k=$qPlus',
          '$b/?k=$qPct',
          '$b/?k=$qPlus&sort=relevance',
          '$b/?k=$qPlus&sort=relevance&datef=alltime',
        ]);
      } else {
        urls.addAll([
          '$b/?k=$qPlus&p=$p',
          '$b/?k=$qPct&p=$p',
          '$b/?k=$qPlus&p=$p&sort=relevance',
          '$b/?k=$qPlus&p=$p&sort=relevance&datef=alltime',
        ]);
      }
    }
    Object? lastErr;
    for (final url in urls) {
      try {
        final html = await _getHtml(url);
        final list = _parseList(
          html,
          <String>{},
          base: Uri.parse(url).origin,
        );
        if (list.isNotEmpty) return list;
        // Empty parse on a valid search page → try next shape/mirror.
      } catch (e) {
        if (e is DioException && CancelToken.isCancel(e)) rethrow;
        lastErr = e;
        continue;
      }
    }
    if (lastErr != null) throw lastErr;
    return [];
  }

  Future<List<VideoItem>> fetchFeed({
    int limit = 40,
    Set<String>? exclude,
    int maxUrls = 8,
  }) async {
    final rng = Random();
    final keywords = [
      'asian',
      'japanese',
      'chinese',
      'korean',
      'thai',
      'milf',
      'teen',
      'amateur',
    ];
    final urls = <String>[
      '$_base/',
      '$_base/?k=asian',
      '$_base/best',
    ];
    for (final k in keywords) {
      final p = rng.nextInt(20);
      urls.add(
        p == 0
            ? '$_base/?k=$k'
            : '$_base/?k=$k&p=$p',
      );
    }
    final ordered = [...urls]..shuffle(rng);

    final seen = <String>{...?exclude};
    final results = <VideoItem>[];
    var tried = 0;
    var failCount = 0;
    final concurrency = maxUrls <= 2 ? 2 : 3;
    final hardTimeout = maxUrls <= 2
        ? const Duration(seconds: 14)
        : const Duration(seconds: 24);

    Future<void> runBatches() async {
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
        for (var j = 0; j < pages.length; j++) {
          final html = pages[j];
          if (html == null) continue;
          results.addAll(
            _parseList(
              html,
              seen,
              base: Uri.parse(batchUrls[j]).origin,
            ),
          );
          if (results.length >= limit) break;
        }
        if (results.length >= (limit < 12 ? limit : 8)) break;
      }
    }

    try {
      await runBatches().timeout(hardTimeout);
    } on TimeoutException {
      if (results.isEmpty) {
        throw PhubException(
          'Source fetch timed out. Check network/TUN and try again.',
        );
      }
    }
    if (results.isEmpty && (failCount > 0 || tried > 0)) {
      throw PhubException(
        'Unable to fetch source pages ($failCount/$tried failed). '
        'Check network/TUN or try again later.',
      );
    }
    results.shuffle(rng);
    if (results.length > limit) return results.sublist(0, limit);
    return results;
  }

  List<VideoItem> _parseList(String html, Set<String> seen, {String? base}) {
    final itemBase = base ?? _base;
    final out = <VideoItem>[];
    // Card blocks: id="video_XXXX" (hex id) or legacy numeric
    final blocks = html.split(RegExp(r'(?=<div[^>]+id="video_[^"]+")'));
    Iterable<String> iterable;
    if (blocks.length > 1) {
      iterable = blocks.skip(1);
    } else {
      // Fallback: split on video hrefs (new layout / search pages / mirrors)
      iterable = html.split(RegExp(
        r'(?=href="(?:https?://(?:www\.)?xvideos\.(?:com|es|net))?/video\.[a-zA-Z0-9]+/)',
      ));
      if (iterable.length <= 1) {
        iterable = html.split(RegExp(r'(?=href="/video\.[a-zA-Z0-9]+/)'));
      }
    }

    final hrefRe = RegExp(
      r'href="(?:https?://(?:www\.)?xvideos\.(?:com|es|net))?(/video\.[a-zA-Z0-9]+/[^"#?\s]+)"',
    );
    final titleOnHref = RegExp(
      r'href="(?:https?://(?:www\.)?xvideos\.(?:com|es|net))?/video\.[a-zA-Z0-9]+/[^"]+"[^>]*title="([^"]+)"',
    );
    final titleBeforeHref = RegExp(
      r'title="([^"]+)"[^>]*href="(?:https?://(?:www\.)?xvideos\.(?:com|es|net))?/video\.[a-zA-Z0-9]+/',
    );
    final pTitleRe = RegExp(
      r'class="[^"]*title[^"]*"[^>]*>\s*<a[^>]*>([^<]{1,200})',
      caseSensitive: false,
    );
    final thumbRe = RegExp(
      r'data-src="((?:https?:)?//[^"]+)"|data-srcse="((?:https?:)?//[^"]+)"|data-idthumb="((?:https?:)?//[^"]+)"|data-thumb="((?:https?:)?//[^"]+)"|data-sfwthumb="((?:https?:)?//[^"]+)"|src="((?:https?:)?//[^"]+\.(?:jpg|jpeg|png|webp)[^"]*)"',
      caseSensitive: false,
    );
    final durRe = RegExp(
      r'class="duration"[^>]*>\s*([^<]+)',
      caseSensitive: false,
    );
    // Hoisted: compiled once per parse instead of per card.
    final videoIdRe = RegExp(r'/video\.([a-zA-Z0-9]+)');
    final titleNoiseRe = RegExp(r'title="([^"]{3,200})"');

    for (final chunk in iterable) {
      final hm = hrefRe.firstMatch(chunk);
      if (hm == null) continue;
      final path = hm.group(1)!;
      final idM = videoIdRe.firstMatch(path);
      final id = idM?.group(1) ?? path;
      if (!seen.add(id)) continue;

      String? title;
      final tLink = titleOnHref.firstMatch(chunk);
      final tTitleFirst = titleBeforeHref.firstMatch(chunk);
      if (tLink != null) {
        title = tLink.group(1);
      } else if (tTitleFirst != null) {
        title = tTitleFirst.group(1);
      } else {
        for (final m in titleNoiseRe.allMatches(chunk)) {
          final c = m.group(1)!;
          final low = c.toLowerCase();
          if (low.contains('toggle') ||
              low.contains('logo') ||
              low.contains('menu') ||
              low.contains('search') ||
              low.contains('settings') ||
              low == 'xvideos' ||
              low.contains('xvideos.com')) {
            continue;
          }
          title = c;
          break;
        }
      }
      if (title == null || title.length < 2) {
        final pTitle = pTitleRe.firstMatch(chunk);
        if (pTitle != null) {
          title = pTitle
              .group(1)!
              .replaceAll(RegExp(r'<[^>]+>'), ' ')
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim();
        }
      }
      if (title == null || title.length < 2) {
        // Trailing slash on /video.123/slug/ yields an empty last segment —
        // strip it before splitting so untitled cards aren't dropped.
        final slashless = path.endsWith('/')
            ? path.substring(0, path.length - 1)
            : path;
        final slug = slashless.split('/').last.replaceAll('_', ' ').trim();
        if (slug.length >= 2) title = slug;
      }
      if (title == null || title.length < 2) continue;
      title = title
          .replaceAll('&#039;', "'")
          .replaceAll('&amp;', '&')
          .replaceAll('&quot;', '"')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      // Strip trailing duration text accidentally captured in anchor body.
      title = title.replaceAll(RegExp(r'\s+\d+\s*min\s*$'), '').trim();
      if (title.length < 2) continue;

      String? thumb;
      final tm = thumbRe.firstMatch(chunk);
      if (tm != null) {
        thumb = tm.group(1) ??
            tm.group(2) ??
            tm.group(3) ??
            tm.group(4) ??
            tm.group(5) ??
            tm.group(6);
      }
      if (thumb != null && thumb.startsWith('//')) {
        thumb = 'https:$thumb';
      }

      var duration = '-';
      final dm = durRe.firstMatch(chunk);
      if (dm != null) {
        final d = dm.group(1)!.trim();
        if (d.isNotEmpty) duration = d;
      }

      out.add(VideoItem(
        // Detail URL stays on the mirror that actually served the card, so a
        // tap continues on the same fast route instead of hopping back to the
        // primary host.
        url: '$itemBase$path',
        title: title,
        duration: duration,
        thumb: thumb,
      ));
    }
    return out;
  }

  Future<VideoDetail> getVideoDetail(String url) async {
    final html = await _getHtml(url);
    final titleM = RegExp(r"setVideoTitle\('([^']*)'\)").firstMatch(html) ??
        RegExp(r'setVideoTitle\("([^"]*)"\)').firstMatch(html);
    var title = titleM?.group(1) ?? '';
    title = title
        .replaceAll(r"\'", "'")
        .replaceAll('&#039;', "'")
        .replaceAll('&amp;', '&');
    if (title.isEmpty) {
      final t2 = RegExp(r'<title>([^<]+)</title>', caseSensitive: false)
          .firstMatch(html);
      title = (t2?.group(1) ?? url).split('-').first.trim();
    }

    final streams = <StreamQuality>[];
    final hls = RegExp(r"setVideoHLS\('([^']+)'\)").firstMatch(html) ??
        RegExp(r'setVideoHLS\("([^"]+)"\)').firstMatch(html);
    if (hls != null) {
      streams.add(StreamQuality(width: 1280, height: 720, url: hls.group(1)!));
    }
    final high = RegExp(r"setVideoUrlHigh\('([^']+)'\)").firstMatch(html) ??
        RegExp(r'setVideoUrlHigh\("([^"]+)"\)').firstMatch(html);
    if (high != null) {
      streams.add(StreamQuality(width: 640, height: 360, url: high.group(1)!));
    }
    final low = RegExp(r"setVideoUrlLow\('([^']+)'\)").firstMatch(html) ??
        RegExp(r'setVideoUrlLow\("([^"]+)"\)').firstMatch(html);
    if (low != null) {
      streams.add(StreamQuality(width: 426, height: 240, url: low.group(1)!));
    }
    if (streams.isEmpty) {
      throw PhubException('无法解析 X 视频地址');
    }
    streams.sort((a, b) => b.pixels.compareTo(a.pixels));

    final thumbM = RegExp(r"setThumbUrl\('([^']+)'\)").firstMatch(html) ??
        RegExp(r'setThumbUrl169\("([^"]+)"\)').firstMatch(html) ??
        RegExp(r"setThumbUrl169\('([^']+)'\)").firstMatch(html);

    return VideoDetail(
      url: url,
      title: title.isEmpty ? url : title,
      durationSec: 0,
      thumb: thumbM?.group(1),
      streams: streams,
    );
  }
}

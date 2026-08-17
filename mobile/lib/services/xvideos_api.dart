import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';

import '../models/video_item.dart';
import '../utils/http_client.dart';
import '../utils/http_headers.dart';
import 'phub_api.dart';

/// XVideos list + detail (for feed kind "X").
class XvideosApi {
  XvideosApi({Dio? dio, CancelToken? cancelToken})
      : _cancelToken = cancelToken ?? CancelToken(),
        _dio = dio ??
            AppHttpClient.create(
              headers: {
                ...AppHttpHeaders.browser,
                'Referer': 'https://www.xvideos.com/',
                'Origin': 'https://www.xvideos.com',
                'Cookie': 'age_confirmed=1',
                'Accept-Language': 'en-US,en;q=0.9',
              },
            );

  final Dio _dio;
  CancelToken _cancelToken;

  void cancelRequests([String reason = 'cancelled']) {
    final token = _cancelToken;
    _cancelToken = CancelToken();
    if (!token.isCancelled) token.cancel(reason);
  }

  Future<String> _getHtml(String url) async {
    final res = await _dio.get<String>(
      url,
      cancelToken: _cancelToken,
      options: Options(
        responseType: ResponseType.plain,
        headers: {
          'Accept':
              'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        },
      ),
    );
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

  /// Keyword search. XVideos uses p=0 for first page.
  Future<List<VideoItem>> search(String query, {int page = 1}) async {
    final raw = query.trim();
    if (raw.isEmpty) return [];
    // Prefer + for spaces (site search form); also try %20.
    final qPlus = Uri.encodeQueryComponent(raw).replaceAll('%20', '+');
    final qPct = Uri.encodeQueryComponent(raw);
    final p = (page - 1).clamp(0, 999);
    // Only ?k= forms work; /search/<kw> currently 404s.
    final bases = <String>[
      'https://www.xvideos.com',
      'https://www.xvideos.es',
    ];
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
        final list = _parseList(html, <String>{});
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
      'https://www.xvideos.com/',
      'https://www.xvideos.com/?k=asian',
      'https://www.xvideos.com/best',
    ];
    for (final k in keywords) {
      final p = rng.nextInt(20);
      urls.add(
        p == 0
            ? 'https://www.xvideos.com/?k=$k'
            : 'https://www.xvideos.com/?k=$k&p=$p',
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
        for (final html in pages) {
          if (html == null) continue;
          results.addAll(_parseList(html, seen));
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
          '鍔犺浇瓒呮椂銆傚彲锛氳缃啋閲嶆柊妫€娴嬩唬鐞嗭紝鎴栧紑 TUN/VPN',
        );
      }
    }
    if (results.isEmpty && (failCount > 0 || tried > 0)) {
      throw PhubException(
        '鏃犳硶璁块棶婧愮珯锛?failCount/$tried 澶辫触锛夈€?
        '绯荤粺鏈唬鐞嗘椂璇峰紑 TUN锛屾垨璁剧疆閲屽～鍐?妫€娴嬩唬鐞?,
      );
    }
    results.shuffle(rng);
    if (results.length > limit) return results.sublist(0, limit);
    return results;
  }

  List<VideoItem> _parseList(String html, Set<String> seen) {
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

    for (final chunk in iterable) {
      final hm = hrefRe.firstMatch(chunk);
      if (hm == null) continue;
      final path = hm.group(1)!;
      final idM = RegExp(r'/video\.([a-zA-Z0-9]+)').firstMatch(path);
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
        for (final m in RegExp(r'title="([^"]{3,200})"').allMatches(chunk)) {
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
        final slug = path.split('/').last.replaceAll('_', ' ').trim();
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
        url: 'https://www.xvideos.com$path',
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

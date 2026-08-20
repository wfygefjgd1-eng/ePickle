import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';

import '../models/video_item.dart';
import '../utils/http_client.dart';
import '../utils/http_headers.dart';
import 'mirror_ranker.dart';
import 'scrape_exception.dart';
import 'source_catalog.dart';

/// mitaohk.com — 中文字幕分类 (MacCMS type id=2).
class MitaoApi {
  /// 主域名 — 自动取当前最快的镜像（排名未就绪时按目录顺序，即 mitaohk.com
  /// 优先）。Referer/Origin 由拦截器按请求时注入，保证换镜像即时生效。
  String get base => MirrorRanker.instance.preferredBase(SourceCatalog.mitao);

  /// 中文字幕
  static const zhongTypeId = 2;

  static const _singleRequestTimeout = Duration(seconds: 10);

  MitaoApi({Dio? dio, CancelToken? cancelToken})
      : _cancelToken = cancelToken ?? CancelToken(),
        _dio = dio ??
            AppHttpClient.create(
              headers: {
                ...AppHttpHeaders.browser,
                'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
              },
            ) {
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          options.cancelToken ??= _cancelToken;
          options.headers['Referer'] = '$base/';
          options.headers['Origin'] = base;
          handler.next(options);
        },
      ),
    );
  }

  final Dio _dio;
  CancelToken _cancelToken;

  void cancelRequests([String reason = 'cancelled']) {
    final token = _cancelToken;
    _cancelToken = CancelToken();
    if (!token.isCancelled) token.cancel(reason);
  }

  Future<String> _getHtml(String url) async {
    // Live outcomes feed the ranker so a dead top mirror sinks instead of
    // being re-chosen forever; cancellations are never failures.
    final base = Uri.tryParse(url)?.origin ?? this.base;
    final watch = Stopwatch()..start();
    try {
      final html = await _getHtmlOnce(url);
      MirrorRanker.instance.onFetchOutcome(
        SourceCatalog.mitao.id,
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
        SourceCatalog.mitao.id,
        base,
        ok: false,
        ms: watch.elapsedMilliseconds,
      );
      rethrow;
    }
  }

  /// Fetch [buildUrl] against every mitao mirror in ranked order. Each
  /// non-cancel failure demotes that mirror (via [_getHtml]'s outcome
  /// feedback) and the next mirror gets a shot — a dead top mirror can no
  /// longer take the whole site down until the next probe.
  Future<String> _getHtmlWithFailover(
    String Function(String base) buildUrl, {
    List<String>? mirrors,
  }) async {
    final bases = mirrors ??
        MirrorRanker.instance.rankedMirrors(SourceCatalog.mitao);
    if (bases.isEmpty) bases.addAll(SourceCatalog.mitao.mirrors);
    Object? lastError;
    for (final base in bases) {
      try {
        return await _getHtml(buildUrl(base));
      } catch (e) {
        if (e is DioException && CancelToken.isCancel(e)) rethrow;
        lastError = e;
      }
    }
    throw lastError ?? PhubException('请求失败');
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
          .get<String>(url, cancelToken: token)
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

  String _abs(String path) {
    if (path.startsWith('http')) return path;
    if (path.startsWith('//')) return 'https:$path';
    if (!path.startsWith('/')) path = '/$path';
    return '$base$path';
  }

  /// Site search (keyword as-is; Chinese OK for this site).
  Future<List<VideoItem>> search(String query, {int page = 1}) async {
    final q = Uri.encodeComponent(query.trim());
    if (q.isEmpty) return [];
    // MacCMS search URL
    try {
      final html = await _getHtmlWithFailover(
        (b) => page <= 1
            ? '$b/index.php/vod/search/wd/$q.html'
            : '$b/index.php/vod/search/wd/$q/page/$page.html',
      );
      return _parseList(html, <String>{});
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) rethrow;
      // alternate pattern
      final html = await _getHtmlWithFailover(
        (b) => '$b/index.php/vod/search.html?wd=$q&page=$page',
      );
      return _parseList(html, <String>{});
    }
  }

  /// Random pages of 中文字幕 type list.
  Future<List<VideoItem>> fetchZhong({
    int limit = 40,
    Set<String>? exclude,
    int maxPages = 6,
  }) async {
    final rng = Random();
    final pages = <int>{1};
    while (pages.length < maxPages) {
      pages.add(1 + rng.nextInt(30));
    }
    final ordered = pages.toList()..shuffle(rng);

    final seen = <String>{...?exclude};
    final results = <VideoItem>[];
    var failCount = 0;
    var tried = 0;
    final concurrency = maxPages <= 2 ? 2 : 3;
    final hardTimeout = maxPages <= 2
        ? const Duration(seconds: 14)
        : const Duration(seconds: 24);

    Future<List<VideoItem>> fetchPage(int p) async {
      try {
        final html = await _getHtmlWithFailover(
          (b) => p <= 1
              ? '$b/index.php/vod/type/id/$zhongTypeId.html'
              : '$b/index.php/vod/type/id/$zhongTypeId/page/$p.html',
        );
        return _parseList(html, seen);
      } catch (e) {
        if (e is DioException && CancelToken.isCancel(e)) rethrow;
        if (p > 1) {
          try {
            final html = await _getHtmlWithFailover(
              (b) => '$b/index.php/vod/type/id/$zhongTypeId.html?page=$p',
            );
            return _parseList(html, seen);
          } catch (e) {
            if (e is DioException && CancelToken.isCancel(e)) rethrow;
          }
        }
        // Count once per page (primary + alt are one logical page attempt).
        failCount++;
        return const <VideoItem>[];
      }
    }

    Future<void> runBatches() async {
      for (var i = 0; i < ordered.length && tried < maxPages;) {
        if (results.length >= limit) break;
        final batchPages = <int>[];
        while (batchPages.length < concurrency &&
            i < ordered.length &&
            tried < maxPages) {
          batchPages.add(ordered[i]);
          i++;
          tried++;
        }
        final pagesOut = await Future.wait(batchPages.map(fetchPage));
        for (final list in pagesOut) {
          if (list.isEmpty) continue;
          results.addAll(list);
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
          '加载超时。可：设置→重新检测代理，或开 TUN/VPN',
        );
      }
    }
    if (results.isEmpty && (failCount > 0 || tried > 0)) {
      throw PhubException(
        '无法访问源站（$failCount/$tried 失败）。'
        '系统未代理时请开 TUN，或设置里填写/检测代理',
      );
    }

    results.shuffle(rng);
    if (results.length > limit) return results.sublist(0, limit);
    return results;
  }

  List<VideoItem> _parseList(String html, Set<String> seen) {
    final out = <VideoItem>[];
    final detailRe = RegExp(r'/index\.php/vod/detail/id/(\d+)\.html');
    final playRe = RegExp(
      r'/index\.php/vod/play/id/(\d+)/sid/(\d+)/nid/(\d+)\.html',
    );

    final titles = <String, String>{};
    final thumbs = <String, String>{};
    final playPaths = <String, String>{};

    void considerTitle(String id, String raw) {
      final t = _cleanTitle(raw);
      if (!_isGoodTitle(t, id)) return;
      final prev = titles[id];
      // Prefer longer / CJK-rich titles over short noise
      if (prev == null || _titleScore(t) > _titleScore(prev)) {
        titles[id] = t;
      }
    }

    // Module cards: title attr + href (both orders)
    for (final m in RegExp(
      r'title="([^"]{2,200})"[^>]*href="(/index\.php/vod/(?:detail|play)/id/(\d+)[^"]*)"',
      caseSensitive: false,
    ).allMatches(html)) {
      final id = m.group(3)!;
      considerTitle(id, m.group(1)!);
      final href = m.group(2)!;
      if (href.contains('/play/')) {
        playPaths.putIfAbsent(id, () => href);
      }
    }
    for (final m in RegExp(
      r'href="(/index\.php/vod/(?:detail|play)/id/(\d+)[^"]*)"[^>]*title="([^"]{2,200})"',
      caseSensitive: false,
    ).allMatches(html)) {
      final id = m.group(2)!;
      considerTitle(id, m.group(3)!);
      final href = m.group(1)!;
      if (href.contains('/play/')) {
        playPaths.putIfAbsent(id, () => href);
      }
    }

    // data-original / lazy img alt near detail links
    for (final m in RegExp(
      r'alt="([^"]{2,200})"[^>]*(?:data-original|data-src|src)="([^"]+)"[^>]{0,200}href="[^"]*vod/(?:detail|play)/id/(\d+)',
      caseSensitive: false,
    ).allMatches(html)) {
      considerTitle(m.group(3)!, m.group(1)!);
      thumbs.putIfAbsent(m.group(3)!, () => m.group(2)!);
    }

    // Text inside titled anchors: <a href="...detail/id/N">真实标题</a>
    for (final m in RegExp(
      r'href="(/index\.php/vod/(?:detail|play)/id/(\d+)[^"]*)"[^>]*>\s*([^<]{4,200})\s*<',
      caseSensitive: false,
    ).allMatches(html)) {
      final id = m.group(2)!;
      considerTitle(id, m.group(3)!);
      final href = m.group(1)!;
      if (href.contains('/play/')) {
        playPaths.putIfAbsent(id, () => href);
      }
    }

    for (final m in detailRe.allMatches(html)) {
      final id = m.group(1)!;
      final idx = m.start;
      final start = idx > 800 ? idx - 800 : 0;
      final end = (idx + 600).clamp(0, html.length);
      final ctx = html.substring(start, end);
      final t = _pickTitle(ctx, id);
      if (t.isNotEmpty) considerTitle(id, t);
      final th = _pickThumb(ctx);
      if (th != null) thumbs.putIfAbsent(id, () => th);
    }

    for (final m in playRe.allMatches(html)) {
      final id = m.group(1)!;
      final path =
          '/index.php/vod/play/id/$id/sid/${m.group(2)}/nid/${m.group(3)}.html';
      playPaths.putIfAbsent(id, () => path);
      if (!titles.containsKey(id) ||
          (thumbs[id] == null || thumbs[id]!.isEmpty)) {
        final idx = m.start;
        final start = idx > 800 ? idx - 800 : 0;
        final end = (idx + 600).clamp(0, html.length);
        final ctx = html.substring(start, end);
        if (!titles.containsKey(id)) {
          final t = _pickTitle(ctx, id);
          if (t.isNotEmpty) considerTitle(id, t);
        }
        final th = _pickThumb(ctx);
        if (th != null) thumbs.putIfAbsent(id, () => th);
      }
    }

    // MacCMS list often has .module-item-title / .module-item-pic
    for (final m in RegExp(
      r'class="[^"]*module-item-title[^"]*"[^>]*>\s*<a[^>]*href="[^"]*id/(\d+)[^"]*"[^>]*>([^<]{2,200})</a>',
      caseSensitive: false,
    ).allMatches(html)) {
      considerTitle(m.group(1)!, m.group(2)!);
    }
    for (final m in RegExp(
      r'class="[^"]*module-item-title[^"]*"[^>]*>\s*<a[^>]*title="([^"]{2,200})"[^>]*href="[^"]*id/(\d+)',
      caseSensitive: false,
    ).allMatches(html)) {
      considerTitle(m.group(2)!, m.group(1)!);
    }

    final ids = {...titles.keys, ...playPaths.keys, ...thumbs.keys};
    for (final id in ids) {
      if (!seen.add(id)) continue;
      final path =
          playPaths[id] ?? '/index.php/vod/play/id/$id/sid/1/nid/1.html';
      var title = titles[id] ?? '';
      if (!_isGoodTitle(title, id)) {
        title = '未命名 $id';
      }

      final th = thumbs[id];
      out.add(VideoItem(
        url: _abs(path.startsWith('/') ? path : '/$path'),
        title: title,
        duration: '-',
        thumb: (th != null && th.isNotEmpty) ? _abs(th) : null,
      ));
    }
    return out;
  }

  String _cleanTitle(String t) => t
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&amp;', '&')
      .replaceAll('&#039;', "'")
      .replaceAll('&quot;', '"')
      .replaceAll('&nbsp;', ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  bool _isGoodTitle(String t, String id) {
    if (t.isEmpty || t.length < 2) return false;
    if (t == id || RegExp(r'^\d+$').hasMatch(t)) return false;
    if (t == '中文字幕' || t == '更多' || t == '播放' || t == '详情') return false;
    if (t.contains('点击') || t.contains('广告')) return false;
    if (t.startsWith('视频') && RegExp(r'^视频\s*\d+$').hasMatch(t)) return false;
    return true;
  }

  int _titleScore(String t) {
    var s = t.length;
    if (RegExp(r'[\u4e00-\u9fff]').hasMatch(t)) s += 20;
    return s;
  }

  String _pickTitle(String ctx, String id) {
    final cands = <String>[];
    for (final m in RegExp(r'title="([^"]{2,200})"').allMatches(ctx)) {
      cands.add(_cleanTitle(m.group(1)!));
    }
    for (final m in RegExp(r'alt="([^"]{2,200})"').allMatches(ctx)) {
      cands.add(_cleanTitle(m.group(1)!));
    }
    for (final m in RegExp(
      r'<(?:h[234]|span|p|div)[^>]*class="[^"]*(?:title|name|vod)[^"]*"[^>]*>([^<]{2,200})</',
      caseSensitive: false,
    ).allMatches(ctx)) {
      cands.add(_cleanTitle(m.group(1)!));
    }
    // bare CJK text near link
    for (final m in RegExp(r'>([\u4e00-\u9fff][^<]{3,80})<').allMatches(ctx)) {
      cands.add(_cleanTitle(m.group(1)!));
    }
    String? best;
    for (final t in cands) {
      if (!_isGoodTitle(t, id)) continue;
      if (best == null || _titleScore(t) > _titleScore(best)) best = t;
    }
    return best ?? '';
  }

  String? _pickThumb(String ctx) {
    final im = RegExp(
      r'data-original="([^"]+)"|data-src="([^"]+)"|data-bg="([^"]+)"|src="((?:https?:)?//[^"]+\.(?:jpg|jpeg|png|webp)[^"]*)"',
      caseSensitive: false,
    ).firstMatch(ctx);
    if (im == null) return null;
    return im.group(1) ?? im.group(2) ?? im.group(3) ?? im.group(4);
  }

  Future<VideoDetail> getVideoDetail(String url) async {
    // Prefer play page; detail-only pages sometimes lack player_aaaa.
    var pageUrl = url;
    if (pageUrl.contains('/vod/detail/id/')) {
      final idm = RegExp(r'/vod/detail/id/(\d+)').firstMatch(pageUrl);
      if (idm != null) {
        pageUrl =
            '$base/index.php/vod/play/id/${idm.group(1)}/sid/1/nid/1.html';
      }
    }

    String html;
    try {
      html = await _getHtml(pageUrl);
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) rethrow;
      html = await _getHtml(url);
      pageUrl = url;
    }

    var m = RegExp(
      r'player_aaaa\s*=\s*(\{[\s\S]*?\})\s*</script>',
    ).firstMatch(html);
    m ??= RegExp(
      r'player_aaaa\s*=\s*(\{[\s\S]*?\})\s*;',
    ).firstMatch(html);
    m ??= RegExp(
      r'player_data\s*=\s*(\{[\s\S]*?\})\s*;',
    ).firstMatch(html);

    if (m == null) {
      // MacCMS sometimes puts url in MacPlayerConfig
      final loose = RegExp(
        r'''["']url["']\s*:\s*["'](https?[^"']+\.(?:m3u8|mp4)[^"']*)["']''',
        caseSensitive: false,
      ).firstMatch(html);
      if (loose != null) {
        var playUrl = loose.group(1)!.replaceAll(r'\/', '/');
        playUrl = await _resolvePlayableUrl(playUrl);
        return VideoDetail(
          url: pageUrl,
          title: _titleFromHtml(html) ?? pageUrl,
          durationSec: await _durationFromM3u8(playUrl),
          streams: [
            StreamQuality(width: 1280, height: 720, url: playUrl),
          ],
        );
      }
      throw PhubException('无法解析播放数据');
    }

    Map<String, dynamic> data;
    try {
      var raw = m.group(1)!;
      // player_aaaa JSON may contain unescaped control chars
      raw = raw.replaceAll(r'\/', '/');
      data = jsonDecode(raw) as Map<String, dynamic>;
    } catch (e) {
      // Fallback: pull url field with regex
      final um = RegExp(r'''["']url["']\s*:\s*["']([^"']+)["']''')
          .firstMatch(m.group(1)!);
      if (um == null) throw PhubException('播放 JSON 解析失败: $e');
      data = {'url': um.group(1), 'encrypt': 0};
    }

    final encrypt = int.tryParse('${data['encrypt']}') ?? 0;
    var playUrl = (data['url'] ?? '').toString().trim();
    if (playUrl.isEmpty) {
      throw PhubException('播放地址为空');
    }
    playUrl = playUrl.replaceAll(r'\/', '/').replaceAll('&amp;', '&');
    if (encrypt == 1) {
      try {
        playUrl = utf8.decode(base64.decode(playUrl));
      } catch (_) {
        throw PhubException('播放地址解密失败');
      }
    } else if (encrypt == 2) {
      // escape + base64 (common MacCMS)
      try {
        playUrl = utf8.decode(base64.decode(Uri.decodeComponent(playUrl)));
      } catch (_) {
        try {
          playUrl = utf8.decode(base64.decode(playUrl));
        } catch (_) {
          throw PhubException('播放地址解密失败(encrypt=2)');
        }
      }
    }
    if (!playUrl.startsWith('http')) {
      playUrl = _abs(playUrl);
    }
    playUrl = await _resolvePlayableUrl(playUrl);

    String title = '';
    var durationSec = 0;
    final vd = data['vod_data'];
    if (vd is Map) {
      title = (vd['vod_name'] ?? '').toString();
      durationSec = int.tryParse('${vd['vod_duration'] ?? 0}') ?? 0;
      if (durationSec <= 0) {
        final ds = (vd['vod_duration'] ?? vd['duration'] ?? '').toString();
        durationSec = _parseDurationText(ds);
      }
    }
    durationSec = _durationFromHtml(html, durationSec);
    if (durationSec <= 0) {
      durationSec = await _durationFromM3u8(playUrl);
    }

    if (title.isEmpty) {
      title = _titleFromHtml(html) ?? '视频';
    }

    final streams = <StreamQuality>[
      StreamQuality(width: 1280, height: 720, url: playUrl),
    ];

    return VideoDetail(
      url: pageUrl,
      title: title.isEmpty ? pageUrl : title,
      durationSec: durationSec,
      streams: streams,
    );
  }

  String? _titleFromHtml(String html) {
    final og = RegExp(
      r'<meta[^>]+property=["'
      ']og:title["'
      '][^>]+content=["'
      ']([^"'
      ']+)["'
      ']',
      caseSensitive: false,
    ).firstMatch(html);
    if (og != null) return og.group(1)!.trim();
    final tm = RegExp(r'<title>([^<]+)</title>', caseSensitive: false)
        .firstMatch(html);
    if (tm != null) {
      return tm.group(1)!.split(RegExp(r'\s*[-_|–—]\s*')).first.trim();
    }
    return null;
  }

  int _durationFromHtml(String html, int current) {
    if (current > 0) return current;
    final patterns = <RegExp>[
      RegExp(r'vod_duration["\s:]+["' "'" r']?(\d+)'),
      RegExp(r'时长[：:\s]*(\d{1,2}):(\d{2}):(\d{2})'),
      RegExp(r'(?:播放时长|片长)[：:\s]*(\d{1,2}:\d{2}(?::\d{2})?)'),
      RegExp(r'''data-duration=["'](\d+)["']'''),
      RegExp(r'"duration"\s*:\s*(\d+)'),
    ];
    for (final re in patterns) {
      final m = re.firstMatch(html);
      if (m == null) continue;
      if (m.groupCount >= 3 && m.group(3) != null) {
        final h = int.tryParse(m.group(1) ?? '0') ?? 0;
        final mi = int.tryParse(m.group(2) ?? '0') ?? 0;
        final s = int.tryParse(m.group(3) ?? '0') ?? 0;
        final t = h * 3600 + mi * 60 + s;
        if (t > 0) return t;
      } else {
        final g = m.group(1) ?? '';
        final t = _parseDurationText(g);
        if (t > 0) return t;
      }
    }
    return 0;
  }

  /// Follow master m3u8 → media playlist; some CDNs need site Referer.
  Future<String> _resolvePlayableUrl(String playUrl) async {
    if (!playUrl.toLowerCase().contains('.m3u8')) return playUrl;
    try {
      final res = await _dio.get<String>(
        playUrl,
        options: Options(
          responseType: ResponseType.plain,
          headers: {
            ...AppHttpHeaders.forMediaUrl(playUrl, pageUrl: base),
            'Accept': 'application/vnd.apple.mpegurl,application/x-mpegURL,*/*',
          },
          receiveTimeout: const Duration(seconds: 12),
        ),
      );
      final body = res.data ?? '';
      if (!body.contains('#EXTM3U')) return playUrl;
      // Master playlist: pick highest bandwidth variant
      if (body.contains('#EXT-X-STREAM-INF')) {
        final lines = body.split(RegExp(r'\r?\n'));
        String? best;
        var bestBw = -1;
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i].trim();
          if (!line.startsWith('#EXT-X-STREAM-INF')) continue;
          final bw = int.tryParse(
                  RegExp(r'BANDWIDTH=(\d+)').firstMatch(line)?.group(1) ??
                      '') ??
              0;
          if (i + 1 >= lines.length) continue;
          var next = lines[i + 1].trim();
          if (next.isEmpty || next.startsWith('#')) continue;
          if (bw >= bestBw) {
            bestBw = bw;
            best = next;
          }
        }
        if (best != null) {
          return _absUrl(playUrl, best);
        }
      }
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) rethrow;
    }
    return playUrl;
  }

  String _absUrl(String baseUrl, String ref) {
    final r = ref.trim();
    if (r.startsWith('http://') || r.startsWith('https://')) return r;
    if (r.startsWith('//')) return 'https:$r';
    final u = Uri.parse(baseUrl);
    if (r.startsWith('/')) return '${u.scheme}://${u.host}$r';
    final path = u.path.substring(0, u.path.lastIndexOf('/') + 1);
    return '${u.scheme}://${u.host}$path$r';
  }

  /// Sum EXTINF from media playlist so UI has a seek bar even if ExoPlayer
  /// reports duration=0 for some HLS.
  Future<int> _durationFromM3u8(String playUrl) async {
    if (!playUrl.toLowerCase().contains('m3u8')) return 0;
    try {
      var url = playUrl;
      for (var hop = 0; hop < 2; hop++) {
        final res = await _dio.get<String>(
          url,
          options: Options(
            responseType: ResponseType.plain,
            headers: AppHttpHeaders.forMediaUrl(url, pageUrl: base),
            receiveTimeout: const Duration(seconds: 12),
          ),
        );
        final body = res.data ?? '';
        if (body.contains('#EXT-X-STREAM-INF')) {
          final lines = body.split(RegExp(r'\r?\n'));
          for (var i = 0; i < lines.length; i++) {
            if (lines[i].contains('#EXT-X-STREAM-INF') &&
                i + 1 < lines.length) {
              final next = lines[i + 1].trim();
              if (next.isNotEmpty && !next.startsWith('#')) {
                url = _absUrl(url, next);
                break;
              }
            }
          }
          continue;
        }
        var total = 0.0;
        for (final m in RegExp(r'#EXTINF:([\d.]+)').allMatches(body)) {
          total += double.tryParse(m.group(1)!) ?? 0;
        }
        if (total >= 1) return total.round();
        break;
      }
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) rethrow;
    }
    return 0;
  }

  int _parseDurationText(String s) {
    final t = s.trim();
    if (t.isEmpty) return 0;
    final n = int.tryParse(t);
    if (n != null && n > 0) return n;
    final parts = t.split(':').map((e) => int.tryParse(e) ?? 0).toList();
    if (parts.length == 3) {
      return parts[0] * 3600 + parts[1] * 60 + parts[2];
    }
    if (parts.length == 2) {
      return parts[0] * 60 + parts[1];
    }
    return 0;
  }
}

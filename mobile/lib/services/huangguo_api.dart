import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';

import '../models/video_item.dart';
import '../utils/http_client.dart';
import '../utils/http_headers.dart';
import 'app_settings.dart';
import 'mirror_ranker.dart';
import 'scrape_exception.dart';
import 'source_catalog.dart';

/// huangguoai.com (黄果短剧) — 内置规则适配器。
///
/// 黄果规则（可在设置中修改主域名，换域名不重装）：
///  - 频道列表:  /ai-duanju/  /ai-manju/  /ai-huanlian/  /ai-mogai/
///  - 排行榜:    /ranks/hot/  专题: /topics/  首页推荐: /
///  - 分页:      /ai-duanju/2/  (列表页卡片 href=/detail/ID/)
///  - 播放数据:  播放页 /video/ID/ 内嵌
///               <script id="videoInitialData" type="application/json">
///               含 epPlaySrcs {集数: m3u8} / videoSrc / videoType / title /
///               coverSrc / description。
class HuangGuoApi {
  static const String defaultBase = 'https://huangguoai.com';

  /// 封面/图片 AES-128-CBC(NoPadding) 密钥与 IV（站点 crypto-worker.js 内嵌，
  /// 实图 = 对 URL 返回的密文做 CBC 解密；浏览器内由 Worker 完成）。
  static const String mediaAesKey = 'f5d965df75336270';
  static const String mediaAesIv = '97b60394abc2fbe1';

  static const _singleRequestTimeout = Duration(seconds: 10);

  HuangGuoApi({AppSettings? settings, Dio? dio, CancelToken? cancelToken})
      : _cancelToken = cancelToken ?? CancelToken(),
        _dio = dio ?? AppHttpClient.create() {
    _settings = settings;
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          options.cancelToken ??= _cancelToken;
          handler.next(options);
        },
      ),
    );
  }

  AppSettings? _settings;
  final Dio _dio;
  CancelToken _cancelToken;

  /// 剧集缓存：detail url → 各集 VideoItem（第 1 集起，含直接播放地址）。
  /// 播放器在详情抓取完成后展开成连续翻页条目。
  final Map<String, List<VideoItem>> _episodesCache = {};

  /// 已展开过的剧集 key（播放器侧还会再过滤一次，这里仅作为 API 层快取）。
  List<VideoItem>? episodesFor(String url) => _episodesCache[url];

  /// 主域名（黄果规则），设置里可改；运行时读取，改完即时生效。
  /// 未设置时自动使用最快镜像（目录顺序兜底）。
  String get base {
    final custom = _settings?.huangguoDomain.trim();
    if (custom != null && custom.isNotEmpty) {
      return custom.replaceAll(RegExp(r'/$'), '');
    }
    return MirrorRanker.instance.preferredBase(SourceCatalog.huangguo);
  }

  void cancelRequests([String reason = 'cancelled']) {
    final token = _cancelToken;
    _cancelToken = CancelToken();
    if (!token.isCancelled) token.cancel(reason);
  }

  Future<String> _getHtml(String url, {Duration? timeout}) async {
    // Live outcomes feed the ranker (used when no custom domain is set);
    // cancellations are control flow, never failures.
    final base = _originOf(url) ?? this.base;
    final watch = Stopwatch()..start();
    try {
      final html = await _getHtmlOnce(url, timeout: timeout);
      MirrorRanker.instance.onFetchOutcome(
        SourceCatalog.huangguo.id,
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
        SourceCatalog.huangguo.id,
        base,
        ok: false,
        ms: watch.elapsedMilliseconds,
      );
      rethrow;
    }
  }

  Future<String> _getHtmlOnce(String url, {Duration? timeout}) async {
    final token = CancelToken();
    // Cascade the instance-level cancel (page exit / tab switch).
    if (!_cancelToken.isCancelled) {
      // ignore: discarded_futures
      _cancelToken.whenCancel.then((_) {
        if (!token.isCancelled) token.cancel();
      });
    }
    final origin = _originOf(url);
    final Response<String> res;
    try {
      res = await _dio
          .get<String>(
            url,
            cancelToken: token,
            options: Options(
              responseType: ResponseType.plain,
              headers: {
                ...AppHttpHeaders.browser,
                'Referer': origin == null ? '$url/' : '$origin/',
                'Origin': origin ?? base,
                'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
              },
              validateStatus: (s) => s != null && s < 500,
            ),
          )
          .timeout(timeout ?? _singleRequestTimeout);
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
      throw PhubException('页面不存在 (404)，可能域名已变更');
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

  /// 黄果频道 → 列表页路径（tagId: duanju/manju/huanlian/mogai/rank/recommend/topics）。
  /// 首页/排行/专题无分页：翻页时直接退回短剧列表，避免重复同一页。
  String _listUrlFor(String tagId, int page) {
    final p = page < 1 ? 1 : page;
    return switch (tagId) {
      'duanju' => '$base/ai-duanju/${p > 1 ? '$p/' : ''}',
      'manju' => '$base/ai-manju/${p > 1 ? '$p/' : ''}',
      'huanlian' => '$base/ai-huanlian/${p > 1 ? '$p/' : ''}',
      'mogai' => '$base/ai-mogai/${p > 1 ? '$p/' : ''}',
      'rank' => p > 1 ? '$base/ai-duanju/$p/' : '$base/ranks/hot/',
      'topics' => p > 1 ? '$base/ai-duanju/$p/' : '$base/topics/',
      _ => '$base/${p > 1 ? 'ai-duanju/$p/' : ''}',
    };
  }

  /// Feed list for a channel tag.
  Future<List<VideoItem>> fetchFeed({
    String tagId = 'duanju',
    int page = 1,
    int limit = 40,
    Set<String>? exclude,
  }) async {
    if (tagId == 'topics') {
      // 专题首页是 hg-topic-card，无分页；直接返回专题列表。
      if (page > 1) return [];
      final html = await _getHtml(_listUrlFor(tagId, page));
      final topics = _parseTopicCards(html);
      if (topics.isNotEmpty) return topics;
    }
    final seen = <String>{...?exclude};
    final url = _listUrlFor(tagId, page);
    List<VideoItem> capped(List<VideoItem> items) =>
        items.length > limit ? items.sublist(0, limit) : items;
    try {
      final html = await _getHtml(url);
      return capped(_parseList(html, seen));
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) rethrow;
      // 首页/排行/专题无分页，翻页时退回短剧列表，避免空翻页。
      if (page > 1 && tagId != 'duanju' && tagId != 'manju' &&
          tagId != 'huanlian' && tagId != 'mogai') {
        try {
          final html = await _getHtml(
            '$base/ai-duanju/${page > 1 ? '$page/' : ''}',
          );
          return capped(_parseList(html, seen));
        } catch (e) {
          if (e is DioException && CancelToken.isCancel(e)) rethrow;
        }
      }
      rethrow;
    }
  }

  /// Site search（中文关键词原样保留）。
  Future<List<VideoItem>> search(String query, {int page = 1}) async {
    final q = Uri.encodeComponent(query.trim());
    if (q.isEmpty) return [];
    final url = '$base/search/video/$q/';
    try {
      final html = await _getHtml(url);
      return _parseList(html, <String>{});
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) rethrow;
      final alt = '$base/search/?keyword=$q';
      final html = await _getHtml(alt);
      return _parseList(html, <String>{});
    }
  }

  List<VideoItem> _parseList(String html, Set<String> seen) {
    // 频道页只取当前激活面板（第一个网格），避免串入热播/随机等面板内容。
    if (html.contains('hg-channel-page')) {
      final grids = RegExp(r'<div class="hg-card-grid[^"]*"')
          .allMatches(html)
          .toList();
      if (grids.isNotEmpty) {
        final gStart = grids.first.start;
        final gEnd = grids.length > 1 ? grids[1].start : html.length;
        final items = _parseCardGrid(html.substring(gStart, gEnd), seen);
        if (items.isNotEmpty) return items;
      }
      return _parseListLegacy(html, seen);
    }
    // 首页 / 排行榜 / 搜索结果：整页收集（data-track-* 同时覆盖剧卡与榜单条目）。
    final items = _parsePageCards(html, seen);
    if (items.isNotEmpty) return items;
    return _parseListLegacy(html, seen);
  }

  /// 整页收集卡片：hg-drama-card 与 hg-rank-item 都带 data-track-id/title，
  /// 另外补首页“为你推荐”的分类条目（hg-category-item）。
  List<VideoItem> _parsePageCards(String html, Set<String> seen) {
    final out = <VideoItem>[];
    final tracks = RegExp(
      r'''data-track-id="(\d+)"[^>]*data-track-title="([^"]*)"''',
    ).allMatches(html).toList();
    for (var i = 0; i < tracks.length; i++) {
      final start = tracks[i].start;
      final end = i + 1 < tracks.length
          ? tracks[i + 1].start
          : (start + 2400).clamp(start, html.length);
      // Sparse pages (big promo blocks between cards) must not drop the card:
      // cap the context instead of skipping it.
      final ctx = html.substring(
        start,
        end > start + 2400 ? start + 2400 : end,
      );
      final id = tracks[i].group(1)!;
      if (!seen.add(id)) continue;
      final title = _cleanTitle(tracks[i].group(2)!);
      if (title.length < 2) continue;

      String? thumb;
      for (final im in RegExp(
        r'''(?:data-src|src|data-original)\s*=\s*["']([^"']+\.(?:jpg|jpeg|png|webp)[^"']*)["']''',
        caseSensitive: false,
      ).allMatches(ctx)) {
        final t = im.group(1)!.replaceAll(r'\/', '/');
        if (t.contains('cover-placeholder')) continue;
        thumb = t;
        break;
      }
      final score = RegExp(
        r'''hg-drama-card__score[^>]*>\s*([^<]{1,40})<''',
      ).firstMatch(ctx)?.group(1)?.trim();
      final badge = RegExp(
        r'''hg-drama-card__episode[^>]*>\s*([^<]{1,40})<''',
      ).firstMatch(ctx)?.group(1)?.trim();

      out.add(VideoItem(
        url: '$base/detail/$id/',
        title: title,
        duration: '-',
        thumb: thumb == null ? null : _abs(thumb),
        score: score,
        badge: badge,
      ));
    }

    // 首页“为你推荐”分类条目。
    final catRe = RegExp(
      r'''<a class="hg-category-item" href="/detail/(\d+)/"[\s\S]*?</a>''',
    );
    for (final m in catRe.allMatches(html)) {
      final id = m.group(1)!;
      if (!seen.add(id)) continue;
      final ctx = m.group(0)!;
      final title = _cleanTitle(
        RegExp(r'''hg-category-item__title">\s*([^<]{2,120})<''')
            .firstMatch(ctx)
            ?.group(1) ??
            '',
      );
      if (title.length < 2) continue;
      String? thumb;
      for (final im in RegExp(
        r'''(?:data-src|src|data-original)\s*=\s*["']([^"']+\.(?:jpg|jpeg|png|webp)[^"']*)["']''',
        caseSensitive: false,
      ).allMatches(ctx)) {
        final t = im.group(1)!.replaceAll(r'\/', '/');
        if (t.contains('cover-placeholder')) continue;
        thumb = t;
        break;
      }
      out.add(VideoItem(
        url: '$base/detail/$id/',
        title: title,
        duration: '-',
        thumb: thumb == null ? null : _abs(thumb),
      ));
    }
    return out;
  }

  /// 解析单个卡片网格里的 hg-drama-card（data-track-id/title + 卡片内封面/角标）。
  List<VideoItem> _parseCardGrid(String seg, Set<String> seen) {
    final out = <VideoItem>[];
    final cards = RegExp(r'<div class="hg-drama-card"[^>]*>')
        .allMatches(seg)
        .toList();
    for (var i = 0; i < cards.length; i++) {
      final start = cards[i].start;
      final end = i + 1 < cards.length
          ? cards[i + 1].start
          : (start + 2400).clamp(start, seg.length);
      // Cap, don't skip: sparse grids must not drop cards.
      final ctx = seg.substring(
        start,
        end > start + 2400 ? start + 2400 : end,
      );
      final idm = RegExp(r'data-track-id="(\d+)"').firstMatch(ctx);
      if (idm == null) continue;
      final id = idm.group(1)!;
      if (!seen.add(id)) continue;
      var title = _cleanTitle(
        RegExp(r'data-track-title="([^"]*)"').firstMatch(ctx)?.group(1) ?? '',
      );
      if (title.length < 2) {
        final tm = RegExp(
          r'''hg-drama-card__title"[^>]*>\s*<a[^>]*>\s*([^<]{2,120})''',
        ).firstMatch(ctx);
        if (tm != null) title = _cleanTitle(tm.group(1)!);
      }
      if (title.length < 2) continue;

      String? thumb;
      for (final im in RegExp(
        r'''(?:data-src|src|data-original)\s*=\s*["']([^"']+\.(?:jpg|jpeg|png|webp)[^"']*)["']''',
        caseSensitive: false,
      ).allMatches(ctx)) {
        final t = im.group(1)!.replaceAll(r'\/', '/');
        if (t.contains('cover-placeholder')) continue;
        thumb = t;
        break;
      }
      final score = RegExp(
        r'''hg-drama-card__score[^>]*>\s*([^<]{1,40})<''',
      ).firstMatch(ctx)?.group(1)?.trim();
      final badge = RegExp(
        r'''hg-drama-card__episode[^>]*>\s*([^<]{1,40})<''',
      ).firstMatch(ctx)?.group(1)?.trim();

      out.add(VideoItem(
        url: '$base/detail/$id/',
        title: title,
        duration: '-',
        thumb: thumb == null ? null : _abs(thumb),
        score: score,
        badge: badge,
      ));
    }
    return out;
  }

  /// 专题首页（/topics/）：hg-topic-card 列表。
  List<VideoItem> _parseTopicCards(String html) {
    final out = <VideoItem>[];
    final cardRe = RegExp(r'''<a class="hg-topic-card" href="([^"]+)"[\s\S]*?</a>''');
    for (final m in cardRe.allMatches(html)) {
      final ctx = m.group(0)!;
      final href = m.group(1)!.replaceAll(r'\/', '/');
      final title = _cleanTitle(
        RegExp(r'''hg-topic-card__title">\s*([^<]{2,120})<''')
            .firstMatch(ctx)
            ?.group(1) ??
            '',
      );
      if (title.length < 2) continue;
      String? thumb;
      for (final im in RegExp(
        r'''(?:data-src|src|data-original)\s*=\s*["']([^"']+\.(?:jpg|jpeg|png|webp)[^"']*)["']''',
        caseSensitive: false,
      ).allMatches(ctx)) {
        final t = im.group(1)!.replaceAll(r'\/', '/');
        if (t.contains('cover-placeholder')) continue;
        thumb = t;
        break;
      }
      out.add(VideoItem(
        url: _abs(href),
        title: title,
        duration: '-',
        thumb: thumb == null ? null : _abs(thumb),
      ));
    }
    return out;
  }

  /// 专题列表页（/topics/slug/），结构与频道页一致：卡片网格 + 分页。
  Future<List<VideoItem>> fetchTopicList(String path, {int page = 1}) async {
    var url = path.startsWith('http://') || path.startsWith('https://')
        ? path
        : '$base$path';
    if (page > 1) url = url.replaceFirst(RegExp(r'/$'), '/$page/');
    final html = await _getHtml(url);
    return _parseList(html, <String>{});
  }

  List<VideoItem> _parseListLegacy(String html, Set<String> seen) {
    // 1) HTML 卡片元信息：封面 / 评分 / 集数徽标（按 detail id 缓存）。
    final thumbs = <String, String>{};
    final scores = <String, String>{};
    final badges = <String, String>{};
    final hrefRe = RegExp(r'''href\s*=\s*["'](/detail/(\d+)/?)["']''');
    for (final m in hrefRe.allMatches(html)) {
      final id = m.group(2)!;
      if (thumbs.containsKey(id) &&
          scores.containsKey(id) &&
          badges.containsKey(id)) {
        continue;
      }
      final idx = m.start;
      final start = idx > 700 ? idx - 700 : 0;
      final end = (idx + 700).clamp(0, html.length);
      final ctx = html.substring(start, end);
      if (!thumbs.containsKey(id)) {
        for (final im in RegExp(
          r'''(?:data-src|src|data-original)\s*=\s*["']([^"']+\.(?:jpg|jpeg|png|webp)[^"']*)["']''',
          caseSensitive: false,
        ).allMatches(ctx)) {
          final th = im.group(1)!.replaceAll(r'\/', '/');
          if (th.contains('cover-placeholder')) continue;
          thumbs[id] = th;
          break;
        }
      }
      if (!scores.containsKey(id)) {
        final sm = RegExp(
          r'''hg-drama-card__score[^>]*>\s*([^<]{1,40})<''',
        ).firstMatch(ctx);
        if (sm != null) scores[id] = sm.group(1)!.trim();
      }
      if (!badges.containsKey(id)) {
        final bm = RegExp(
          r'''hg-drama-card__episode[^>]*>\s*([^<]{1,40})<''',
        ).firstMatch(ctx);
        if (bm != null) badges[id] = bm.group(1)!.trim();
      }
    }

    final out = <VideoItem>[];
    void addItem(String id, String name) {
      if (!seen.add(id)) return;
      out.add(VideoItem(
        url: '$base/detail/$id/',
        title: name,
        duration: '-',
        thumb: thumbs[id] == null ? null : _abs(thumbs[id]!),
        score: scores[id],
        badge: badges[id],
      ));
    }

    // 2) 标题/链接优先走 JSON-LD ItemList（name + url 成对，最干净）。
    final ld = RegExp(
      r'"itemListElement"\s*:\s*\[([\s\S]*?)\]',
    ).firstMatch(html);
    if (ld != null) {
      for (final m in RegExp(
        r'''\{"@type"\s*:\s*"ListItem"[^{}]*?"name"\s*:\s*"([^"]+)"[^{}]*?"url"\s*:\s*"([^"]+)"''',
        caseSensitive: false,
      ).allMatches(ld.group(1)!)) {
        final name = _cleanTitle(m.group(1)!);
        final href = m.group(2)!.replaceAll(r'\/', '/');
        final idm = RegExp(r'/(?:detail|video)/(\d+)').firstMatch(href);
        if (idm == null || name.length < 2) continue;
        addItem(idm.group(1)!, name);
      }
      if (out.isNotEmpty) return out;
    }

    // 3) HTML 卡片兜底：/detail/ID/ 链接 + 附近 title/alt/data-src。
    final titles = <String, String>{};
    for (final m in hrefRe.allMatches(html)) {
      final id = m.group(2)!;
      final idx = m.start;
      final start = idx > 700 ? idx - 700 : 0;
      final end = (idx + 500).clamp(0, html.length);
      final ctx = html.substring(start, end);

      String? bestTitle;
      var bestScore = -1;
      for (final t in RegExp(
        r'''(?:title|alt)\s*=\s*["']([^"']{2,200})["']''',
        caseSensitive: false,
      ).allMatches(ctx)) {
        final t2 = _cleanTitle(t.group(1)!);
        if (!_isGoodTitle(t2)) continue;
        final s = _titleScore(t2);
        if (s > bestScore) {
          bestScore = s;
          bestTitle = t2;
        }
      }
      if (bestTitle == null) {
        for (final t in RegExp(
          r'>\s*([^<>]{4,120})\s*<',
        ).allMatches(ctx)) {
          final t2 = _cleanTitle(t.group(1)!);
          if (!_isGoodTitle(t2) || _isNavNoise(t2)) continue;
          final s = _titleScore(t2);
          if (s > bestScore) {
            bestScore = s;
            bestTitle = t2;
          }
        }
      }
      if (bestTitle != null && !titles.containsKey(id)) {
        titles[id] = bestTitle;
      }
    }
    for (final id in titles.keys) {
      addItem(id, titles[id]!);
    }
    return out;
  }

  Future<VideoDetail> getVideoDetail(String url) async {
    var pageUrl = url;
    String html;
    try {
      html = await _getHtml(pageUrl, timeout: _singleRequestTimeout);
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) rethrow;
      // 卡片通常指到 /detail/ID/，直接换 /video/ID/ 更可靠。
      final idm = RegExp(r'/(?:detail|video)/(\d+)').firstMatch(url);
      if (idm != null) {
        pageUrl = '$base/video/${idm.group(1)}/';
        html = await _getHtml(pageUrl);
      } else {
        rethrow;
      }
    }

    var data = _videoData(html);
    if (data == null) {
      final idm = RegExp(r'/(?:detail|video)/(\d+)').firstMatch(pageUrl);
      if (idm != null) {
        pageUrl = '$base/video/${idm.group(1)}/';
        html = await _getHtml(pageUrl);
        data = _videoData(html);
      }
    }
    if (data == null) {
      throw PhubException('无法解析播放数据（页面结构可能已改版）');
    }

    var videoSrc = (data['videoSrc'] ?? '').toString().trim();
    final epPlaySrcs = data['epPlaySrcs'];
    final eps = <String>[];
    if (epPlaySrcs is Map) {
      final entries = epPlaySrcs.entries.toList()
        ..sort((a, b) => _epNum(a.key).compareTo(_epNum(b.key)));
      for (final e in entries) {
        final v = e.value.toString().trim();
        if (v.isNotEmpty && !eps.contains(v)) eps.add(v);
      }
    }
    if (videoSrc.isEmpty && eps.isNotEmpty) videoSrc = eps.first;
    if (videoSrc.isEmpty) {
      throw PhubException('播放地址为空');
    }
    videoSrc = _abs(videoSrc).replaceAll('&amp;', '&');

    final title = (data['title'] ?? '').toString().trim();
    final cover = (data['coverSrc'] ?? data['posterSrc'] ?? '').toString();
    final desc = (data['description'] ?? '').toString().trim();

    // 缓存整部剧的集列表：连续翻页播放 1,2,3…N 集。
    // 站点每页只内嵌“当前+下一集”的直链（epPlaySrcs ≈ 2 条），整剧集数取自
    // 选集链接（data-ep-id 与 /video/{id}/ep-N/）。补齐 N 集；缺直链的集
    // 各自动抓 /video/{id}/ep-N/ 详情页取真实播放地址。
    final seriesKey = url;
    _episodesCache.remove(seriesKey);
    final idm = RegExp(r'/(?:detail|video)/(\d+)').firstMatch(pageUrl);
    final seriesId = idm?.group(1);
    var total = eps.length;
    if (seriesId != null) {
      final n = _maxEpisodeFromHtml(html);
      if (n > total) total = n;
    }
    if (total < 1) total = 1;
    final epByNum = <int, String>{};
    if (epPlaySrcs is Map) {
      for (final e in epPlaySrcs.entries) {
        final v = e.value.toString().trim();
        if (v.isNotEmpty) epByNum[_epNum(e.key)] = _abs(v);
      }
    }
    final episodeItems = <VideoItem>[];
    final seriesTitle = title.isEmpty ? pageUrl : title;
    for (var i = 1; i <= total; i++) {
      final episodeUrl = seriesId == null
          ? seriesKey
          : '$base/video/$seriesId/${i > 1 ? 'ep-$i/' : ''}';
      final directUrl = epByNum[i];
      episodeItems.add(VideoItem(
        url: episodeUrl,
        title: '$seriesTitle 第$i集',
        duration: '-',
        thumb: cover.isNotEmpty ? _abs(cover) : null,
        episode: i,
        episodeTotal: total,
        directUrl: directUrl?.replaceAll('&amp;', '&'),
      ));
    }
    if (episodeItems.isNotEmpty) {
      _episodesCache[seriesKey] = List<VideoItem>.unmodifiable(episodeItems);
    }

    var durationSec = 0;
    if (videoSrc.toLowerCase().contains('.m3u8')) {
      durationSec = await _durationFromM3u8(videoSrc, pageUrl);
    }

    return VideoDetail(
      url: pageUrl,
      title: title.isEmpty ? pageUrl : title,
      description: desc.isEmpty ? null : desc,
      durationSec: durationSec,
      thumb: cover.isNotEmpty ? _abs(cover) : null,
      streams: [
        StreamQuality(
          width: 1280,
          height: 720,
          url: videoSrc,
          referer: pageUrl,
        ),
      ],
    );
  }

  /// 提取 <script id="videoInitialData"> 里的 JSON。
  Map<String, dynamic>? _videoData(String html) {
    final m = RegExp(
      r'''<script[^>]*id\s*=\s*["']videoInitialData["'][^>]*>([\s\S]*?)</script>''',
      caseSensitive: false,
    ).firstMatch(html);
    if (m == null) return null;
    try {
      final decoded = jsonDecode(m.group(1)!.trim());
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {}
    return null;
  }

  /// Sum EXTINF so the UI gets a seek bar for HLS short dramas.
  Future<int> _durationFromM3u8(String playUrl, String pageUrl) async {
    try {
      final res = await _dio.get<String>(
        playUrl,
        options: Options(
          responseType: ResponseType.plain,
          headers: {
            ...AppHttpHeaders.forMediaUrl(playUrl, pageUrl: pageUrl),
            'Accept': 'application/vnd.apple.mpegurl,application/x-mpegURL,*/*',
          },
          receiveTimeout: const Duration(seconds: 12),
        ),
      );
      final body = res.data ?? '';
      if (body.contains('#EXT-X-STREAM-INF')) {
        // Master playlist: follow best variant once.
        final lines = body.split(RegExp(r'\r?\n'));
        String? next;
        var bestBw = -1;
        for (var i = 0; i < lines.length; i++) {
          if (!lines[i].trim().startsWith('#EXT-X-STREAM-INF')) continue;
          final bw = int.tryParse(
                  RegExp(r'BANDWIDTH=(\d+)')
                      .firstMatch(lines[i].trim())
                      ?.group(1) ??
                      '') ??
              0;
          if (i + 1 >= lines.length) continue;
          var candidate = lines[i + 1].trim();
          if (candidate.isEmpty || candidate.startsWith('#')) continue;
          if (bw >= bestBw) {
            bestBw = bw;
            next = candidate;
          }
        }
        if (next == null) return 0;
        final resolved = await _dio.get<String>(
          _absUrl(playUrl, next),
          options: Options(
            responseType: ResponseType.plain,
            headers: {
              ...AppHttpHeaders.forMediaUrl(playUrl, pageUrl: pageUrl),
              'Accept':
                  'application/vnd.apple.mpegurl,application/x-mpegURL,*/*',
            },
            receiveTimeout: const Duration(seconds: 12),
          ),
        );
        var total = 0.0;
        for (final m in RegExp(r'#EXTINF:([\d.]+)')
            .allMatches(resolved.data ?? '')) {
          total += double.tryParse(m.group(1)!) ?? 0;
        }
        return total >= 1 ? total.round() : 0;
      }
      var total = 0.0;
      for (final m in RegExp(r'#EXTINF:([\d.]+)').allMatches(body)) {
        total += double.tryParse(m.group(1)!) ?? 0;
      }
      return total >= 1 ? total.round() : 0;
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) rethrow;
      return 0;
    }
  }

  /// 无法解析为数字的集数 key（如 "hd"、"1080p"）按出现顺序给稳定递增编号，
  /// 使排序与合并两处对同一 key 的取值一致（不再全部折叠成 0 互相覆盖）。
  final Map<String, int> _epNumCache = {};
  int _unparsedEpCounter = 0;

  int _epNum(dynamic key) {
    final s = '$key';
    final cached = _epNumCache[s];
    if (cached != null) return cached;
    final n = int.tryParse(s);
    final result = (n != null && n >= 0)
        ? n
        : (n != null ? max(0, -1 - n) : _unparsedEpCounter++);
    _epNumCache[s] = result;
    return result;
  }

  /// 从视频页/选集 DOM 推断整剧集数（data-ep-id 与 /video/{id}/ep-N/ 链接）。
  int _maxEpisodeFromHtml(String html) {
    var maxEp = 0;
    for (final m in RegExp(r'''data-ep-id="(\d+)"''').allMatches(html)) {
      final n = int.tryParse(m.group(1)!);
      if (n != null && n > maxEp) maxEp = n;
    }
    for (final m in RegExp(
      r'''/video/\d+/ep-(\d+)/?''',
      caseSensitive: false,
    ).allMatches(html)) {
      final n = int.tryParse(m.group(1)!);
      if (n != null && n > maxEp) maxEp = n;
    }
    return maxEp;
  }

  String _abs(String path) {
    var p = path.trim().replaceAll(r'\/', '/');
    if (p.startsWith('http://') || p.startsWith('https://')) return p;
    if (p.startsWith('//')) return 'https:$p';
    if (!p.startsWith('/')) p = '/$p';
    return '$base$p';
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

  String? _originOf(String url) {
    final u = Uri.tryParse(url);
    if (u == null || u.host.isEmpty) return null;
    return u.origin;
  }

  String _cleanTitle(String t) => t
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&amp;', '&')
      .replaceAll('&#039;', "'")
      .replaceAll('&quot;', '"')
      .replaceAll('&nbsp;', ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  bool _isGoodTitle(String t) => t.length >= 2 && t.length <= 200;

  int _titleScore(String t) {
    var s = t.length;
    if (RegExp(r'[\u4e00-\u9fff]').hasMatch(t)) s += 20;
    return s;
  }

  bool _isNavNoise(String t) {
    const noise = ['首页', '排行', '专题', '上一页', '下一页', '更多'];
    for (final n in noise) {
      if (t == n) return true;
    }
    return false;
  }
}

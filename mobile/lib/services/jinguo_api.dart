import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';

import '../models/video_item.dart';
import '../utils/http_client.dart';
import '../utils/http_headers.dart';
import 'mirror_ranker.dart';
import 'scrape_exception.dart';
import 'short_drama_api.dart';
import 'source_catalog.dart';

/// 禁果短剧 (jinguodj.tv) — 内置规则适配器。
///
/// 与黄果短剧共用 [HuangGuoWebPage] 的卡片网格页，但站点结构不同：
///  - 首页:      /
///  - 频道:      /ai-short/page/N、/ai-series/page/N、/rank/page/N
///  - 搜索:      /search/{关键词}、/search/{关键词}/page/N
///  - 详情:      /detail/{slug}，选集锚点 .detail-episode
///               免费集 href=/play/{slug}/{chapterId}
///               付费集 data-chapter-id={chapterId}
///  - 播放数据:  GET /api/playlet/chapter/detail?chapterId=...
///               → data.videoUrl（相对 m3u8）→ 同域 /api/h5/m3u8/ 代理
/// 付费集 videoUrl 为空且 needUnlock=true，交给 App WebView 兜底。
class JinGuoApi implements ShortDramaApi {
  static const String defaultBase = 'https://jinguodj.tv';

  static const _singleRequestTimeout = Duration(seconds: 12);

  JinGuoApi({Dio? dio, CancelToken? cancelToken})
      : _cancelToken = cancelToken ?? CancelToken(),
        _dio = dio ?? AppHttpClient.create() {
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          options.cancelToken ??= _cancelToken;
          handler.next(options);
        },
      ),
    );
  }

  final Dio _dio;
  CancelToken _cancelToken;

  /// 整剧选集缓存：series key → 各集 VideoItem。
  final Map<String, List<VideoItem>> _episodesCache = {};

  /// 剧集章节号缓存：series key → 各集 chapterId（播放接口需要）。
  final Map<String, List<_EpisodeEntry>> _entryCache = {};

  /// 剧集元信息缓存：series key → 标题/封面/简介。
  final Map<String, _SeriesMeta> _metaCache = {};

  static const _maxSeriesCache = 40;

  String get base =>
      MirrorRanker.instance.preferredBase(SourceCatalog.jinguodj);

  @override
  List<VideoItem>? episodesFor(String url) =>
      _episodesCache[_seriesKeyFor(url)];

  @override
  void cancelRequests([String reason = 'cancelled']) {
    final token = _cancelToken;
    _cancelToken = CancelToken();
    if (!token.isCancelled) token.cancel(reason);
  }

  Future<String> _getHtml(String url, {Duration? timeout}) async {
    final origin = _originOf(url) ?? base;
    final watch = Stopwatch()..start();
    try {
      final html = await _getHtmlOnce(url, timeout: timeout);
      MirrorRanker.instance.onFetchOutcome(
        SourceCatalog.jinguodj.id,
        origin,
        ok: true,
        ms: watch.elapsedMilliseconds,
      );
      return html;
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) rethrow;
      MirrorRanker.instance.onFetchOutcome(
        SourceCatalog.jinguodj.id,
        origin,
        ok: false,
        ms: watch.elapsedMilliseconds,
      );
      rethrow;
    }
  }

  Future<String> _getHtmlOnce(String url, {Duration? timeout}) async {
    final token = CancelToken();
    if (_cancelToken.isCancelled) {
      token.cancel();
    } else {
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

  String _listUrlFor(String tagId, int page) {
    final p = page < 1 ? 1 : page;
    final suffix = p > 1 ? '/page/$p' : '';
    return switch (tagId) {
      'short' => '$base/ai-short$suffix',
      'series' => '$base/ai-series$suffix',
      'rank' => '$base/rank$suffix',
      _ => '$base/',
    };
  }

  @override
  Future<List<VideoItem>> fetchFeed({
    String tagId = 'short',
    int page = 1,
    int limit = 40,
    Set<String>? exclude,
  }) async {
    // 首页无分页：继续下滑时直接结束，不要反复请求同一页。
    if (tagId == 'hot' && page > 1) return [];
    final html = await _getHtml(_listUrlFor(tagId, page));
    final items = _parseCards(html, <String>{...?exclude});
    return items.length > limit ? items.sublist(0, limit) : items;
  }

  @override
  Future<List<VideoItem>> search(String query, {int page = 1}) async {
    final q = Uri.encodeComponent(query.trim());
    if (q.isEmpty) return [];
    final p = page < 1 ? 1 : page;
    final url = '$base/search/$q${p > 1 ? '/page/$p' : ''}';
    try {
      final html = await _getHtml(url);
      return _parseCards(html, <String>{});
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) rethrow;
      final alt = '$base/search?q=$q${p > 1 ? '&page=$p' : ''}';
      final html = await _getHtml(alt);
      return _parseCards(html, <String>{});
    }
  }

  @override
  Future<List<VideoItem>> fetchTopicList(String path, {int page = 1}) async {
    var url = path.startsWith('http://') || path.startsWith('https://')
        ? path
        : '$base$path';
    if (page > 1) {
      url = '${url.replaceFirst(RegExp(r'/$'), '')}/page/$page';
    }
    final html = await _getHtml(url);
    return _parseCards(html, <String>{});
  }

  /// 列表页/首页/搜索页统一卡片解析。
  ///
  /// 首页卡片 .card / .editorial-card / .category-playlist-card 以及频道页
  /// .poster-card 都是 <a href="/detail/{slug}">，内部字段基本一致。
  List<VideoItem> _parseCards(String html, Set<String> seen) {
    final out = <VideoItem>[];
    final anchorRe = RegExp(
      r'<a\b([^>]*)>([\s\S]*?)</a>',
      caseSensitive: false,
    );
    for (final m in anchorRe.allMatches(html)) {
      final attrs = m.group(1)!;
      final inner = m.group(2)!;
      final href = RegExp(
        r'''href\s*=\s*["'](/detail/[^"'?#]+)''',
        caseSensitive: false,
      ).firstMatch(attrs)?.group(1);
      if (href == null) continue;
      final cls = RegExp(
        r'''class\s*=\s*["']([^"']*)''',
        caseSensitive: false,
      ).firstMatch(attrs)?.group(1) ??
          '';
      final isCard = cls.contains('poster-card') ||
          cls.contains('drama-data-card') ||
          cls.contains('jgdj-slide');
      if (!isCard) continue;
      final slug = _slugFromPath(href);
      if (slug == null || !seen.add(slug)) continue;

      final title = _cardTitle(attrs, inner);
      if (title.length < 2) continue;

      out.add(VideoItem(
        url: '$base/detail/$slug',
        title: title,
        duration: '-',
        thumb: _cardThumb(inner),
        badge: _cardBadge(inner),
      ));
    }
    return out;
  }

  String _cardTitle(String attrs, String inner) {
    for (final re in <RegExp>[
      RegExp(
        r'''class\s*=\s*["'][^"']*poster-card-title[^"']*["'][^>]*>([\s\S]*?)</div>''',
        caseSensitive: false,
      ),
      RegExp(
        r'''class\s*=\s*["'][^"']*drama-title[^"']*["'][^>]*>([\s\S]*?)</(?:strong|span|div|h3)>''',
        caseSensitive: false,
      ),
      RegExp(r'<h3[^>]*>([\s\S]*?)</h3>', caseSensitive: false),
      RegExp(r'<h2[^>]*>([\s\S]*?)</h2>', caseSensitive: false),
    ]) {
      final t = _stripEpisodeSuffix(
        _cleanTitle(re.firstMatch(inner)?.group(1) ?? ''),
      );
      if (t.length >= 2) return t;
    }
    final aria = RegExp(
      r'''aria-label\s*=\s*["']([^"']{2,200})["']''',
      caseSensitive: false,
    ).firstMatch(attrs)?.group(1);
    if (aria != null) {
      final t = _stripEpisodeSuffix(
        _cleanTitle(aria)
            .replaceFirst(RegExp(r'^查看'), '')
            .replaceFirst(RegExp(r'详情$'), '')
            .trim(),
      );
      if (t.length >= 2) return t;
    }
    final alt = RegExp(
      r'''\balt\s*=\s*["']([^"']{2,200})["']''',
      caseSensitive: false,
    ).firstMatch(inner)?.group(1);
    return _stripEpisodeSuffix(_cleanTitle(alt ?? ''));
  }

  /// 卡片标题常带「（全2集）」/「更新至8集」/「全1集」等集数后缀，
  /// 与详情页标题拼接后会变成「剧名（全2集） 第1集」，这里统一去掉。
  String _stripEpisodeSuffix(String title) => title
      .replaceFirst(
        RegExp(r'\s*[（(]\s*(?:全|更新至?)\s*\d+\s*集\s*[）)]\s*$'),
        '',
      )
      .replaceFirst(RegExp(r'\s+(?:全|更新至)\s*\d+\s*集\s*$'), '')
      .trim();

  String? _cardThumb(String inner) {
    for (final im in RegExp(r'<img\b[^>]*>', caseSensitive: false)
        .allMatches(inner)) {
      final tag = im.group(0)!;
      final candidates = <String?>[
        RegExp(r'''data-src\s*=\s*["']([^"']+)["']''', caseSensitive: false)
            .firstMatch(tag)
            ?.group(1),
        RegExp(r'''\bsrc\s*=\s*["']([^"']+)["']''', caseSensitive: false)
            .firstMatch(tag)
            ?.group(1),
      ];
      for (final c in candidates) {
        if (c == null || c.isEmpty) continue;
        final u = _decode(c);
        if (u.contains('placeholder') || u.contains('cover-placeholder')) {
          continue;
        }
        return _abs(u);
      }
    }
    return null;
  }

  String? _cardBadge(String inner) {
    final idx = inner.indexOf('episode-badge');
    final idx2 = inner.indexOf('drama-episodes');
    final start = idx >= 0 ? idx : idx2;
    if (start < 0) return null;
    final end = min(inner.length, start + 320);
    final text = _cleanTitle(inner.substring(start, end));
    final m = RegExp(r'(?:全\s*)?\d+\s*集|更新至\s*\d+\s*集').firstMatch(text);
    return m?.group(0)?.replaceAll(RegExp(r'\s+'), '');
  }

  @override
  Future<VideoDetail> getVideoDetail(String url) async {
    final slug = _slugFromUrl(url);
    if (slug == null) {
      throw PhubException('无法识别的禁果剧集地址');
    }
    final key = 'jg:$slug';
    final chapterFromUrl = _chapterFromUrl(url);
    var entries = _entryCache[key];
    var meta = _metaCache[key];
    String? detailHtml;

    // 直接进播放页且已有缓存时无需再拉详情页。
    if (entries == null || meta == null) {
      try {
        detailHtml = await _getHtml('$base/detail/$slug');
      } catch (e) {
        if (e is DioException && CancelToken.isCancel(e)) rethrow;
        // 详情页失败不致命：仍可尝试用 URL 里的 chapterId 直接取流。
      }
    }

    if (detailHtml != null) {
      final parsed = _parseEpisodes(detailHtml, slug);
      if (parsed.isNotEmpty) {
        entries = parsed;
        _entryCache[key] = parsed;
        _trim(_entryCache);
      }
      final parsedMeta = _parseDetailMeta(detailHtml, slug);
      if (parsedMeta != null) {
        meta = parsedMeta;
        _metaCache[key] = parsedMeta;
        _trim(_metaCache);
      }
    }

    entries ??= const <_EpisodeEntry>[];
    _EpisodeEntry? entry;
    if (chapterFromUrl != null) {
      for (final e in entries) {
        if (e.chapterId == chapterFromUrl) {
          entry = e;
          break;
        }
      }
      entry ??= _EpisodeEntry(1, chapterFromUrl, slug);
    } else if (entries.isNotEmpty) {
      entry = entries.first;
    }
    if (entry == null) {
      throw PhubException('未找到可播放剧集');
    }

    final playUrl = '$base/play/${entry.slug}/${entry.chapterId}';
    var title = meta?.title ?? '';
    String? thumb = meta?.thumb;
    String? description = meta?.description;

    if (title.isEmpty) {
      // 详情页不可用时以播放页元信息兜底。
      try {
        final playHtml = await _getHtml(playUrl);
        final m = _parseDetailMeta(playHtml, slug);
        if (m != null) {
          title = m.title;
          thumb = thumb ?? m.thumb;
          description = description ?? m.description;
        }
      } catch (e) {
        if (e is DioException && CancelToken.isCancel(e)) rethrow;
      }
    }
    if (title.isEmpty) title = slug;

    final episodeTotal =
        entries.isEmpty ? 1 : entries.map((e) => e.number).reduce(max);
    final seriesTitle = title;
    final episodeItems = <VideoItem>[];
    if (entries.isNotEmpty) {
      for (final e in entries) {
        episodeItems.add(VideoItem(
          url: '$base/play/${e.slug}/${e.chapterId}',
          title: '$seriesTitle 第${e.number}集',
          duration: '-',
          thumb: thumb,
          episode: e.number,
          episodeTotal: episodeTotal,
        ));
      }
      _episodesCache[key] = List<VideoItem>.unmodifiable(episodeItems);
      _trim(_episodesCache);
    }

    // 详情页已标 coin-dialog 的集直接走 WebView：既省一次注定失败的
    // 请求，也避开站点的短时风控（连续请求付费集后，同 IP 一段时间内
    // 连免费集也会被回 needUnlock）。
    final playback =
        entry.locked ? null : await _fetchChapter(entry.chapterId, playUrl);
    var durationSec = playback?.mediaTime ?? 0;
    if (durationSec <= 0 && meta != null) durationSec = meta.durationSec;

    if (playback == null || playback.url.isEmpty) {
      // 付费/未解锁集没有直链：交给现有 App WebView 播放兜底。
      return VideoDetail(
        url: playUrl,
        title: title,
        description: description,
        durationSec: durationSec,
        thumb: thumb,
        streams: const [],
        browserPlaybackUrl: playUrl,
      );
    }

    return VideoDetail(
      url: playUrl,
      title: title,
      description: description,
      durationSec: durationSec,
      thumb: thumb,
      streams: [
        StreamQuality(
          width: playback.width > 0 ? playback.width : 1280,
          height: playback.height > 0 ? playback.height : 720,
          url: playback.url,
          referer: playUrl,
        ),
      ],
    );
  }

  /// GET /api/playlet/chapter/detail?chapterId=... → 直链 m3u8。
  Future<_ChapterPlayback?> _fetchChapter(
    String chapterId,
    String pageUrl,
  ) async {
    final token = CancelToken();
    if (_cancelToken.isCancelled) {
      token.cancel();
    } else {
      // ignore: discarded_futures
      _cancelToken.whenCancel.then((_) {
        if (!token.isCancelled) token.cancel();
      });
    }
    final origin = _originOf(pageUrl) ?? base;
    final url = '$origin/api/playlet/chapter/detail'
        '?chapterId=$chapterId&_playbackRequest=${DateTime.now().millisecondsSinceEpoch}';
    try {
      final res = await _dio
          .get<String>(
            url,
            cancelToken: token,
            options: Options(
              responseType: ResponseType.plain,
              headers: {
                ...AppHttpHeaders.browser,
                'Accept': 'application/json, text/plain, */*',
                'Referer': pageUrl,
                'Origin': origin,
                'X-Requested-With': 'XMLHttpRequest',
              },
              validateStatus: (s) => s != null && s < 500,
            ),
          )
          .timeout(_singleRequestTimeout);
      if ((res.statusCode ?? 0) != 200 || (res.data ?? '').isEmpty) {
        return null;
      }
      final decoded = jsonDecode(res.data!);
      if (decoded is! Map) return null;
      final code = decoded['code'];
      if (code != 200 && code != 0 && code != 1) return null;
      final data = decoded['data'];
      if (data is! Map) return null;

      final raw = data['videoUrl']?.toString().trim() ?? '';
      final mediaTime = int.tryParse('${data['mediaTime'] ?? ''}') ?? 0;
      final width = int.tryParse('${data['width'] ?? ''}') ?? 0;
      final height = int.tryParse('${data['height'] ?? ''}') ?? 0;
      if (raw.isEmpty) {
        return _ChapterPlayback(
          url: '',
          mediaTime: mediaTime,
          width: width,
          height: height,
        );
      }
      return _ChapterPlayback(
        url: _resolveVideoUrl(raw, pageUrl),
        mediaTime: mediaTime,
        width: width,
        height: height,
      );
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) rethrow;
      return null;
    }
  }

  /// 相对 videoUrl（k12/.../file.m3u8?ticket=...）→ 同域 HLS 代理地址。
  String _resolveVideoUrl(String raw, String pageUrl) {
    var u = _decode(raw);
    if (u.startsWith('http://') || u.startsWith('https://')) return u;
    final origin = _originOf(pageUrl) ?? base;
    u = u.replaceFirst(RegExp(r'^/+'), '');
    if (u.startsWith('api/h5/m3u8/')) return '$origin/$u';
    if (u.startsWith('h5/m3u8/')) return '$origin/api/$u';
    return '$origin/api/h5/m3u8/$u';
  }

  List<_EpisodeEntry> _parseEpisodes(String html, String fallbackSlug) {
    final byEp = <int, _EpisodeEntry>{};
    final anchorRe = RegExp(
      r'''<a\b([^>]*class\s*=\s*["'][^"']*detail-episode[^"']*["'][^>]*)>''',
      caseSensitive: false,
    );
    for (final m in anchorRe.allMatches(html)) {
      final attrs = m.group(1)!;
      final ep = int.tryParse(
            RegExp(r'''data-ep\s*=\s*["'](\d+)''', caseSensitive: false)
                    .firstMatch(attrs)
                    ?.group(1) ??
                '',
          ) ??
          -1;
      if (ep <= 0) continue;
      var chapterId = RegExp(
        r'''data-chapter-id\s*=\s*["'](\d+)''',
        caseSensitive: false,
      ).firstMatch(attrs)?.group(1);
      chapterId ??= RegExp(
        r'''href\s*=\s*["']/play/[^/"']+/(\d+)''',
        caseSensitive: false,
      ).firstMatch(attrs)?.group(1);
      if (chapterId == null) continue;
      final slug = RegExp(
            r'''data-playlet-slug\s*=\s*["']([^"']+)''',
            caseSensitive: false,
          ).firstMatch(attrs)?.group(1) ??
          fallbackSlug;
      // 付费集锚点是 javascript:; + data-coin-dialog-open；免费集才是
      // 真实 /play/ href。
      final locked = attrs.contains('data-coin-dialog-open') ||
          attrs.contains('data-single-coins');
      byEp[ep] = _EpisodeEntry(ep, chapterId, slug, locked: locked);
    }

    if (byEp.isEmpty) {
      // 兜底：页面里可能只有免费集的 /play/ 链接。
      var i = 1;
      for (final m in RegExp(
        r'''href\s*=\s*["']/play/([^/"']+)/(\d+)''',
        caseSensitive: false,
      ).allMatches(html)) {
        final slug = m.group(1)!;
        if (slug != fallbackSlug) continue;
        byEp[i] = _EpisodeEntry(i, m.group(2)!, slug);
        i++;
      }
    }

    final entries = byEp.values.toList()
      ..sort((a, b) => a.number.compareTo(b.number));
    return entries;
  }

  _SeriesMeta? _parseDetailMeta(String html, String slug) {
    var title = '';
    final h1 = RegExp(r'<h1[^>]*>([\s\S]*?)</h1>', caseSensitive: false)
        .firstMatch(html);
    if (h1 != null) title = _stripEpisodeSuffix(_cleanTitle(h1.group(1)!));
    if (title.isEmpty) {
      final t = RegExp(r'<title[^>]*>([\s\S]*?)</title>', caseSensitive: false)
          .firstMatch(html);
      if (t != null) title = _stripEpisodeSuffix(_cleanTitle(t.group(1)!));
    }
    if (title.isEmpty) title = slug;

    final ogImage = _metaContent(html, 'og:image');
    final ogDesc = _metaContent(html, 'og:description');
    final desc = ogDesc ?? _metaContent(html, 'description');
    var durationSec = 0;
    final mv = RegExp(
      r'''data-media-time\s*=\s*["'](\d+)''',
      caseSensitive: false,
    ).firstMatch(html);
    if (mv != null) durationSec = int.tryParse(mv.group(1)!) ?? 0;

    return _SeriesMeta(
      title: title,
      thumb: ogImage == null ? null : _abs(_decode(ogImage)),
      description: _cleanDescription(desc),
      durationSec: durationSec,
    );
  }

  String? _metaContent(String html, String key) {
    final want = key.toLowerCase();
    for (final m in RegExp(r'<meta\b[^>]*>', caseSensitive: false)
        .allMatches(html)) {
      final tag = m.group(0)!;
      final k = RegExp(
        r'''(?:property|name)\s*=\s*["']([^"']+)["']''',
        caseSensitive: false,
      ).firstMatch(tag)?.group(1)?.toLowerCase();
      if (k != want) continue;
      return RegExp(
        r'''content\s*=\s*["']([^"']*)["']''',
        caseSensitive: false,
      ).firstMatch(tag)?.group(1);
    }
    return null;
  }

  String? _cleanDescription(String? raw) {
    var d = _cleanTitle(raw ?? '');
    d = d.replaceFirst(RegExp(r'\s*-\s*正在播放第\d+集\s*$'), '').trim();
    return d.isEmpty ? null : d;
  }

  String? _slugFromUrl(String url) {
    final m = RegExp(
      r'''/(?:detail|play)/([^/?#]+)''',
      caseSensitive: false,
    ).firstMatch(url);
    return m?.group(1);
  }

  String? _slugFromPath(String path) {
    final m = RegExp(r'''/detail/([^/?#]+)''', caseSensitive: false)
        .firstMatch(path);
    return m?.group(1);
  }

  String? _chapterFromUrl(String url) {
    final m = RegExp(
      r'''/play/[^/?#]+/(\d+)''',
      caseSensitive: false,
    ).firstMatch(url);
    return m?.group(1);
  }

  String _seriesKeyFor(String url) {
    final slug = _slugFromUrl(url);
    return slug == null ? url : 'jg:$slug';
  }

  void _trim(Map<String, dynamic> cache) {
    while (cache.length > _maxSeriesCache) {
      cache.remove(cache.keys.first);
    }
  }

  String _abs(String path) {
    var p = path.trim().replaceAll(r'\/', '/');
    if (p.startsWith('http://') || p.startsWith('https://')) return p;
    if (p.startsWith('//')) return 'https:$p';
    if (!p.startsWith('/')) p = '/$p';
    return '$base$p';
  }

  String? _originOf(String url) {
    final u = Uri.tryParse(url);
    if (u == null || u.host.isEmpty) return null;
    return u.origin;
  }

  String _decode(String s) => s
      .replaceAll(r'\/', '/')
      .replaceAll('&amp;', '&')
      .replaceAll('&#039;', "'")
      .replaceAll('&quot;', '"')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&#x27;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');

  String _cleanTitle(String t) => _decode(t)
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

class _EpisodeEntry {
  const _EpisodeEntry(
    this.number,
    this.chapterId,
    this.slug, {
    this.locked = false,
  });
  final int number;
  final String chapterId;
  final String slug;

  /// 详情页已标「金币解锁」：没有直链，直接走 WebView 兜底。
  final bool locked;
}

class _SeriesMeta {
  const _SeriesMeta({
    required this.title,
    this.thumb,
    this.description,
    this.durationSec = 0,
  });
  final String title;
  final String? thumb;
  final String? description;
  final int durationSec;
}

class _ChapterPlayback {
  const _ChapterPlayback({
    required this.url,
    required this.mediaTime,
    required this.width,
    required this.height,
  });
  final String url;
  final int mediaTime;
  final int width;
  final int height;
}

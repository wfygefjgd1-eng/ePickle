import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';
import 'package:pointycastle/api.dart';

import '../models/video_item.dart';
import '../utils/http_client.dart';
import '../utils/http_headers.dart';
import 'source_catalog.dart';

/// 站点"标签页"分类节点（a=types 返回的两级树）。
class LangmeiType {
  const LangmeiType({required this.id, required this.name, this.children = const []});
  final String id;
  final String name;
  final List<LangmeiType> children;
}

/// 浪妹/要发发两站的接入配置：同一套 Vue 模板（langmei/188），同一内容库，
/// 仅域名、API 前缀与 AES 密钥不同。
class LangmeiSiteConfig {
  const LangmeiSiteConfig({
    required this.entryBase,
    required this.apiBase,
    required this.keyMask,
    this.navRename = const {},
    this.navOrder = const [],
    this.navExclude = const {},
  });

  /// 页面入口（`/#/play/<id>`、`/get/play.php` 挂在这个域上）。
  final String entryBase;
  final String apiBase;

  /// app.js 里的异或掩码字节数组，运行时逐字节 ^0x5A 还原 AES-256 密钥。
  final List<int> keyMask;

  /// 站点导航对顶级分类的改名（逆向自各自 app.js 的 navRename）。
  final Map<String, String> navRename;

  /// 站点导航的自定义排序（navOrder，未列出的按接口顺序追加在后面）。
  final List<String> navOrder;

  /// 站点导航不展示的顶级分类（如浪妹隐藏"吃瓜图文"图文频道）。
  final Set<String> navExclude;

  Uint8List get key {
    final out = Uint8List(keyMask.length);
    for (var i = 0; i < keyMask.length; i++) {
      out[i] = keyMask[i] ^ 0x5A;
    }
    return out;
  }
}

/// 浪妹系站点解析器（rczga.cn=浪妹视频 / lfbrs.cn=要发发视频）。
///
/// API 协议（逆向自站点 app.js）：
/// - 请求：`GET {apiBase}?a=<action>&<params>`，服务端按 CORS 允许跨域；
/// - 响应：整体 base64，解码后前 16 字节为 IV，其余为 AES-256-CBC 密文
///   （PKCS7 填充），明文为 JSON；
/// - 动作：types（分类树）/ home（首页）/ list（分类列表）/ search（全局
///   搜索）/ detail（详情）；has_token 的详情用相对 m3u8 路径，需再请求
///   `{entryBase}/get/play.php?id=&sid=0&nid=1` 换取签名后的绝对播放地址。
///
/// 隐私会话：本类不持有任何 Cookie/持久化存储，追踪脚本（tj.fxzcr.cn 统计、
/// app.fxzcr.cn iframe）只存在于网页里、原生解析永远不会加载。每次进入卡片
/// 时页面会调用 [resetSession] 重建 Dio 并清空内存缓存 —— 每次进入都是全新
/// 状态（新连接、无 Cookie、无历史），等效隐私浏览器的全新身份。
class LangmeiApi {
  LangmeiApi();

  static final Map<String, LangmeiSiteConfig> _configs = {
    'langmei': LangmeiSiteConfig(
      entryBase: 'https://10326.rczga.cn',
      apiBase: 'https://api.rczga.cn/lm-api/',
      keyMask: const [
        202, 211, 221, 188, 52, 127, 180, 22, 13, 100, 241, 190, 183, 127, 26,
        100, 80, 225, 133, 206, 147, 145, 255, 149, 243, 36, 96, 155, 231, 163,
        179, 26,
      ],
      // rczga app.js: navRename={1:'激情',7:'国产',8:'嫩妹',2:'传媒',6:'网黄'}，
      // navOrder=[7,9,2,8,3,5,4,6,1]，且导航隐藏图文频道"吃瓜图文"。
      navRename: const {
        '1': '\u6fc0\u60c5', // 激情
        '7': '\u56fd\u4ea7', // 国产
        '8': '\u5ae9\u59b9', // 嫩妹
        '2': '\u4f20\u5a92', // 传媒
        '6': '\u7f51\u9ec4', // 网黄
      },
      navOrder: const ['7', '9', '2', '8', '3', '5', '4', '6', '1'],
      navExclude: const {'1092'},
    ),
    'yaofafa': LangmeiSiteConfig(
      entryBase: 'https://10326.lfbrs.cn',
      apiBase: 'https://api.lfbrs.cn/yf-api/',
      keyMask: const [
        105, 247, 25, 38, 156, 50, 4, 164, 49, 53, 48, 214, 114, 179, 87, 55,
        61, 95, 6, 227, 42, 76, 181, 70, 119, 166, 206, 209, 164, 135, 110, 19,
      ],
      // lfbrs app.js：无改名/重排/过滤，接口顺序即导航顺序（含吃瓜图文）。
    ),
  };

  Dio? _dio;

  /// 会话级内存缓存（key = site.id），resetSession 时清空。
  final Map<String, List<LangmeiType>> _typesCache = {};

  /// 用户自添加站点（设置-添加网站选"浪妹/要发发解析"）的派生配置，
  /// key = site.id；resetSession 一并清空。
  final Map<String, LangmeiSiteConfig> _customConfigs = {};

  /// 会话序号（调试观测用：每次 reset 递增）。
  int sessionSeq = 0;

  LangmeiSiteConfig configOf(SiteDef site) {
    final exact = _configs[site.id];
    if (exact != null) return exact;
    // 自定义站点（id 形如 custom_langmei_<url>）：API 前缀与密钥跟随解析
    // 家族，入口域名用用户填写的站点（/get/play.php 挂在该域上）。
    final family = site.parserId == null ? null : _configs[site.parserId!];
    if (family != null) {
      return _customConfigs.putIfAbsent(
        site.id,
        () => LangmeiSiteConfig(
          entryBase: site.primaryHost,
          apiBase: family.apiBase,
          keyMask: family.keyMask,
        ),
      );
    }
    throw ArgumentError('LangmeiApi: unknown site ${site.id}');
  }

  /// 每次进入卡片调用：丢弃旧 Dio（连接池/缓冲一并作废）并清空会话缓存，
  /// 下次请求自动重建 —— 等效"全新身份"。
  void resetSession() {
    _dio?.close(force: true);
    _dio = null;
    _typesCache.clear();
    _customConfigs.clear();
    sessionSeq++;
  }

  Dio get _client {
    final existing = _dio;
    if (existing != null) return existing;
    final fresh = AppHttpClient.create(
      headers: {'Accept': 'application/json, text/plain, */*'},
    );
    _dio = fresh;
    return fresh;
  }

  Map<String, String> _apiHeaders(LangmeiSiteConfig cfg) => {
        ...AppHttpHeaders.browser,
        'Accept': 'application/json, text/plain, */*',
        'Referer': '${cfg.entryBase}/',
        'Origin': cfg.entryBase,
      };

  /// 调用一个 API 动作并解密为 JSON。
  Future<dynamic> _call(
    SiteDef site,
    String action, [
    Map<String, Object?> params = const {},
  ]) async {
    final cfg = configOf(site);
    final res = await _client.get<dynamic>(
      cfg.apiBase,
      queryParameters: {'a': action, ...params},
      options: Options(
        responseType: ResponseType.plain,
        headers: _apiHeaders(cfg),
      ),
    );
    final body = res.data;
    if (body is! String || body.trim().isEmpty) {
      throw const FormatException('langmei: empty api body');
    }
    return _decrypt(cfg, body);
  }

  /// base64 → iv(16) + AES-256-CBC(PKCS7) → UTF-8 JSON。
  static dynamic _decrypt(LangmeiSiteConfig cfg, String b64) {
    final normalized =
        b64.trim().replaceAll(RegExp(r'\s'), '').replaceAll('-', '+').replaceAll('_', '/');
    final all = base64.decode(normalized);
    if (all.length <= 16 || all.length % 16 != 0) {
      throw const FormatException('langmei: bad payload length');
    }
    final iv = Uint8List.sublistView(all, 0, 16);
    final cipher = Uint8List.sublistView(all, 16);
    final cbc = CBCBlockCipher(AESEngine())
      ..init(false, ParametersWithIV(KeyParameter(cfg.key), iv));
    final plain = Uint8List(cipher.length);
    for (var off = 0; off < cipher.length; off += 16) {
      cbc.processBlock(cipher, off, plain, off);
    }
    // PKCS7 去填充（与 WebCrypto AES-CBC 行为一致）。
    final pad = plain.isEmpty ? 0 : plain.last;
    final end = (pad >= 1 && pad <= 16 && pad <= plain.length)
        ? plain.length - pad
        : plain.length;
    return json.decode(utf8.decode(Uint8List.sublistView(plain, 0, end)));
  }

  // ── 标签页（分类树） ────────────────────────────────────────────────────

  /// 分类树（站点顶部标签栏的数据源），会话内缓存。
  ///
  /// 复刻各站 app.js 的导航规则：顶级分类按 [LangmeiSiteConfig.navOrder]
  /// 排序、按 navRename 改名、按 navExclude 隐藏；子分类保持接口顺序。
  Future<List<LangmeiType>> fetchTypes(SiteDef site) async {
    final cached = _typesCache[site.id];
    if (cached != null) return cached;
    final cfg = configOf(site);
    final data = await _call(site, 'types');
    final raw = data is Map<String, dynamic> ? data['types'] : null;
    final list = <LangmeiType>[];
    if (raw is List) {
      for (final t in raw) {
        if (t is! Map<String, dynamic>) continue;
        final id = '${t['type_id']}';
        if (t['type_pid'].toString() != '0') continue;
        if (cfg.navExclude.contains(id)) continue;
        final children = <LangmeiType>[];
        final rawChildren = t['children'];
        if (rawChildren is List) {
          for (final c in rawChildren) {
            if (c is! Map<String, dynamic>) continue;
            children.add(LangmeiType(
              id: '${c['type_id']}',
              name: '${c['type_name']}',
            ));
          }
        }
        list.add(LangmeiType(
          id: id,
          name: cfg.navRename[id] ?? '${t['type_name']}',
          children: children,
        ));
      }
    }
    // 导航排序：navOrder 里的排前面（稳定），其余按接口顺序追加。
    final orderIndex = <String, int>{
      for (var i = 0; i < cfg.navOrder.length; i++) cfg.navOrder[i]: i,
    };
    if (orderIndex.isNotEmpty) {
      list.sort((a, b) =>
          (orderIndex[a.id] ?? 999) - (orderIndex[b.id] ?? 999));
    }
    _typesCache[site.id] = list;
    return list;
  }

  // ── 列表 / 首页 / 搜索 ────────────────────────────────────────────────

  /// 首页最新视频（a=home 的 vods 段）。
  Future<List<VideoItem>> fetchHome(SiteDef site, {int num = 24}) async {
    final data = await _call(site, 'home', {'num': num, 'sec_num': 5});
    return _parseVods(data, site);
  }

  /// 分类列表。sort: hits=最多观看 / time=最新更新 / score=评分最高。
  Future<List<VideoItem>> fetchList(
    SiteDef site, {
    required String typeId,
    int page = 1,
    String sort = 'hits',
    int limit = 24,
  }) async {
    final data = await _call(site, 'list', {
      'type_id': typeId,
      'page': page,
      'sort': sort,
      'limit': limit,
    });
    return _parseVods(data, site);
  }

  /// 站点全局搜索（等价于网页 `/#/search?wd=<wd>`）。
  Future<List<VideoItem>> search(
    SiteDef site,
    String wd, {
    int page = 1,
    int limit = 24,
  }) async {
    final data = await _call(site, 'search', {
      'wd': wd,
      'page': page,
      'limit': limit,
    });
    return _parseVods(data, site);
  }

  static List<VideoItem> _parseVods(dynamic data, SiteDef site) {
    final raw = data is Map<String, dynamic> ? data['vods'] : null;
    final items = <VideoItem>[];
    if (raw is List) {
      for (final v in raw) {
        if (v is! Map<String, dynamic>) continue;
        final id = '${v['id']}';
        final name = '${v['name'] ?? ''}'.trim();
        if (id.isEmpty || name.isEmpty) continue;
        final remarks = '${v['remarks'] ?? ''}'.trim();
        final score = '${v['score'] ?? ''}'.trim();
        items.add(VideoItem(
          url: '${site.primaryHost}/#/play/$id',
          title: name,
          duration: remarks.isEmpty ? '-' : remarks,
          thumb: '${v['pic'] ?? ''}',
          score: score.isEmpty ? null : score,
          badge: '${v['type_name'] ?? ''}',
        ));
      }
    }
    return items;
  }

  // ── 详情 / 播放地址 ──────────────────────────────────────────────────

  static final _playIdRe = RegExp(r'play/(\d+)');

  /// 解析播放页（`{entryBase}/#/play/<id>`）为可播流。
  Future<VideoDetail> getVideoDetail(SiteDef site, String pageUrl) async {
    final cfg = configOf(site);
    final id = _playIdRe.firstMatch(pageUrl)?.group(1);
    if (id == null || id.isEmpty) {
      return VideoDetail(
        url: pageUrl,
        title: '',
        durationSec: 0,
        streams: const [],
        unavailable: true,
      );
    }
    final data = await _call(site, 'detail', {'id': id});
    if (data is! Map<String, dynamic> || data['vod'] is! Map<String, dynamic>) {
      return VideoDetail(
        url: pageUrl,
        title: '',
        durationSec: 0,
        streams: const [],
        unavailable: true,
      );
    }
    final vod = data['vod'] as Map<String, dynamic>;
    final name = '${vod['name'] ?? ''}'.trim();
    final pic = '${vod['pic'] ?? ''}';
    final durationSec = _parseDuration('${vod['duration'] ?? vod['remarks'] ?? ''}');

    // sources[0].episodes[nid].url；本站单源单集，取第一集。
    var playUrl = '';
    final sources = vod['sources'];
    if (sources is List && sources.isNotEmpty && sources.first is Map<String, dynamic>) {
      final episodes = (sources.first as Map<String, dynamic>)['episodes'];
      if (episodes is List && episodes.isNotEmpty && episodes.first is Map<String, dynamic>) {
        playUrl = '${(episodes.first as Map<String, dynamic>)['url'] ?? ''}'.trim();
      }
    }
    if (playUrl.isEmpty) {
      return VideoDetail(
        url: pageUrl,
        title: name,
        durationSec: durationSec,
        thumb: pic,
        streams: const [],
        unavailable: true,
      );
    }

    // has_token：相对路径需要用 play.php 换签名后的绝对地址。
    final hasToken = vod['has_token'] == true ||
        '${vod['has_token']}'.toLowerCase() == 'true';
    if (hasToken && !playUrl.startsWith('http')) {
      final res = await _client.get<dynamic>(
        '${cfg.entryBase}/get/play.php',
        queryParameters: {'id': id, 'sid': 0, 'nid': 1},
        options: Options(
          responseType: ResponseType.plain,
          headers: _apiHeaders(cfg),
        ),
      );
      final body = res.data;
      if (body is String && body.isNotEmpty) {
        try {
          final decoded = json.decode(body);
          if (decoded is Map<String, dynamic> && decoded['url'] is String) {
            final signed = (decoded['url'] as String).trim();
            if (signed.isNotEmpty) playUrl = signed;
          }
        } catch (_) {/* 保底用原始相对路径 */}
      }
    }
    if (!playUrl.startsWith('http')) {
      playUrl = '${cfg.entryBase}/${playUrl.replaceFirst(RegExp(r'^/'), '')}';
    }

    return VideoDetail(
      url: pageUrl,
      title: name,
      description: '${vod['content'] ?? ''}'.trim(),
      durationSec: durationSec,
      thumb: pic,
      streams: [
        StreamQuality(width: 1920, height: 1080, url: playUrl),
      ],
    );
  }

  /// "29:06" / "1:02:03" → 秒。
  static int _parseDuration(String text) {
    final parts = text.split(':');
    var sec = 0;
    for (final p in parts) {
      final v = int.tryParse(p.trim());
      if (v == null) return 0;
      sec = sec * 60 + v;
    }
    return sec;
  }
}

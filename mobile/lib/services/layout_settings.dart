import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'source_catalog.dart';

class LayoutSettings extends ChangeNotifier {
  static const _kEnabled = 'layout_enabled_video_ids_v1';
  static const _kLiveId = 'layout_live_id_v1';
  static const _kGlobalSearch = 'layout_global_search_v1';
  static const _kCatalogVer = 'layout_catalog_ver_v1';
  static const _kCustomUrls = 'layout_custom_urls_v1';
  static const _kCustomSites = 'layout_custom_sites_v2';
  static const _kHiddenSites = 'layout_hidden_sites_v1';
  static const _catalogVer = 13;

  List<String> _enabledVideoIds =
      List<String>.from(SourceCatalog.defaultEnabledVideoIds);
  List<String> _customUrls = [];
  List<CustomSiteConfig> _customSites = [];
  Set<String> _hiddenSiteKeys = <String>{};
  String _liveId = SourceCatalog.defaultLiveId;
  bool _globalSearch = false;
  bool _ready = false;

  bool get ready => _ready;
  List<String> get enabledVideoIds => List.unmodifiable(_enabledVideoIds);
  List<String> get customUrls => List.unmodifiable(_customUrls);
  List<CustomSiteConfig> get customSites => List.unmodifiable(_customSites);
  String get liveId => _liveId;
  bool get globalSearch => _globalSearch;

  List<SiteDef> get allManagedSites => [
        ...SourceCatalog.all.where((s) => s.ready),
        ..._customSites.map((c) => c.site),
      ];

  bool isSiteHidden(SiteDef site) => _hiddenSiteKeys.contains(site.id);

  List<SiteDef> get enabledVideoSites => [
        ..._enabledVideoIds
            .map(SourceCatalog.byId)
            .whereType<SiteDef>()
            .where((s) => s.kind == SiteKind.video && s.ready),
        ..._customSites
            .where((c) => c.kind == SiteKind.video)
            .map((c) => c.site),
      ].where((s) => !isSiteHidden(s)).toList(growable: false);

  List<SiteDef> get enabledLiveSites => [
        ...SourceCatalog.liveSites.where((s) => s.ready),
        ..._customSites
            .where((c) => c.kind == SiteKind.live)
            .map((c) => c.site),
      ].where((s) => !isSiteHidden(s)).toList(growable: false);

  SiteDef? get liveSite {
    final site = SourceCatalog.byId(_liveId);
    if (site?.ready == true && !isSiteHidden(site!)) return site;
    for (final candidate in enabledLiveSites) {
      return candidate;
    }
    return null;
  }

  /// 自定义视频站是否可作为"至少保留一个视频站"的兜底。
  bool get _hasCustomVideoFallback =>
      _customSites.any((c) => c.kind == SiteKind.video);

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      // 自定义站/隐藏站必须先于启用列表加载：空启用列表是否合法（由自定义
      // 视频站兜底）取决于它们。
      _customUrls = p.getStringList(_kCustomUrls) ?? [];
      _customSites = (p.getStringList(_kCustomSites) ?? [])
          .map(CustomSiteConfig.tryDecode)
          .whereType<CustomSiteConfig>()
          .toList();
      _hiddenSiteKeys = (p.getStringList(_kHiddenSites) ?? []).toSet();
      if (_customSites.isEmpty && _customUrls.isNotEmpty) {
        _customSites = _customUrls
            .map((u) => CustomSiteConfig(url: u, parser: 'generic_vod'))
            .toList();
        await _persistCustomSites(p);
      }
      final catVer = p.getInt(_kCatalogVer) ?? 0;
      if (catVer < _catalogVer) {
        _enabledVideoIds =
            List<String>.from(SourceCatalog.defaultEnabledVideoIds);
        await p.setStringList(_kEnabled, _enabledVideoIds);
        await p.setInt(_kCatalogVer, _catalogVer);
      } else {
        final raw = p.getStringList(_kEnabled);
        if (raw != null && raw.isNotEmpty) {
          _enabledVideoIds = raw
              .where((id) => SourceCatalog.byId(id)?.kind == SiteKind.video)
              .toList();
        } else if (raw != null && raw.isEmpty && _hasCustomVideoFallback) {
          // 持久化的空列表 + 自定义视频站兜底 = 用户有意只留自定义站，
          // 不能回默认（否则删掉的内置站会在重启后复活）。
          _enabledVideoIds = <String>[];
        }
        if (_enabledVideoIds.isEmpty && !_hasCustomVideoFallback) {
          _enabledVideoIds =
              List<String>.from(SourceCatalog.defaultEnabledVideoIds);
        }
      }
      final live = p.getString(_kLiveId);
      if (live != null &&
          SourceCatalog.byId(live)?.kind == SiteKind.live &&
          SourceCatalog.byId(live)?.ready == true) {
        _liveId = live;
      }
      _globalSearch = p.getBool(_kGlobalSearch) ?? false;
    } catch (_) {
      // SharedPreferences unavailable — the field initializers already hold
      // exactly these defaults (defaultEnabledVideoIds, defaultLiveId, ...).
    }
    _ready = true;
    notifyListeners();
  }

  Future<void> addCustomUrl(String raw) =>
      addCustomSite(raw, parser: 'generic_vod');

  Future<void> addCustomSite(String raw, {required String parser}) async {
    var u = raw.trim();
    if (u.isEmpty) return;
    if (!u.startsWith('http://') && !u.startsWith('https://')) u = 'https://$u';
    final uri = Uri.tryParse(u);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return;
    final path =
        uri.path == '/' ? '' : uri.path.replaceFirst(RegExp(r'/+$'), '');
    final normalized = Uri(
            scheme: 'https',
            host: uri.host,
            port: uri.hasPort ? uri.port : null,
            path: path)
        .toString();
    if (_customSites.any((e) => e.url == normalized)) return;
    for (final s in SourceCatalog.all) {
      for (final m in s.mirrors) {
        final builtIn = Uri.tryParse(m);
        if (builtIn != null &&
            builtIn.host == uri.host &&
            builtIn.port == uri.port) {
          return;
        }
      }
    }
    _customSites = [
      ..._customSites,
      CustomSiteConfig(url: normalized, parser: parser)
    ];
    _customUrls = _customSites
        .where((e) => e.parser == 'generic_vod')
        .map((e) => e.url)
        .toList();
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList(_kCustomUrls, _customUrls);
      await _persistCustomSites(p);
    } catch (_) {}
  }

  Future<void> removeCustomUrl(String url) async {
    _customSites = _customSites.where((e) => e.url != url).toList();
    _customUrls = _customSites
        .where((e) => e.parser == 'generic_vod')
        .map((e) => e.url)
        .toList();
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList(_kCustomUrls, _customUrls);
      await _persistCustomSites(p);
    } catch (_) {}
  }

  Future<void> setEnabledVideoIds(List<String> ids) async {
    final clean = ids
        .where((id) => SourceCatalog.byId(id)?.kind == SiteKind.video)
        .toList();
    // 自定义视频站可兜底时允许空列表（用户有意只留自定义站）；否则回默认，
    // 保证首页至少有一个视频站。
    if (clean.isEmpty && !_hasCustomVideoFallback) {
      clean.addAll(SourceCatalog.defaultEnabledVideoIds);
    }
    _enabledVideoIds = clean;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList(_kEnabled, _enabledVideoIds);
    } catch (_) {}
  }

  /// Returns false (and leaves the list untouched) when this removal would
  /// leave no visible video site — enabled built-ins plus custom sites, hidden
  /// ones excluded — the same "at least one visible site" policy as
  /// [setSiteHidden]. Callers show "at least one site" feedback instead of
  /// silently no-oping. An empty built-in list is legal here: custom video
  /// sites keep the home page populated, and [load] preserves that choice.
  Future<bool> toggleVideoSite(String id, bool enabled) async {
    final next = List<String>.from(_enabledVideoIds);
    if (enabled) {
      if (!next.contains(id)) next.add(id);
    } else {
      next.remove(id);
      if (enabledVideoSites.where((s) => s.id != id).isEmpty) return false;
    }
    await setEnabledVideoIds(next);
    return true;
  }

  Future<void> reorderVideo(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= _enabledVideoIds.length) return;
    var ni = newIndex;
    if (ni > oldIndex) ni -= 1;
    final id = _enabledVideoIds.removeAt(oldIndex);
    _enabledVideoIds.insert(ni.clamp(0, _enabledVideoIds.length), id);
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList(_kEnabled, _enabledVideoIds);
    } catch (_) {}
  }

  Future<void> setLiveId(String id) async {
    final site = SourceCatalog.byId(id);
    if (site?.kind != SiteKind.live ||
        site?.ready != true ||
        isSiteHidden(site!)) {
      return;
    }
    _liveId = id;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kLiveId, id);
    } catch (_) {}
  }

  Future<void> setGlobalSearch(bool v) async {
    if (_globalSearch == v) return;
    _globalSearch = v;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kGlobalSearch, v);
    } catch (_) {}
  }

  /// Returns false (and leaves state untouched) when hiding this site would
  /// leave no visible video site — same "at least one video site" policy as
  /// [toggleVideoSite]. Callers show feedback instead of silently no-oping.
  Future<bool> setSiteHidden(SiteDef site, bool hidden) async {
    if (hidden) {
      if (site.kind != SiteKind.live) {
        // 可见站 = 内置已启用 + 自定义站（再减去已隐藏），与
        // [enabledVideoSites] 同一口径；只数内置站会误拒自定义站兜底的情况。
        final otherVisible =
            enabledVideoSites.where((s) => s.id != site.id).length;
        if (otherVisible == 0) return false;
      }
      _hiddenSiteKeys = {..._hiddenSiteKeys, site.id};
    } else {
      _hiddenSiteKeys = {..._hiddenSiteKeys}..remove(site.id);
    }
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList(_kHiddenSites, _hiddenSiteKeys.toList());
    } catch (_) {}
    return true;
  }

  Future<void> restoreDefaultLayout() async {
    _enabledVideoIds = List<String>.from(SourceCatalog.defaultEnabledVideoIds);
    _liveId = SourceCatalog.defaultLiveId;
    _globalSearch = false;
    _customUrls = [];
    _customSites = [];
    _hiddenSiteKeys = <String>{};
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList(_kEnabled, _enabledVideoIds);
      await p.setString(_kLiveId, _liveId);
      await p.setBool(_kGlobalSearch, false);
      await p.setStringList(_kCustomUrls, _customUrls);
      await _persistCustomSites(p);
      await p.setStringList(_kHiddenSites, const []);
      await p.setInt(_kCatalogVer, _catalogVer);
    } catch (_) {}
  }

  Future<void> _persistCustomSites(SharedPreferences p) async {
    await p.setStringList(
        _kCustomSites, _customSites.map((e) => e.encode()).toList());
  }
}

class CustomSiteConfig {
  const CustomSiteConfig({required this.url, required this.parser});
  final String url;
  final String parser;
  SiteKind get kind => parser == 'stripchat' || parser == 'chaturbate'
      ? SiteKind.live
      : SiteKind.video;
  SiteDef get site => SiteDef.customFromUrl(url, parserId: parser);
  String encode() => jsonEncode({'url': url, 'parser': parser});
  static CustomSiteConfig? tryDecode(String raw) {
    try {
      final value = jsonDecode(raw);
      if (value is! Map ||
          value['url'] is! String ||
          value['parser'] is! String) {
        return null;
      }
      return CustomSiteConfig(
          url: value['url'] as String, parser: value['parser'] as String);
    } catch (_) {
      return null;
    }
  }
}

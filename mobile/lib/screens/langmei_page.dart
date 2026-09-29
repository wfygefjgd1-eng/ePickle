import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/video_item.dart';
import '../services/langmei_api.dart';
import '../services/source_catalog.dart';
import 'search_feed_screen.dart';

/// 浪妹系站点站内入口（浪妹视频 / 要发发视频，同一套 Vue 模板）：
/// 仿站点移动端样式 —— 顶栏（站名 + 右上搜索框 + 隐私会话图标）、
/// 分类标签栏（a=types 动态解析，非硬编码）、子分类 chips、排序、
/// 16:9 双列卡片网格；点卡片进既有竖滑播放器。
///
/// 隐私：进入时 [LangmeiApi.resetSession] 重建全新会话（无 Cookie、
/// 无持久化、不加载站点统计脚本），离开时再次 reset 销毁痕迹。
class LangmeiPage extends StatefulWidget {
  const LangmeiPage({super.key, required this.site});

  final SiteDef site;

  @override
  State<LangmeiPage> createState() => _LangmeiPageState();
}

class _PageCache {
  _PageCache(this.items, this.page, this.hasMore, this.offset);
  final List<VideoItem> items;
  final int page;
  final bool hasMore;
  final double offset;
}

class _LangmeiPageState extends State<LangmeiPage> {
  static const _bg = Color(0xFF0D0D0D);
  static const _panel = Color(0xFF191919);
  static const _homeTab = 'home';

  final _scroll = ScrollController();
  final _searchCtrl = TextEditingController();
  final _cache = <String, _PageCache>{};

  List<LangmeiType> _types = const [];
  bool _typesLoading = true;
  String? _typesError;

  String _tab = _homeTab;
  String _sub = '';
  String _sort = 'hits';
  String _query = '';
  List<VideoItem> _items = const [];
  int _page = 0;
  bool _hasMore = false;
  bool _loading = false;
  bool _loadingMore = false;
  String? _error;
  int _generation = 0;

  Color get _theme => Color(widget.site.color);

  @override
  void initState() {
    super.initState();
    _api = context.read<LangmeiApi>();
    // 全新身份：进入卡片即重建会话（清连接池/内存缓存，无任何复用）。
    _api.resetSession();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_initTypes());
    });
  }

  @override
  void dispose() {
    // 离开卡片：销毁本站全部会话状态（等效隐私浏览器关窗）。
    // dispose 里不能再查 Provider，用 initState 缓存的引用。
    _api.resetSession();
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  late LangmeiApi _api;

  Future<void> _initTypes() async {
    setState(() {
      _typesLoading = true;
      _typesError = null;
    });
    try {
      final types = await _api.fetchTypes(widget.site);
      if (!mounted) return;
      setState(() {
        _types = types;
        _typesLoading = false;
      });
      unawaited(_load());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _typesLoading = false;
        _typesError = e.toString();
      });
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients || _scroll.position.extentAfter > 360) return;
    unawaited(_loadMore());
  }

  String get _cacheKey {
    if (_query.isNotEmpty) return 'search:$_query';
    if (_tab == _homeTab) return 'home';
    return 'cat:$_tab:${_sub.isEmpty ? _tab : _sub}:$_sort';
  }

  void _rememberCache() {
    if (_items.isEmpty) return;
    final offset = _scroll.hasClients ? _scroll.offset : 0.0;
    _cache[_cacheKey] = _PageCache(_items, _page, _hasMore, offset);
    while (_cache.length > 24) {
      _cache.remove(_cache.keys.first);
    }
  }

  void _selectTab(String id) {
    if (id == _tab && _query.isEmpty) return;
    _rememberCache();
    setState(() {
      _query = '';
      _searchCtrl.clear();
      _tab = id;
      _sub = '';
    });
    _restoreOrLoad();
  }

  void _selectSub(String id) {
    if (id == _sub) return;
    _rememberCache();
    setState(() => _sub = id);
    _restoreOrLoad();
  }

  void _selectSort(String sort) {
    if (sort == _sort) return;
    _rememberCache();
    setState(() => _sort = sort);
    _restoreOrLoad();
  }

  void _restoreOrLoad() {
    final cached = _cache[_cacheKey];
    if (cached != null) {
      _generation++;
      setState(() {
        _items = cached.items;
        _page = cached.page;
        _hasMore = cached.hasMore;
        _error = null;
        _loading = false;
        _loadingMore = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        _scroll.jumpTo(
          cached.offset.clamp(0.0, _scroll.position.maxScrollExtent),
        );
      });
      return;
    }
    unawaited(_load());
  }

  void _onSearch(String value) {
    final query = value.trim();
    if (query == _query) return;
    _rememberCache();
    setState(() => _query = query);
    unawaited(_load());
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final tab = _tab;
    final sub = _sub;
    final sort = _sort;
    final query = _query;
    setState(() {
      _loading = true;
      _loadingMore = false;
      _hasMore = false;
      _error = null;
    });
    try {
      final List<VideoItem> list;
      if (query.isNotEmpty) {
        list = await _api.search(widget.site, query, page: 1);
      } else if (tab == _homeTab) {
        list = await _api.fetchHome(widget.site);
      } else {
        list = await _api.fetchList(
          widget.site,
          typeId: sub.isEmpty ? tab : sub,
          page: 1,
          sort: sort,
        );
      }
      if (!mounted || generation != _generation) return;
      setState(() {
        _items = list;
        _page = 1;
        // 首页聚合接口无分页，其余列表按返回量续抓。
        _hasMore = list.isNotEmpty && tab != _homeTab;
        _loading = false;
        if (list.isEmpty) _error = '\u6682\u65e0\u53ef\u64ad\u653e\u7684\u5185\u5bb9';
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        _scroll.jumpTo(0);
      });
    } catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore) return;
    final generation = _generation;
    final tab = _tab;
    final sub = _sub;
    final sort = _sort;
    final query = _query;
    final page = _page;
    setState(() => _loadingMore = true);
    try {
      final List<VideoItem> list;
      if (query.isNotEmpty) {
        list = await _api.search(widget.site, query, page: page + 1);
      } else if (tab == _homeTab) {
        return;
      } else {
        list = await _api.fetchList(
          widget.site,
          typeId: sub.isEmpty ? tab : sub,
          page: page + 1,
          sort: sort,
        );
      }
      if (!mounted || generation != _generation) return;
      final seen = <String>{for (final item in _items) item.viewkey};
      final additions = <VideoItem>[];
      for (final item in list) {
        if (seen.add(item.viewkey)) additions.add(item);
      }
      setState(() {
        _items = [..._items, ...additions];
        _page = page + 1;
        _hasMore = list.isNotEmpty && additions.isNotEmpty;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() => _loadingMore = false);
    }
  }

  bool _navLock = false;

  Future<void> _openPlayer(int index) async {
    if (_navLock) return;
    _navLock = true;
    try {
      final items = List<VideoItem>.from(_items);
      final title = _query.isEmpty
          ? _currentTitle
          : '\u641c\u7d22\u300a$_query\u300b';
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => SearchFeedScreen(
            items: items,
            source: SearchSource.langmei,
            site: widget.site,
            title: title,
            initialIndex: index,
            onLoadMore: () async {
              final before = _items.length;
              await _loadMore();
              if (_items.length <= before) return const <VideoItem>[];
              return _items.sublist(before);
            },
          ),
        ),
      );
    } finally {
      _navLock = false;
    }
  }

  String get _currentTitle {
    if (_tab == _homeTab) return widget.site.name;
    for (final t in _types) {
      if (t.id == _tab) {
        if (_sub.isEmpty) return t.name;
        for (final c in t.children) {
          if (c.id == _sub) return c.name;
        }
        return t.name;
      }
    }
    return widget.site.name;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            _buildTabs(),
            if (_tab != _homeTab && _query.isEmpty) ...[
              if (_selectedType?.children.isNotEmpty ?? false) _buildSubChips(),
              _buildSortRow(),
            ],
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  LangmeiType? get _selectedType {
    for (final t in _types) {
      if (t.id == _tab) return t;
    }
    return null;
  }

  // ── 顶栏：站名（末二字主题色）+ 右上搜索框 + 隐私会话按钮 ─────────────

  Widget _buildHeader() {
    final name = widget.site.name;
    final suffix = '\u89c6\u9891'; // 视频
    final hasSuffix = name.endsWith(suffix) && name.length > suffix.length;
    return Container(
      color: _panel,
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 6),
      child: Row(
        children: [
          if (hasSuffix)
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: name.substring(0, name.length - suffix.length),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                    ),
                  ),
                  TextSpan(
                    text: suffix,
                    style: TextStyle(
                      color: _theme,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            )
          else
            Text(
              name,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.5,
              ),
            ),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _searchCtrl,
              onSubmitted: _onSearch,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                isDense: true,
                hintText: '\u641c\u7d22\u4f60\u611f\u5174\u8da3\u7684\u5185\u5bb9',
                hintStyle:
                    const TextStyle(color: Colors.white30, fontSize: 13),
                prefixIcon: const Icon(Icons.search,
                    color: Colors.white30, size: 18),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close,
                            color: Colors.white38, size: 16),
                        onPressed: () {
                          _rememberCache();
                          setState(() {
                            _query = '';
                            _searchCtrl.clear();
                          });
                          unawaited(_load());
                        },
                      ),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.08),
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: '\u9690\u79c1\u4f1a\u8bdd',
            icon: Icon(Icons.shield_outlined, color: _theme, size: 20),
            onPressed: _showPrivacyDialog,
          ),
        ],
      ),
    );
  }

  void _showPrivacyDialog() {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Row(
          children: [
            Icon(Icons.shield_outlined, color: _theme, size: 20),
            const SizedBox(width: 8),
            const Text(
              '\u9690\u79c1\u4f1a\u8bdd',
              style: TextStyle(color: Colors.white, fontSize: 16),
            ),
          ],
        ),
        content: const Text(
          '\u6bcf\u6b21\u8fdb\u5165\u672c\u5361\u7247\u90fd\u4f1a\u91cd\u5efa'
          '\u5168\u65b0\u4f1a\u8bdd\uff1a\u4e0d\u643a\u5e26 Cookie\u3001'
          '\u4e0d\u843d\u76d8\u4efb\u4f55\u6570\u636e\u3001\u4e0d\u52a0\u8f7d'
          '\u7ad9\u70b9\u7edf\u8ba1\u811a\u672c\uff0c\u79bb\u5f00\u9875\u9762'
          '\u5373\u9500\u6bc1\u3002',
          style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('\u597d\u7684', style: TextStyle(color: _theme)),
          ),
        ],
      ),
    );
  }

  // ── 标签栏：首页 + 动态分类（站点 lm-tab 下划线样式） ──────────────────

  Widget _buildTabs() {
    final tabs = <(String, String)>[
      (_homeTab, '\u9996\u9875'),
      ..._types.map((t) => (t.id, t.name)),
    ];
    return Container(
      width: double.infinity,
      color: _panel,
      child: SizedBox(
        height: 38,
        child: _typesLoading
            ? const SizedBox.shrink()
            : ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                itemCount: tabs.length,
                separatorBuilder: (_, __) => const SizedBox(width: 2),
                itemBuilder: (_, i) {
                  final (id, name) = tabs[i];
                  final active = id == _tab && _query.isEmpty;
                  return InkWell(
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
                    onTap: () => _selectTab(id),
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            width: 2,
                            color: active ? _theme : Colors.transparent,
                          ),
                        ),
                      ),
                      child: Text(
                        name,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                          color: active ? _theme : Colors.white60,
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }

  // ── 子分类 chips（站点 lm-nav-row 圆角块样式） ────────────────────────

  Widget _buildSubChips() {
    final type = _selectedType!;
    final chips = <(String, String)>[
      ('', '\u5168\u90e8'),
      ...type.children.map((c) => (c.id, c.name)),
    ];
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        itemCount: chips.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (_, i) {
          final (id, name) = chips[i];
          final active = id == _sub;
          return InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => _selectSub(id),
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: active
                    ? _theme
                    : Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                name,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: active ? Colors.white : Colors.white70,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // ── 排序（最新更新 / 最多观看 / 评分最高） ────────────────────────────

  Widget _buildSortRow() {
    final sorts = <(String, String)>[
      ('time', '\u6700\u65b0\u66f4\u65b0'),
      ('hits', '\u6700\u591a\u89c2\u770b'),
      ('score', '\u8bc4\u5206\u6700\u9ad8'),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
      child: Row(
        children: [
          for (var i = 0; i < sorts.length; i++) ...[
            if (i > 0) const SizedBox(width: 14),
            InkWell(
              borderRadius: BorderRadius.circular(4),
              onTap: () => _selectSort(sorts[i].$1),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text(
                  sorts[i].$2,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight:
                        sorts[i].$1 == _sort ? FontWeight.w700 : FontWeight.w400,
                    color: sorts[i].$1 == _sort ? _theme : Colors.white54,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── 主体：16:9 双列网格 ───────────────────────────────────────────────

  Widget _buildBody() {
    if (_typesLoading) {
      return const Center(
        child: CircularProgressIndicator(strokeWidth: 2.5),
      );
    }
    if (_typesError != null) {
      return _buildErrorBody(_typesError!);
    }
    if (_loading) {
      return Center(
        child: CircularProgressIndicator(color: _theme, strokeWidth: 2.5),
      );
    }
    if (_error != null && _items.isEmpty) {
      return _buildErrorBody(_error!);
    }
    if (_items.isEmpty) {
      return const Center(
        child: Text(
          '\u6ca1\u6709\u627e\u5230\u76f8\u5173\u5185\u5bb9',
          style: TextStyle(color: Colors.white38, fontSize: 13),
        ),
      );
    }
    return CustomScrollView(
      controller: _scroll,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 12,
              crossAxisSpacing: 10,
              // 16:9 封面 + 两行标题 + 徽标留白。
              childAspectRatio: 0.82,
            ),
            delegate: SliverChildBuilderDelegate(
              (_, i) => _buildCard(_items[i], i),
              childCount: _items.length,
            ),
          ),
        ),
        SliverToBoxAdapter(child: _buildFooter()),
      ],
    );
  }

  Widget _buildErrorBody(String message) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_outlined, color: Colors.white30, size: 40),
          const SizedBox(height: 10),
          Text(
            message,
            style: const TextStyle(color: Colors.white38, fontSize: 13),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 14),
          OutlinedButton(
            onPressed: () =>
                _typesError != null ? unawaited(_initTypes()) : unawaited(_load()),
            style: OutlinedButton.styleFrom(
              foregroundColor: _theme,
              side: BorderSide(color: _theme),
            ),
            child: const Text('\u91cd\u8bd5'),
          ),
        ],
      ),
    );
  }

  Widget _buildCard(VideoItem item, int index) {
    return GestureDetector(
      onTap: () => _openPlayer(index),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _buildCover(item),
                  Positioned(
                    bottom: 6,
                    right: 6,
                    child: _badge(
                      item.duration == '-' ? '' : item.duration,
                      color: Colors.white,
                    ),
                  ),
                  if (item.score != null && item.score!.isNotEmpty)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: _badge(item.score!, color: _theme),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Text(
              item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCover(VideoItem item) {
    final thumb = item.thumb;
    if (thumb == null || thumb.isEmpty) {
      return Container(
        color: const Color(0xFF141414),
        child: const Center(
          child: Icon(Icons.movie_creation_outlined,
              color: Colors.white24, size: 28),
        ),
      );
    }
    return CachedNetworkImage(
      imageUrl: thumb,
      fit: BoxFit.cover,
      memCacheWidth: 480,
      placeholder: (_, __) => Container(color: const Color(0xFF141414)),
      errorWidget: (_, __, ___) => Container(
        color: const Color(0xFF141414),
        child: const Icon(Icons.broken_image, color: Colors.white24, size: 24),
      ),
    );
  }

  Widget _badge(String text, {required Color color}) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        border: Border.all(color: Colors.white24),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildFooter() {
    if (_loadingMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: CircularProgressIndicator(color: _theme, strokeWidth: 2.5),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Center(
        child: Text(
          _hasMore
              ? '\u7ee7\u7eed\u6ed1\u52a8\u52a0\u8f7d'
              : '\u5df2\u6ca1\u6709\u66f4\u591a\u5185\u5bb9',
          style: const TextStyle(color: Colors.white30, fontSize: 12),
        ),
      ),
    );
  }
}

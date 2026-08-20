import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

import '../models/video_item.dart';
import '../services/generic_site_api.dart';
import '../services/huangguo_api.dart';
import '../services/layout_settings.dart';
import '../services/mitao_api.dart';
import '../services/phub_api.dart';
import '../services/source_catalog.dart';
import '../services/translator.dart';
import '../services/xvideos_api.dart';
import '../utils/playback_helpers.dart';
import '../widgets/site_logo.dart';
import '../widgets/video_card.dart';
import 'search_feed_screen.dart';

/// Multi-site search: left site tabs, right results for the selected site.
class SearchScreen extends StatefulWidget {
  const SearchScreen({
    super.key,
    this.initialQuery,
  });

  final String? initialQuery;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  String _lastQuery = '';
  String? _enQuery;
  int _searchGen = 0;
  String? _activeSiteId;

  final Map<String, List<VideoItem>> _results = {};
  final Map<String, bool> _loading = {};
  final Map<String, String?> _error = {};
  final Map<String, int> _page = {};
  final Map<String, bool> _hasMore = {};

  static const _maxResultsPerSrc = 200;

  List<SiteDef> get _sites {
    final layout = context.read<LayoutSettings>();
    return layout.enabledVideoSites
        .where((s) => s.ready && s.searchable)
        .toList(growable: false);
  }

  String? _effectiveActiveId(List<SiteDef> sites) {
    if (sites.isEmpty) return _activeSiteId;
    if (_activeSiteId == null || !sites.any((s) => s.id == _activeSiteId)) {
      return sites.first.id;
    }
    return _activeSiteId;
  }

  @override
  void initState() {
    super.initState();
    final q = widget.initialQuery?.trim();
    if (q != null && q.isNotEmpty) {
      _controller.text = q;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) _runAll();
      });
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _unfocus() {
    _focus.unfocus();
    FocusManager.instance.primaryFocus?.unfocus();
  }

  Future<void> _runAll() async {
    final q = _controller.text.trim();
    if (q.isEmpty) return;
    _unfocus();
    final gen = ++_searchGen;
    _lastQuery = q;
    _enQuery = null;

    final sites = _sites;
    if (sites.isEmpty) return;

    final validatedActiveId = _effectiveActiveId(sites);
    setState(() {
      _activeSiteId = validatedActiveId;
      for (final s in sites) {
        _results[s.id] = [];
        _error[s.id] = null;
        _loading[s.id] = true;
        _page[s.id] = 1;
        _hasMore[s.id] = true;
      }
    });

    final tr = context.read<Translator>();
    var en = q;
    if (tr.containsChinese(q)) {
      try {
        final t = await tr.zhToEn(q);
        if (t.trim().isNotEmpty) en = t.trim();
      } catch (_) {}
    }
    if (!mounted || gen != _searchGen) return;
    _enQuery = en;

    for (final site in sites) {
      final query =
          (site.id == 'mitao' || site.id == 'huangguo') ? q : en;
      // ignore: unawaited_futures
      _searchOne(site, query, 1, replace: true, gen: gen);
    }
  }

  Future<List<VideoItem>> _fetchPage(SiteDef site, String query, int page) {
    if (site.id == 'pornhub') {
      return context.read<PhubApi>().search(query, page: page);
    }
    if (site.id == 'xvideos') {
      return context.read<XvideosApi>().search(query, page: page);
    }
    if (site.id == 'mitao') {
      return context.read<MitaoApi>().search(query, page: page);
    }
    if (site.id == 'huangguo') {
      return context.read<HuangGuoApi>().search(query, page: page);
    }
    return context.read<GenericSiteApi>().search(site, query, page: page);
  }

  Future<void> _searchOne(
    SiteDef site,
    String query,
    int page, {
    required bool replace,
    required int gen,
  }) async {
    final id = site.id;
    if (!mounted || gen != _searchGen) return;
    setState(() {
      _loading[id] = true;
      _error[id] = null;
    });
    try {
      final list = await _fetchPage(site, query, page);
      if (!mounted || gen != _searchGen) return;
      final prev = _results[id] ?? [];
      final seen = <String>{
        for (final e in (replace ? <VideoItem>[] : prev)) e.viewkey,
      };
      final fresh = <VideoItem>[];
      for (final e in list) {
        if (seen.add(e.viewkey)) fresh.add(e);
      }
      var merged = replace ? fresh : [...prev, ...fresh];
      if (merged.length > _maxResultsPerSrc) {
        merged = merged.sublist(merged.length - _maxResultsPerSrc);
        _hasMore[id] = false;
      }
      setState(() {
        _results[id] = merged;
        _page[id] = page;
        _loading[id] = false;
        _hasMore[id] = list.isNotEmpty &&
            fresh.isNotEmpty &&
            merged.length < _maxResultsPerSrc;
      });
    } catch (e) {
      if (!mounted || gen != _searchGen) return;
      setState(() {
        _loading[id] = false;
        _error[id] = PlaybackHelpers.friendlyError(e);
      });
    }
  }

  Future<void> _loadMore(SiteDef site) async {
    final id = site.id;
    if (_loading[id] == true || _lastQuery.isEmpty) return;
    if (_hasMore[id] == false) return;
    final next = (_page[id] ?? 1) + 1;
    final q = site.id == 'mitao' ? _lastQuery : (_enQuery ?? _lastQuery);
    if (site.id == 'huangguo') {
      // 黄果为中文站，搜索词保持原样。
      await _searchOne(site, _lastQuery, next, replace: false, gen: _searchGen);
      return;
    }
    await _searchOne(site, q, next, replace: false, gen: _searchGen);
  }

  void _openFeed(SiteDef site, int index) {
    final items = _results[site.id] ?? [];
    if (items.isEmpty) return;
    final source = switch (site.id) {
      'xvideos' => SearchSource.x,
      'mitao' => SearchSource.zhong,
      'pornhub' => SearchSource.ph,
      'huangguo' => SearchSource.huangguo,
      _ => SearchSource.generic,
    };
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SearchFeedScreen(
          items: List<VideoItem>.from(items),
          source: source,
          initialIndex: index,
          title: site.name,
          // Generic sites need the real SiteDef so detail resolution keeps the
          // site-specific parser branches AND mirror failover (instead of
          // degrading to a synthetic custom-site detail query).
          site: source == SearchSource.generic ? site : null,
          onLoadMore: () async {
            final before = (_results[site.id] ?? []).length;
            await _loadMore(site);
            final all = _results[site.id] ?? [];
            if (all.length <= before) return const <VideoItem>[];
            return all.sublist(before);
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sites = context
        .watch<LayoutSettings>()
        .enabledVideoSites
        .where((s) => s.ready && s.searchable)
        .toList(growable: false);
    final activeId = _effectiveActiveId(sites);
    SiteDef? activeSite;
    for (final s in sites) {
      if (s.id == activeId) {
        activeSite = s;
        break;
      }
    }
    activeSite ??= sites.isEmpty ? null : sites.first;
    final items = activeSite == null
        ? const <VideoItem>[]
        : (_results[activeSite.id] ?? []);
    final loading =
        activeSite == null ? false : (_loading[activeSite.id] ?? false);
    final err = activeSite == null ? null : _error[activeSite.id];
    final canPop = Navigator.of(context).canPop();

    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        automaticallyImplyLeading: canPop,
        title: const Text('搜索'),
        backgroundColor: const Color(0xFF1E1E1E),
        foregroundColor: Colors.white,
      ),
      body: Column(
        verticalDirection: VerticalDirection.up,
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 108,
                  child: Material(
                    color: const Color(0xFF1A1A1A),
                    child: ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: sites.length,
                      itemBuilder: (_, i) {
                        final s = sites[i];
                        final selected = s.id == activeSite?.id;
                        final count = (_results[s.id] ?? []).length;
                        final busy = _loading[s.id] ?? false;
                        return InkWell(
                          onTap: () => setState(() => _activeSiteId = s.id),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 12,
                            ),
                            color: selected
                                ? const Color(0x22FF6B35)
                                : Colors.transparent,
                            child: Column(
                              children: [
                                SiteLogo(site: s, size: 36),
                                const SizedBox(height: 6),
                                Text(
                                  s.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: selected
                                        ? const Color(0xFFFF6B35)
                                        : Colors.white70,
                                    fontSize: 11,
                                    fontWeight: selected
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                if (busy)
                                  const SizedBox(
                                    width: 10,
                                    height: 10,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 1.5,
                                      color: Color(0xFFFF6B35),
                                    ),
                                  )
                                else if (count > 0)
                                  Text(
                                    '$count',
                                    style: const TextStyle(
                                      color: Colors.white38,
                                      fontSize: 10,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                const VerticalDivider(width: 1, color: Colors.white12),
                Expanded(
                  child: _buildResultsBody(
                    activeSite,
                    items,
                    loading,
                    err,
                  ),
                ),
              ],
            ),
          ),
          Material(
            color: const Color(0xFF1E1E1E),
            elevation: 8,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      focusNode: _focus,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                      ),
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _runAll(),
                      decoration: InputDecoration(
                        hintText: '搜索全部已启用网站',
                        hintStyle: const TextStyle(color: Colors.white38),
                        filled: true,
                        fillColor: const Color(0xFF2A2A2A),
                        isDense: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        prefixIcon: const Icon(
                          Icons.search,
                          color: Colors.white38,
                          size: 20,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFFF6B35),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                    ),
                    onPressed: _runAll,
                    child: const Text('搜'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultsBody(
    SiteDef? site,
    List<VideoItem> items,
    bool loading,
    String? err,
  ) {
    if (site == null) {
      return const Center(
        child: Text('暂无已启用网站', style: TextStyle(color: Colors.grey)),
      );
    }
    if (loading && items.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFFFF6B35)),
      );
    }
    if (err != null && items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                err,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.redAccent, fontSize: 13),
              ),
              const SizedBox(height: 12),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFFF6B35),
                ),
                onPressed: () {
                  final q = (site.id == 'mitao' || site.id == 'huangguo')
                      ? _lastQuery
                      : (_enQuery ?? _lastQuery);
                  if (q.isEmpty) {
                    _runAll();
                  } else {
                    _searchOne(site, q, 1, replace: true, gen: _searchGen);
                  }
                },
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (items.isEmpty) {
      return Center(
        child: Text(
          _lastQuery.isEmpty ? '输入关键词，遍历已启用网站' : '${site.name} 暂无结果',
          style: const TextStyle(color: Colors.grey),
        ),
      );
    }
    final hasMore = _hasMore[site.id] ?? true;
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.pixels >= n.metrics.maxScrollExtent - 240) {
          if (hasMore && !loading) _loadMore(site);
        }
        return false;
      },
      child: ListView.builder(
        itemCount: items.length + 1,
        itemBuilder: (_, i) {
          if (i == items.length) {
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: loading
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          color: Color(0xFFFF6B35),
                          strokeWidth: 2,
                        ),
                      )
                    : Text(
                        hasMore ? '上拉加载更多' : '没有更多了',
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 12,
                        ),
                      ),
              ),
            );
          }
          return VideoCard(
            item: items[i],
            onTap: () => _openFeed(site, i),
          );
        },
      ),
    );
  }
}

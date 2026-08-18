import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/video_item.dart';
import '../services/generic_site_api.dart';
import '../services/huangguo_api.dart';
import '../services/mitao_api.dart';
import '../services/phub_api.dart';
import '../services/source_catalog.dart';
import '../services/xvideos_api.dart';
import '../utils/playback_helpers.dart';
import '../widgets/site_logo.dart';
import '../widgets/video_card.dart';
import 'search_feed_screen.dart';

/// Search within a single site only.
class SiteSearchPage extends StatefulWidget {
  const SiteSearchPage({super.key, required this.site});

  final SiteDef site;

  @override
  State<SiteSearchPage> createState() => _SiteSearchPageState();
}

class _SiteSearchPageState extends State<SiteSearchPage> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  List<VideoItem> _items = [];
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = false;
  int _page = 0;
  String? _error;
  int _gen = 0;

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final q = _ctrl.text.trim();
    if (q.isEmpty) return;
    final gen = ++_gen;
    setState(() {
      _loading = true;
      _error = null;
      _items = [];
      _page = 0;
      _hasMore = false;
    });
    try {
      final list = await _searchPage(q, 1);
      if (!mounted || gen != _gen) return;
      setState(() {
        _items = list;
        _loading = false;
        _page = 1;
        _hasMore = list.isNotEmpty;
        if (list.isEmpty) _error = '无结果';
      });
    } catch (e) {
      if (!mounted || gen != _gen) return;
      setState(() {
        _loading = false;
        _error = PlaybackHelpers.friendlyError(e);
      });
    }
  }

  Future<List<VideoItem>> _searchPage(String query, int page) {
    final site = widget.site;
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

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    final q = _ctrl.text.trim();
    if (q.isEmpty) return;
    final gen = _gen;
    final nextPage = _page + 1;
    setState(() => _loadingMore = true);
    try {
      final list = await _searchPage(q, nextPage);
      if (!mounted || gen != _gen) return;
      final seen = _items.map((e) => e.viewkey).toSet();
      final additions = list.where((e) => seen.add(e.viewkey)).toList();
      setState(() {
        _items.addAll(additions);
        _page = nextPage;
        _hasMore = list.isNotEmpty;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted || gen != _gen) return;
      setState(() {
        _loadingMore = false;
        _error = PlaybackHelpers.friendlyError(e);
      });
    }
  }

  SearchSource get _feedSource {
    switch (widget.site.id) {
      case 'xvideos':
        return SearchSource.x;
      case 'mitao':
        return SearchSource.zhong;
      case 'pornhub':
        return SearchSource.ph;
      case 'huangguo':
        return SearchSource.huangguo;
      default:
        return SearchSource.generic;
    }
  }

  Widget _buildBody() {
    final site = widget.site;
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFFFF6B35)),
      );
    }
    if (_error != null && _items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 16),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFFF6B35),
                ),
                onPressed: _loading ? null : _run,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (_items.isEmpty) {
      return const Center(
        child: Text(
          '输入关键词搜索本站',
          style: TextStyle(color: Colors.white38),
        ),
      );
    }
    return ListView.builder(
      itemCount: _items.length + (_hasMore ? 1 : 0),
      itemBuilder: (_, i) {
        if (i == _items.length) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: _loadingMore
                  ? const CircularProgressIndicator(color: Color(0xFFFF6B35))
                  : TextButton.icon(
                      onPressed: _loadMore,
                      icon: const Icon(Icons.expand_more),
                      label: const Text('加载更多'),
                    ),
            ),
          );
        }
        return VideoCard(
          item: _items[i],
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => SearchFeedScreen(
                  items: List<VideoItem>.from(_items),
                  source: _feedSource,
                  initialIndex: i,
                  title: site.name,
                  site: site,
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final site = widget.site;
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Row(
          children: [
            SiteLogo(site: site, size: 28),
            const SizedBox(width: 10),
            Expanded(
              child: Text('搜索 · ${site.name}', overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
      body: Column(
        verticalDirection: VerticalDirection.up,
        children: [
          Expanded(child: _buildBody()),
          Material(
            color: const Color(0xFF1E1E1E),
            elevation: 8,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ctrl,
                      focusNode: _focus,
                      style: const TextStyle(color: Colors.white),
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _run(),
                      decoration: InputDecoration(
                        hintText: '仅搜索 ${site.name}',
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
                    onPressed: _loading ? null : _run,
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
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/video_item.dart';
import '../services/generic_site_api.dart';
import '../services/huangguo_api.dart';
import '../services/mitao_api.dart';
import '../services/phub_api.dart';
import '../services/source_catalog.dart';
import '../services/translator.dart';
import '../services/xvideos_api.dart';
import '../utils/playback_helpers.dart';
import '../widgets/site_logo.dart';
import '../widgets/video_card.dart';
import 'search_feed_screen.dart';
import 'video_feed_screen.dart';

/// Compact category directory with a persistent tag rail and paged results.
class SiteTagDirectoryPage extends StatefulWidget {
  const SiteTagDirectoryPage({super.key, required this.site});
  final SiteDef site;

  @override
  State<SiteTagDirectoryPage> createState() => _SiteTagDirectoryPageState();
}

class _SiteTagDirectoryPageState extends State<SiteTagDirectoryPage> {
  final _scroll = ScrollController();
  SiteTag? _selected;
  List<VideoItem> _items = const [];
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = false;
  int _page = 0;
  int _generation = 0;
  String? _error;

  List<SiteTag> get _tags {
    if (widget.site.directoryTags.isNotEmpty) return widget.site.directoryTags;
    return widget.site.kind == SiteKind.live
        ? SourceCatalog.liveDirectoryTags
        : SourceCatalog.vodDirectoryTags;
  }

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients || _scroll.position.extentAfter > 360) return;
    _loadMore();
  }

  Future<void> _select(SiteTag tag) async {
    final api = context.read<GenericSiteApi>();
    final generation = ++_generation;
    setState(() {
      _selected = tag;
      _loading = true;
      _loadingMore = false;
      _hasMore = false;
      _page = 0;
      _items = const [];
      _error = null;
    });
    try {
      final raw = await _fetchItems(api, tag, page: 1, exclude: const {});
      if (!mounted || generation != _generation) return;
      setState(() {
        _items = raw;
        _page = 1;
        _hasMore = raw.isNotEmpty;
        _loading = false;
        if (raw.isEmpty) {
          _error = '\u6682\u65e0\u53ef\u64ad\u653e\u7684\u5185\u5bb9';
        }
      });
      if (raw.isNotEmpty && widget.site.kind != SiteKind.live) {
        unawaited(_translateRange(0, generation));
      }
    } catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = PlaybackHelpers.friendlyError(e);
      });
    }
  }

  Future<void> _loadMore() async {
    final tag = _selected;
    if (tag == null || _loading || _loadingMore || !_hasMore) return;
    final api = context.read<GenericSiteApi>();
    final generation = _generation;
    setState(() => _loadingMore = true);
    try {
      final seen = _items.map((item) => item.viewkey).toSet();
      final raw = await _fetchItems(api, tag, page: _page + 1, exclude: seen);
      final additions = raw.where((item) => seen.add(item.viewkey)).toList();
      if (!mounted || generation != _generation) return;
      final addedStart = _items.length;
      setState(() {
        _items = [..._items, ...additions];
        _page++;
        _hasMore = raw.isNotEmpty && additions.isNotEmpty;
        _loadingMore = false;
      });
      if (additions.isNotEmpty && widget.site.kind != SiteKind.live) {
        unawaited(_translateRange(addedStart, generation));
      }
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loadingMore = false;
        _hasMore = false;
      });
    }
  }

  Future<void> _translateRange(int start, int generation) async {
    if (widget.site.kind == SiteKind.live) return;
    if (start < 0 || start >= _items.length) return;
    try {
      final slice = _items.sublist(start);
      final titles = slice.map((e) => e.title).toList();
      final translated =
          await context.read<Translator>().batchEnToZh(titles);
      if (!mounted || generation != _generation) return;
      setState(() {
        for (var i = 0; i < translated.length; i++) {
          final idx = start + i;
          if (idx >= _items.length) break;
          final zh = translated[i];
          if (zh.isEmpty || zh == _items[idx].title) continue;
          _items[idx] = _items[idx].copyWith(title: zh);
        }
      });
    } catch (_) {}
  }

  Future<List<VideoItem>> _fetchItems(
    GenericSiteApi api,
    SiteTag tag, {
    required int page,
    required Set<String> exclude,
  }) {
    switch (widget.site.parserId ?? widget.site.id) {
      case 'pornhub':
        if (tag.id == 'hot' || tag.id == 'popular' || tag.id == 'best') {
          return context.read<PhubApi>().fetchRecommend(
                limit: 40,
                exclude: exclude,
              );
        }
        if (tag.id == 'asian') {
          return context.read<PhubApi>().fetchAsian(
                limit: 40,
                exclude: exclude,
              );
        }
        return context.read<PhubApi>().search(_queryForTag(tag.id), page: page);
      case 'xvideos':
        if (tag.id == 'hot' || tag.id == 'popular' || tag.id == 'best') {
          return context.read<XvideosApi>().fetchFeed(
                limit: 40,
                exclude: exclude,
              );
        }
        return context
            .read<XvideosApi>()
            .search(_queryForTag(tag.id), page: page);
      case 'mitao':
        if (tag.id == 'hot' || tag.id == 'popular' || tag.id == 'best') {
          return context.read<MitaoApi>().fetchZhong(
                limit: 40,
                exclude: exclude,
              );
        }
        return context
            .read<MitaoApi>()
            .search(_queryForTag(tag.id), page: page);
      case 'huangguo':
        return context.read<HuangGuoApi>().fetchFeed(
              tagId: tag.id,
              page: page,
              limit: 40,
              exclude: exclude,
            );
      default:
        return api.fetchFeed(
          widget.site,
          tagId: tag.id,
          page: page,
          limit: 40,
          exclude: exclude,
        );
    }
  }

  String _queryForTag(String id) => switch (id) {
        'new' => 'new',
        'asian' => 'asian',
        'amateur' => 'amateur',
        'couples' => 'couple',
        'mature' => 'mature',
        'japanese' => 'japanese',
        'chinese' => 'chinese',
        'korean' => 'korean',
        'cosplay' => 'cosplay',
        'massage' => 'massage',
        'office' => 'office',
        'uniform' => 'uniform',
        'story' => 'story',
        'short' => 'short',
        'long' => 'long',
        'hd' => 'HD',
        _ => id,
      };

  SearchSource get _playbackSource =>
      switch (widget.site.parserId ?? widget.site.id) {
        'pornhub' => SearchSource.ph,
        'xvideos' => SearchSource.x,
        'mitao' => SearchSource.zhong,
        'huangguo' => SearchSource.huangguo,
        _ => SearchSource.generic,
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Row(children: [
          SiteLogo(site: widget.site, size: 26),
          const SizedBox(width: 8),
          Expanded(child: Text('\u6807\u7b7e \u00b7 ${widget.site.name}')),
        ]),
      ),
      body: Row(children: [
        SizedBox(width: 92, child: _buildTagRail()),
        const VerticalDivider(width: 1, color: Colors.white10),
        Expanded(child: _buildResults()),
      ]),
    );
  }

  Widget _buildTagRail() => ListView.separated(
        padding: EdgeInsets.fromLTRB(
          8,
          10,
          8,
          180 + MediaQuery.viewPaddingOf(context).bottom,
        ),
        itemCount: _tags.length,
        separatorBuilder: (_, __) => const SizedBox(height: 7),
        itemBuilder: (_, i) {
          final tag = _tags[i];
          final selected = tag.id == _selected?.id;
          return InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _select(tag),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              height: 62,
              decoration: BoxDecoration(
                color: selected
                    ? const Color(0x33FF6B35)
                    : const Color(0xFF242424),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: selected ? const Color(0xFFFF6B35) : Colors.white10),
              ),
              child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(selected ? tag.iconSelected : tag.icon,
                        size: 21,
                        color: selected
                            ? const Color(0xFFFF6B35)
                            : Colors.white70),
                    const SizedBox(height: 3),
                    Text(tag.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            const TextStyle(color: Colors.white, fontSize: 11)),
                  ]),
            ),
          );
        },
      );

  Widget _buildResults() {
    if (_loading) {
      return const Center(
          child: CircularProgressIndicator(color: Color(0xFFFF6B35)));
    }
    if (_error != null) {
      return Center(
          child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white60))));
    }
    if (_selected == null) {
      return const Center(
          child: Text('\u4ece\u5de6\u4fa7\u9009\u62e9\u6807\u7b7e',
              style: TextStyle(color: Colors.white54)));
    }
    return ListView.builder(
      controller: _scroll,
      padding: EdgeInsets.only(
        top: 6,
        bottom: 180 + MediaQuery.viewPaddingOf(context).bottom,
      ),
      itemCount: _items.length + 1,
      itemBuilder: (_, i) {
        if (i == _items.length) {
          if (_loadingMore) {
            return const Padding(
                padding: EdgeInsets.all(18),
                child: Center(
                    child:
                        CircularProgressIndicator(color: Color(0xFFFF6B35))));
          }
          return Padding(
            padding: const EdgeInsets.all(18),
            child: Center(
                child: Text(
                    _hasMore
                        ? '\u7ee7\u7eed\u4e0b\u6ed1\u52a0\u8f7d'
                        : '\u5df2\u6ca1\u6709\u66f4\u591a\u5185\u5bb9',
                    style: const TextStyle(color: Colors.white38))),
          );
        }
        return VideoCard(
          item: _items[i],
          onTap: () => _openPlayer(i),
        );
      },
    );
  }

  Future<void> _openPlayer(int index) async {
    final items = List<VideoItem>.from(_items);
    if (widget.site.kind == SiteKind.live) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => VideoFeedScreen(
            site: widget.site,
            tagId: _selected?.id,
            initialItems: items,
            initialIndex: index,
            autoStart: true,
          ),
        ),
      );
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SearchFeedScreen(
          items: items,
          source: _playbackSource,
          initialIndex: index,
          title: widget.site.name,
          site: widget.site,
        ),
      ),
    );
  }
}

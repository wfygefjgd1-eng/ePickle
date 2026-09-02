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
        ? SourceCatalog.chaturbateDirectoryTags
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
        // Keep _hasMore: a transient error must NOT mislabel the end of the
        // list — the next scroll simply retries.
      });
    }
  }

  Future<void> _translateRange(int start, int generation) async {
    if (widget.site.kind == SiteKind.live) return;
    if (start < 0 || start >= _items.length) return;
    try {
      // Collect by index instead of sublist(): every load-more re-translates
      // the tail, so copying the tail per page would be O(n²).
      final titles = <String>[
        for (var i = start; i < _items.length; i++) _items[i].title,
      ];
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
        'big-ass' => 'big ass',
        'big-tits' => 'big tits',
        'big-dick' => 'big dick',
        'small-tits' => 'small tits',
        'red-head' => 'redhead',
        'step-fantasy' => 'step fantasy',
        'old-young' => 'old and young',
        'rough-sex' => 'rough sex',
        'solo-female' => 'solo female',
        'solo-male' => 'solo male',
        'pussy-licking' => 'pussy licking',
        'behind-the-scenes' => 'behind the scenes',
        'role-play' => 'role play',
        'cum-in-mouth' => 'cum in mouth',
        'facial' => 'facial',
        'handjob' => 'handjob',
        'blowjob' => 'blowjob',
        'footjob' => 'footjob',
        'creampie' => 'creampie',
        'anal' => 'anal',
        'lesbian' => 'lesbian',
        'hentai' => 'hentai',
        'milf' => 'milf',
        'ebony' => 'ebony',
        'latina' => 'latina',
        'indian' => 'indian',
        'russian' => 'russian',
        'french' => 'french',
        'german' => 'german',
        'italian' => 'italian',
        'brazilian' => 'brazilian',
        'thai' => 'thai',
        'vietnamese' => 'vietnamese',
        'filipina' => 'filipina',
        'teens' => 'teens',
        'teen' => 'teen',
        'bbw' => 'bbw',
        'chubby' => 'chubby',
        'pov' => 'pov',
        'threesome' => 'threesome',
        'gangbang' => 'gangbang',
        'squirt' => 'squirt',
        'fetish' => 'fetish',
        'bondage' => 'bondage',
        'bdsm' => 'bdsm',
        'tattoo' => 'tattoo',
        'vr' => 'vr',
        'webcam' => 'webcam',
        'vintage' => 'vintage',
        'public' => 'public',
        'orgy' => 'orgy',
        'toys' => 'toys',
        'striptease' => 'striptease',
        'transgender' => 'transgender',
        'interracial' => 'interracial',
        'bukkake' => 'bukkake',
        'cuckold' => 'cuckold',
        'compilation' => 'compilation',
        'casting' => 'casting',
        'celebrity' => 'celebrity',
        'pornstar' => 'pornstar',
        'petite' => 'petite',
        'blonde' => 'blonde',
        'brunette' => 'brunette',
        'redhead' => 'redhead',
        'funny' => 'funny',
        'reality' => 'reality',
        'party' => 'party',
        'school' => 'school',
        'hospital' => 'hospital',
        'nurse' => 'nurse',
        'teacher' => 'teacher',
        'doctor' => 'doctor',
        'pregnant' => 'pregnant',
        'hairy' => 'hairy',
        'shaven' => 'shaven',
        'feet' => 'feet',
        'foot-fetish' => 'foot fetish',
        'smoking' => 'smoking',
        'stockings' => 'stockings',
        'lingerie' => 'lingerie',
        'latex' => 'latex',
        'masturbation' => 'masturbation',
        'solo' => 'solo',
        'group' => 'group',
        'group-sex' => 'group sex',
        'double-penetration' => 'double penetration',
        'fisting' => 'fisting',
        'deepthroat' => 'deep throat',
        'deep-throat' => 'deep throat',
        'pissing' => 'pissing',
        'golden-shower' => 'golden shower',
        'gang-bang' => 'gang bang',
        'milf-lesbian' => 'milf lesbian',
        'asian-lesbian' => 'asian lesbian',
        'anal-lesbian' => 'anal lesbian',
        'granny' => 'granny',
        'cougar' => 'cougar',
        'older-woman' => 'older woman',
        'mother-daughter' => 'mother and daughter',
        'sister' => 'sister',
        'family' => 'family',
        'incest' => 'incest',
        'stepmom' => 'stepmom',
        'stepfather' => 'stepfather',
        'cartoon' => 'cartoon',
        '3d' => '3d',
        'animated' => 'animated',
        'game' => 'game',
        'celebrities' => 'celebrities',
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
      // 标签竖排靠左、可上下滑动，右侧显示所选标签的内容。
      // （v2.8.26 恢复：v2.8.20 曾把窄屏改成顶部横排，用户要求改回。）
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
                    Icon(
                        selected ? tag.iconSelected : tag.icon,
                        size: 21,
                        color: selected
                            ? const Color(0xFFFF6B35)
                            : Colors.white70),
                    const SizedBox(height: 3),
                    _buildTagLabel(tag),
                  ]),
            ),
          );
        },
      );

  Widget _buildTagLabel(SiteTag tag) => Text(
        tag.label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white, fontSize: 11),
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white60)),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: () {
                  final tag = _selected;
                  if (tag != null) {
                    unawaited(_select(tag));
                  }
                },
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('\u91cd\u8bd5'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFFF6B35),
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (_selected == null) {
      return const Center(
          child: Text('\u9009\u62e9\u6807\u7b7e\u67e5\u770b\u5185\u5bb9',
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

  // 双击防抖：同一卡片压栈两次会让第一次返回"看起来没反应"。
  bool _navLock = false;

  Future<void> _openPlayer(int index) async {
    if (_navLock) return;
    _navLock = true;
    try {
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
            // Keep the directory paged while the player feed is open: without
            // this the feed stops at the first page even though the directory
            // still has more pages to offer.
            onLoadMore: () async {
              if (!mounted) return const <VideoItem>[];
              // Route through _loadMore so the in-flight flag and generation
              // guard stay authoritative. A parallel duplicate fetch would
              // request the same page twice and race _hasMore.
              final oldLength = _items.length;
              await _loadMore();
              if (!mounted) return const <VideoItem>[];
              // _loadMore appends only; return the appended tail.
              if (_items.length <= oldLength) return const <VideoItem>[];
              return _items.sublist(oldLength);
            },
          ),
        ),
      );
    } finally {
      _navLock = false;
    }
  }
}

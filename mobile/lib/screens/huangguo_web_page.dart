import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/video_item.dart';
import '../services/huangguo_api.dart';
import '../services/source_catalog.dart';
import '../utils/playback_helpers.dart';
import 'search_feed_screen.dart';

/// 黄果短剧站内入口：仿 huangguoai.com web 移动端样式（卡片网格 + 频道导航 + 分页），
/// 无底部 Tab 栏，点卡片进入既有播放器。
class HuangGuoWebPage extends StatefulWidget {
  const HuangGuoWebPage({super.key, required this.site});
  final SiteDef site;

  @override
  State<HuangGuoWebPage> createState() => _HuangGuoWebPageState();
}

class _ChannelCache {
  _ChannelCache(this.items, this.page, this.hasMore, this.offset);
  final List<VideoItem> items;
  final int page;
  final bool hasMore;
  final double offset;
}

class _HuangGuoWebPageState extends State<HuangGuoWebPage> {
  static const _primary = Color(0xFFFFD21C);
  static const _channels = <(String, String)>[
    ('recommend', '首页'),
    ('duanju', 'AI成人短剧'),
    ('manju', 'AI成人漫剧'),
    ('huanlian', 'AI换脸'),
    ('mogai', 'AI魔改'),
    ('topics', '专题'),
    ('rank', '排行榜'),
  ];

  final _scroll = ScrollController();
  final _searchCtrl = TextEditingController();
  final _cache = <String, _ChannelCache>{};

  String _channel = 'recommend';
  String _query = '';
  List<VideoItem> _items = const [];
  int _page = 0;
  bool _hasMore = false;
  bool _loading = false;
  bool _loadingMore = false;
  String? _error;
  int _generation = 0;

  String get _channelName {
    for (final (id, name) in _channels) {
      if (id == _channel) return name;
    }
    return '黄果短剧';
  }

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  @override
  void dispose() {
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients || _scroll.position.extentAfter > 360) return;
    unawaited(_loadMore());
  }

  void _rememberCache() {
    if (_items.isEmpty) return;
    _cache[_channel] =
        _ChannelCache(_items, _page, _hasMore, _scroll.offset);
  }

  void _selectChannel(String id) {
    if (id == _channel && _query.isEmpty) return;
    _rememberCache();
    setState(() {
      _query = '';
      _searchCtrl.clear();
      _channel = id;
    });
    final cached = _cache[id];
    if (cached != null) {
      setState(() {
        _items = cached.items;
        _page = cached.page;
        _hasMore = cached.hasMore;
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
    final channel = _channel;
    final query = _query;
    setState(() {
      _loading = true;
      _loadingMore = false;
      _hasMore = false;
      _error = null;
    });
    try {
      final api = context.read<HuangGuoApi>();
      final List<VideoItem> list;
      if (query.isNotEmpty) {
        list = await api.search(query, page: 1);
      } else {
        list = await api.fetchFeed(tagId: channel, page: 1);
      }
      if (!mounted || generation != _generation) return;
      setState(() {
        _items = list;
        _page = 1;
        _hasMore = list.isNotEmpty;
        _loading = false;
        if (list.isEmpty) _error = '\u6682\u65e0\u53ef\u64ad\u653e\u7684\u5185\u5bb9';
      });
      if (_scroll.hasClients) _scroll.jumpTo(0);
    } catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = PlaybackHelpers.friendlyError(e);
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore) return;
    final generation = _generation;
    final channel = _channel;
    final query = _query;
    final page = _page;
    setState(() => _loadingMore = true);
    try {
      final api = context.read<HuangGuoApi>();
      final List<VideoItem> list;
      if (query.isNotEmpty) {
        list = await api.search(query, page: page + 1);
      } else {
        list = await api.fetchFeed(
          tagId: channel,
          page: page + 1,
          limit: 30,
          exclude: _items.map((item) => item.viewkey).toSet(),
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

  Future<void> _openPlayer(int index) async {
    final items = List<VideoItem>.from(_items);
    final title = _query.isEmpty ? _channelName : '\u641c\u7d22\u300a$_query\u300b';
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SearchFeedScreen(
          items: items,
          source: SearchSource.huangguo,
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
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            _buildNav(),
            _buildAnnounce(),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
      child: Row(
        children: [
          const Text(
            '\u9ec4\u679c\u77ed\u5267',
            style: TextStyle(
              color: _primary,
              fontSize: 21,
              fontWeight: FontWeight.w800,
              letterSpacing: 1,
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
                hintStyle: const TextStyle(color: Colors.white30, fontSize: 13),
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
                fillColor: const Color(0xFF1A1A1A),
                contentPadding: const EdgeInsets.symmetric(vertical: 9),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNav() {
    return SizedBox(
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        itemCount: _channels.length,
        separatorBuilder: (_, __) => const SizedBox(width: 22),
        itemBuilder: (_, i) {
          final (id, name) = _channels[i];
          final active = id == _channel && _query.isEmpty;
          return InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => _selectChannel(id),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  name,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                    color: active ? _primary : Colors.white70,
                  ),
                ),
                const SizedBox(height: 3),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: 18,
                  height: 2,
                  decoration: BoxDecoration(
                    color: active ? _primary : Colors.transparent,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildAnnounce() {
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xC716100C),
        border: Border.all(color: const Color(0x6BC48C30)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFFFF8A00), Color(0xFFFFD21A)],
              ),
              borderRadius: BorderRadius.all(Radius.circular(4)),
            ),
            child: const Text(
              '\u516c\u544a',
              style: TextStyle(
                color: Colors.black87,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              '\u6d77\u91cfAI\u6210\u4eba\u77ed\u5267 \u00b7 \u6f2b\u5267 \u00b7 \u6362\u8138 \u00b7 \u9b54\u6539 \u9ad8\u6e05\u514d\u8d39\u5728\u7ebf\u89c2\u770b',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Color(0xFFE8C96A), fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: _primary, strokeWidth: 2.5),
      );
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, color: Colors.white30, size: 40),
            const SizedBox(height: 10),
            Text(
              _error!,
              style: const TextStyle(color: Colors.white38, fontSize: 13),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 14),
            OutlinedButton(
              onPressed: () => unawaited(_load()),
              style: OutlinedButton.styleFrom(
                foregroundColor: _primary,
                side: const BorderSide(color: _primary),
              ),
              child: const Text('\u91cd\u8bd5'),
            ),
          ],
        ),
      );
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
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 230,
              mainAxisSpacing: 14,
              crossAxisSpacing: 10,
              childAspectRatio: 0.60,
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

  Widget _buildCard(VideoItem item, int index) {
    return GestureDetector(
      onTap: () => _openPlayer(index),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: AspectRatio(
              aspectRatio: 3 / 4,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _buildCover(item),
                  if (item.score != null)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: _badge(item.score!, color: _primary),
                    ),
                  if (item.badge != null)
                    Positioned(
                      bottom: 6,
                      right: 6,
                      child: _badge(item.badge!, color: Colors.white),
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
      return _coverPlaceholder();
    }
    return CachedNetworkImage(
      imageUrl: thumb,
      fit: BoxFit.cover,
      placeholder: (_, __) => _coverPlaceholder(),
      errorWidget: (_, __, ___) => _coverPlaceholder(),
    );
  }

  Widget _coverPlaceholder() {
    return Container(
      color: const Color(0xFF141414),
      child: const Center(
        child: Icon(Icons.movie_creation_outlined,
            color: Colors.white24, size: 28),
      ),
    );
  }

  Widget _badge(String text, {required Color color}) {
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
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: CircularProgressIndicator(color: _primary, strokeWidth: 2.5),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Center(
        child: Text(
          _hasMore ? '\u7ee7\u7eed\u6ed1\u52a8\u52a0\u8f7d' : '\u5df2\u6ca1\u6709\u66f4\u591a\u5185\u5bb9',
          style: const TextStyle(color: Colors.white30, fontSize: 12),
        ),
      ),
    );
  }
}

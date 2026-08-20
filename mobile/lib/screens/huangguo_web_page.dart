import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/video_item.dart';
import '../services/huangguo_api.dart';
import '../services/source_catalog.dart';
import '../utils/hg_cover_log.dart';
import '../utils/http_headers.dart';
import '../utils/native_browser_http.dart';
import '../utils/playback_helpers.dart';
import 'search_feed_screen.dart';

/// 黄果短剧站内入口：仿 huangguoai.com web 移动端样式（卡片网格 + 频道导航 + 分页），
/// 无底部 Tab 栏，点卡片进入既有播放器；[topicPath] 非空时直接进入专题列表页。
class HuangGuoWebPage extends StatefulWidget {
  const HuangGuoWebPage({
    super.key,
    required this.site,
    this.topicPath,
    this.topicTitle,
  });
  final SiteDef site;
  final String? topicPath;
  final String? topicTitle;

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
  String? _topicPath;
  String? _topicTitle;
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
    _topicPath = widget.topicPath;
    _topicTitle = widget.topicTitle;
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

  String get _cacheKey {
    if (_topicPath != null) return 'topic:$_topicPath';
    if (_query.isNotEmpty) return 'search:$_query';
    return 'channel:$_channel';
  }

  void _rememberCache() {
    if (_items.isEmpty) return;
    _cache[_cacheKey] = _ChannelCache(_items, _page, _hasMore, _scroll.offset);
  }

  void _selectChannel(String id) {
    if (id == _channel && _query.isEmpty && _topicPath == null) return;
    _rememberCache();
    setState(() {
      _query = '';
      _searchCtrl.clear();
      _channel = id;
      _topicPath = null;
      _topicTitle = null;
    });
    final cached = _cache[_cacheKey];
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
    final topic = _topicPath;
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
      } else if (topic != null) {
        list = await api.fetchTopicList(topic, page: 1);
      } else {
        list = await api.fetchFeed(tagId: channel, page: 1);
      }
      if (!mounted || generation != _generation) return;
      final thumbs = list
          .where((item) => item.thumb != null && item.thumb!.isNotEmpty)
          .length;
      HgCoverLog.add('load: channel=$channel query=$query topic=$topic '
          'items=${list.length} thumbs=$thumbs/${list.length} '
          'first=${list.isEmpty ? '-' : list.first.thumb}');
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
    final topic = _topicPath;
    final query = _query;
    final page = _page;
    setState(() => _loadingMore = true);
    try {
      final api = context.read<HuangGuoApi>();
      final List<VideoItem> list;
      if (query.isNotEmpty) {
        list = await api.search(query, page: page + 1);
      } else if (topic != null) {
        list = await api.fetchTopicList(topic, page: page + 1);
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
      setState(() {
        _loadingMore = false;
        // 专题无分页，翻页失败即止。
        if (topic != null) _hasMore = false;
      });
    }
  }

  Future<void> _openPlayer(int index) async {
    final item = _items[index];
    // 专题卡片：进入该专题的剧集列表页（复用本页）。
    if (item.url.contains('/topics/')) {
      final path = Uri.tryParse(item.url)?.path ?? '/topics/';
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => HuangGuoWebPage(
            site: widget.site,
            topicPath: path,
            topicTitle: item.title,
          ),
        ),
      );
      return;
    }
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
            if (_topicPath == null) _buildNav(),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final topic = _topicPath != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
      child: Row(
        children: [
          if (topic) ...[
            InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: () => Navigator.of(context).pop(),
              child: const Padding(
                padding: EdgeInsets.all(6),
                child: Icon(Icons.arrow_back_ios_new,
                    color: _primary, size: 18),
              ),
            ),
            const SizedBox(width: 2),
            Flexible(
              child: Text(
                _topicTitle ?? _topicPath ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: _primary,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ] else
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
    return _HgCover(key: ValueKey(thumb), url: thumb);
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

/// 黄果封面加载器：优先走原生 URLSession（部分 CDN 拒绝 Dart HttpClient 的 TLS
/// 指纹，webview 能显示而 Flutter 直连失败）；失败时记录日志并回退 dart:io 直连。
class _HgCover extends StatefulWidget {
  const _HgCover({super.key, required this.url});
  final String url;

  @override
  State<_HgCover> createState() => _HgCoverState();
}

class _HgCoverState extends State<_HgCover> {
  static final _mem = <String, Uint8List>{};
  static const _memLimit = 600;

  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    HgCoverLog.retrySignal.addListener(_onRetrySignal);
    final hit = _mem[widget.url];
    if (hit != null) {
      _bytes = hit;
    } else {
      unawaited(_loadNative());
    }
  }

  @override
  void dispose() {
    HgCoverLog.retrySignal.removeListener(_onRetrySignal);
    super.dispose();
  }

  void _onRetrySignal() {
    if (!mounted || _bytes != null) return;
    unawaited(_loadNative());
    if (mounted) setState(() {});
  }

  Future<void> _loadNative() async {
    HgCoverLog.add('cover native try: ${widget.url}');
    final bytes = await NativeBrowserHttp.getBytes(
      widget.url,
      headers: AppHttpHeaders.forMediaUrl(widget.url),
      timeout: const Duration(seconds: 8),
      aesKeyHex: HuangGuoApi.mediaAesKey,
      aesIvHex: HuangGuoApi.mediaAesIv,
    );
    if (!mounted) return;
    if (bytes != null && bytes.isNotEmpty) {
      final magic = bytes.length >= 2
          ? '${bytes[0].toRadixString(16).padLeft(2, '0')}'
            '${bytes[1].toRadixString(16).padLeft(2, '0')}'
          : 'short';
      final isJpeg = bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8;
      HgCoverLog.add(
        'cover native OK ${bytes.length}B magic=$magic ${isJpeg ? 'JPEG' : ''}: '
        '${widget.url}');
      _mem[widget.url] = bytes;
      if (_mem.length > _memLimit) {
        _mem.remove(_mem.keys.first);
      }
      setState(() => _bytes = bytes);
    } else {
      HgCoverLog.add('cover native FAILED: ${widget.url}');
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = _bytes;
    if (b != null) {
      return Image.memory(
        b,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) {
          HgCoverLog.add('cover decode error: ${widget.url}');
          return const ColoredBox(color: Color(0xFF141414));
        },
      );
    }
    return const ColoredBox(color: Color(0xFF141414));
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../models/video_item.dart';
import '../services/feed_list_cache.dart';
import '../services/generic_site_api.dart';
import '../services/layout_settings.dart';
import '../services/mitao_api.dart';
import '../services/phub_api.dart';
import '../services/source_catalog.dart';
import '../services/xvideos_api.dart';
import '../widgets/player_settings_sheet.dart';
import '../widgets/site_logo.dart';
import 'search_screen.dart';
import 'site_feed_page.dart';

/// Primary home: site list + bottom search (always multi-site).
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _searchCtrl = TextEditingController();
  final _focusNode = FocusNode();
  String _versionLabel = '';
  bool _prewarmStarted = false;

  @override
  void initState() {
    super.initState();
    _loadVersion();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_prewarmHomeFeeds());
    });
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final v = info.version.trim();
      if (!mounted || v.isEmpty) return;
      setState(() => _versionLabel = v);
    } catch (_) {}
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _openSite(SiteDef site) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SiteFeedPage(site: site)),
    );
  }

  void _onHomeSearch() {
    final q = _searchCtrl.text.trim();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SearchScreen(
          initialQuery: q.isEmpty ? null : q,
        ),
      ),
    );
  }

  void _openSettings() {
    showPlayerSettingsSheet(context);
  }

  Future<void> _removeSite(SiteDef site) async {
    final lay = context.read<LayoutSettings>();
    if (site.custom) {
      await lay.removeCustomUrl(site.primaryHost);
    } else {
      await lay.toggleVideoSite(site.id, false);
    }
  }

  Future<void> _prewarmHomeFeeds() async {
    if (_prewarmStarted || !mounted) return;
    _prewarmStarted = true;
    await Future<void>.delayed(const Duration(milliseconds: 450));
    if (!mounted) return;
    final sites = context
        .read<LayoutSettings>()
        .enabledVideoSites
        .where((s) => s.ready && s.tags.isNotEmpty)
        .take(3)
        .toList(growable: false);
    for (final site in sites) {
      if (!mounted) return;
      final tag = site.tags.first;
      final cacheKey = '${site.id}_${tag.id}';
      if (FeedListCache.peek(cacheKey) != null) continue;
      try {
        final list = await _fetchPrewarmList(site, tag);
        if (!mounted || list.isEmpty) continue;
        FeedListCache.put(
          cacheKey,
          FeedListSnapshot(
            items: list,
            seen: <String>{for (final item in list) item.viewkey},
            index: 0,
          ),
        );
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  Future<List<VideoItem>> _fetchPrewarmList(SiteDef site, SiteTag tag) {
    switch (site.id) {
      case 'pornhub':
        if (tag.id == 'asian') {
          return context.read<PhubApi>().fetchAsian(limit: 12, maxUrls: 2);
        }
        return context.read<PhubApi>().fetchRecommend(limit: 12, maxUrls: 2);
      case 'xvideos':
        return context.read<XvideosApi>().fetchFeed(limit: 12, maxUrls: 2);
      case 'mitao':
        return context.read<MitaoApi>().fetchZhong(limit: 12, maxPages: 2);
      default:
        return context.read<GenericSiteApi>().fetchFeed(
              site,
              tagId: tag.id,
              page: 1,
              limit: 12,
            );
    }
  }

  @override
  Widget build(BuildContext context) {
    final layout = context.watch<LayoutSettings>();
    final sites = layout.enabledVideoSites;
    final lives = layout.enabledLiveSites;
    final live = layout.liveSite ?? SourceCatalog.chaturbate;

    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        backgroundColor: Colors.black,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        title: Text(
          _versionLabel.isEmpty ? 'ePickle' : 'ePickle $_versionLabel',
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: Column(
        children: [
          _HomeSearchBar(
            controller: _searchCtrl,
            focusNode: _focusNode,
            onSearch: _onHomeSearch,
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              children: [
                for (final s in sites)
                  _SwipeSiteTile(
                    site: s,
                    onTap: () => _openSite(s),
                    onDelete: () => _removeSite(s),
                    subtitle: s.custom
                        ? '用户添加'
                        : (s.mirrors.length > 1
                            ? '${s.mirrors.length} 个域名'
                            : null),
                  ),
                if (lives.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.fromLTRB(4, 0, 4, 2),
                    child: Text(
                      '直播',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  ),
                  for (final s in lives)
                    _SwipeSiteTile(
                      site: s,
                      swipeEnabled: false,
                      onTap: () => _openSite(s),
                      onDelete: () {},
                      subtitle: s.mirrors.length > 1
                          ? '${s.mirrors.length} 个域名${s.id == live.id ? ' · 默认直播' : ''}'
                          : (s.id == live.id ? '默认直播' : null),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HomeSearchBar extends StatelessWidget {
  const _HomeSearchBar({
    required this.controller,
    required this.focusNode,
    required this.onSearch,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const ValueKey('home_search_bar'),
      color: Colors.black,
      elevation: 0,
      child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 5, 12, 5),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                ),
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => onSearch(),
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
              onPressed: onSearch,
              child: const Text('搜'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SwipeSiteTile extends StatelessWidget {
  const _SwipeSiteTile({
    required this.site,
    required this.onTap,
    required this.onDelete,
    this.subtitle,
    this.swipeEnabled = true,
  });

  final SiteDef site;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final String? subtitle;
  final bool swipeEnabled;

  @override
  Widget build(BuildContext context) {
    final tile = Card(
      color: const Color(0xFF2A2A2A),
      margin: const EdgeInsets.only(bottom: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
      ),
      child: SizedBox(
        height: 76,
        child: Center(
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            leading: SiteLogo(site: site, size: 40),
            title: Text(
              site.name,
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
            subtitle: subtitle == null
                ? null
                : Text(
                    subtitle!,
                    style: const TextStyle(color: Colors.white38, fontSize: 12),
                  ),
            trailing: const Icon(Icons.chevron_right, color: Colors.white38),
            onTap: onTap,
          ),
        ),
      ),
    );
    if (!swipeEnabled) return tile;
    return Dismissible(
      key: ValueKey('site_${site.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: const Color(0xFFB71C1C),
          borderRadius: BorderRadius.circular(18),
        ),
        child: const Icon(Icons.delete_outline, color: Colors.white),
      ),
      confirmDismiss: (_) async {
        return await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                backgroundColor: const Color(0xFF2A2A2A),
                title: Text(
                  '移除 ${site.name}？',
                  style: const TextStyle(color: Colors.white),
                ),
                content: const Text(
                  '可从设置里一键恢复频道列表。',
                  style: TextStyle(color: Colors.white70),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('取消'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text(
                      '移除',
                      style: TextStyle(color: Color(0xFFFF6B35)),
                    ),
                  ),
                ],
              ),
            ) ??
            false;
      },
      onDismissed: (_) => onDelete(),
      child: tile,
    );
  }
}

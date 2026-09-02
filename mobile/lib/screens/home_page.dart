import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../models/video_item.dart';
import '../services/app_settings.dart';
import '../services/feed_detail_cache.dart';
import '../services/feed_list_cache.dart';
import '../services/generic_site_api.dart';
import '../services/layout_settings.dart';
import '../services/media_prewarm.dart';
import '../services/mirror_ranker.dart';
import '../services/mitao_api.dart';
import '../services/phub_api.dart';
import '../services/source_catalog.dart';
import '../services/xvideos_api.dart';
import '../utils/playback_helpers.dart';
import '../widgets/player_settings_sheet.dart';
import '../widgets/site_logo.dart';
import 'search_screen.dart';
import 'huangguo_web_page.dart';
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
  bool _lastAggressive = false;
  AppSettings? _settings;
  Timer? _prewarmTimer;

  @override
  void initState() {
    super.initState();
    _prewarmStarted = false;
    _settings = context.read<AppSettings>();
    _lastAggressive = _settings!.aggressivePrewarm;
    _settings!.addListener(_onAppSettingsChanged);
    _loadVersion();    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Starts DURING the background domain probe (which fires at ~800ms),
      // not after it: the prewarm is light (2 site cards → list + first two
      // details each) and the probe now measures far fewer domains, so the
      // two waves share the pipe instead of queueing behind it. With 激进
      // 预加载 enabled the scope widens (all site cards, first video each).
      _prewarmTimer = Timer(const Duration(milliseconds: 600), () {
        if (mounted) unawaited(_prewarmHomeFeeds());
      });
    });
  }

  /// 激进预加载开关在设置里被切换：开 → 清掉普通预热暂存的快照，立即按
  /// 激进范围重跑（随机页站点才能拿到计划页）；关 → 释放全部预热解码器。
  void _onAppSettingsChanged() {
    final s = _settings;
    if (!mounted || s == null) return;
    if (s.aggressivePrewarm == _lastAggressive) return;
    _lastAggressive = s.aggressivePrewarm;
    if (s.aggressivePrewarm) {
      final layout = context.read<LayoutSettings>();
      for (final site in layout.enabledVideoSites) {
        if (site.tags.isEmpty) continue;
        FeedListCache.clear('${site.id}_${site.tags.first.id}');
      }
      _prewarmStarted = false;
      unawaited(_prewarmHomeFeeds());
    } else {
      MediaPrewarm.instance.setEnabled(false);
    }
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
    _prewarmTimer?.cancel();
    _prewarmTimer = null;
    _prewarmStarted = false;
    _settings?.removeListener(_onAppSettingsChanged);
    _settings = null;
    _searchCtrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // 快速双击会把同一个路由压栈两次（返回时"看起来没反应"）——按打开期间
  // 加锁的方式防抖：push 的 Future 在出栈时完成，完成后才解锁。
  bool _navLock = false;

  Future<void> _openSite(SiteDef site) async {
    if (_navLock) return;
    _navLock = true;
    try {
      if (site.id == 'huangguo') {
        // 黄果站内入口：网页版卡片网格页（无底部 Tab），点卡片进播放器。
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => HuangGuoWebPage(site: site)),
        );
        return;
      }
      await Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => SiteFeedPage(site: site)));
    } finally {
      _navLock = false;
    }
  }

  Future<void> _onHomeSearch() async {
    if (_navLock) return;
    _navLock = true;
    try {
      final q = _searchCtrl.text.trim();
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => SearchScreen(initialQuery: q.isEmpty ? null : q),
        ),
      );
    } finally {
      _navLock = false;
    }
  }

  void _openSettings() {
    showPlayerSettingsSheet(context);
  }

  Future<void> _removeSite(SiteDef site) async {
    final lay = context.read<LayoutSettings>();
    if (site.custom) {
      await lay.removeCustomUrl(site.primaryHost);
      return;
    }
    final removed = await lay.toggleVideoSite(site.id, false);
    if (!removed && mounted) {
      PlaybackHelpers.toast(context, '至少保留一个视频站点');
    }
  }

  Future<void> _prewarmHomeFeeds() async {
    if (_prewarmStarted || !mounted) return;
    // Don't spend network if the app was backgrounded within the delay.
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      // Not resumed yet — re-arm the timer once instead of silently dropping
      // the prewarm forever (a one-shot timer that fires during the brief
      // transition to resumed must not skip the warm cache permanently).
      _prewarmTimer = Timer(const Duration(milliseconds: 600), () {
        if (mounted) unawaited(_prewarmHomeFeeds());
      });
      return;
    }
    _prewarmStarted = true;
    final settings = _settings ?? context.read<AppSettings>();
    final aggressive = settings.aggressivePrewarm;
    MediaPrewarm.instance.setEnabled(aggressive);
    // 标准预热（与后台域名测速并行跑，600ms 即启动）：全部视频站点卡片
    // 并行，抓默认标签页列表并预热列表内全部卡片的详情页 —— 点进任何一张
    // 卡片都跳过详情网络请求。随机页站点（Jable 等）由预热"计划"随机页，
    // 信息流消费同一页再从下一页续抓，预热结果不再被随机化丢弃。
    // 激进预加载（开关，默认关）在此之上只追加一层：排最前的
    // [MediaPrewarm.maxWarmPlayers] 个站点，首条视频的解码器预缓冲。
    final sites = context
        .read<LayoutSettings>()
        .enabledVideoSites
        .where((s) => s.ready && s.tags.isNotEmpty)
        .toList(growable: false);
    // Independent site fetches run in parallel: one wave instead of a chain.
    await Future.wait(
      sites.asMap().entries.map((entry) async {
        final siteIndex = entry.key;
        final site = entry.value;
        if (!mounted) return;
        final tag = site.tags.first;
        final cacheKey = '${site.id}_${tag.id}';
        if (FeedListCache.take(cacheKey) != null) return;
        final randomized = SourceCatalog.usesRandomizedGenericFeed(site);
        try {
          // 随机页站点的计划页由这里随机选好（每次预热运行都不同），
          // 信息流 initState 消费同一页并从下一页续抓。
          final page = randomized ? 1 + Random().nextInt(10) : 1;
          final list = await _fetchPrewarmList(site, tag, page: page);
          if (!mounted || list.isEmpty) return;
          FeedListCache.put(
            cacheKey,
            FeedListSnapshot(
              items: list,
              seen: <String>{for (final item in list) item.viewkey},
              index: 0,
              sourcePage: randomized ? page : null,
            ),
          );
          // Warm EVERY card's detail in the staged list, sequentially per
          // site (one request per host at a time; the sites themselves run
          // in parallel). Backgrounding the app stops the walk early.
          for (var i = 0; i < list.length; i++) {
            if (!mounted ||
                WidgetsBinding.instance.lifecycleState !=
                    AppLifecycleState.resumed) {
              return;
            }
            final detail = await _prewarmDetail(site, list[i]);
            if (aggressive &&
                i == 0 &&
                detail != null &&
                siteIndex < MediaPrewarm.maxWarmPlayers) {
              // Fire-and-forget：预热失败静默放弃，播放页自动走冷启动。
              unawaited(MediaPrewarm.instance.warm(
                site: site,
                item: list[i],
                detail: detail,
                qualityCap: settings.qualityCap,
              ));
            }
          }
        } catch (_) {}
      }),
    );
  }

  /// Prefetch one item's detail into [FeedDetailCache]; returns the fetched
  /// detail (null on skip/failure) so the aggressive path can chain the
  /// decoder prewarm onto it.
  ///
  /// Routing MUST mirror the player screens' `_fetchDetail` (URL-based
  /// overrides first, then the site's own parser): caching a detail parsed
  /// with the wrong site's rules would poison the feed's playback.
  Future<VideoDetail?> _prewarmDetail(SiteDef site, VideoItem item) async {
    final low = item.url.toLowerCase();
    try {
      final Future<VideoDetail> fetch;
      if (low.contains('huangguoai')) {
        // HuangGuo detail/episode flow lives in HuangGuoWebPage — skip.
        return null;
      } else if (low.contains('xvideos.com') || low.contains('xvideos.es')) {
        fetch = context.read<XvideosApi>().getVideoDetail(item.url);
      } else if (low.contains('mitaohk.com')) {
        fetch = context.read<MitaoApi>().getVideoDetail(item.url);
      } else if (low.contains('pornhub.com') || low.contains('pornhub.org')) {
        fetch = context.read<PhubApi>().getVideoDetail(item.url);
      } else if (site.id == 'pornhub' ||
          site.id == 'xvideos' ||
          site.id == 'mitao') {
        // Built-in card item that stayed on its own host family.
        fetch = switch (site.id) {
          'pornhub' => context.read<PhubApi>().getVideoDetail(item.url),
          'xvideos' => context.read<XvideosApi>().getVideoDetail(item.url),
          _ => context.read<MitaoApi>().getVideoDetail(item.url),
        };
      } else {
        // Generic sites: the screens parse a URL that points at another
        // catalog site with THAT site's rules — never prewarm those, the
        // cached detail could carry the wrong parser's streams.
        SiteDef? hostSite;
        for (final s in SourceCatalog.all) {
          if (s.kind != SiteKind.video) continue;
          final hit = s.mirrors.any((m) {
            final h = Uri.tryParse(m)?.host.toLowerCase() ?? '';
            return h.isNotEmpty && low.contains(h);
          });
          if (hit) {
            hostSite = s;
            break;
          }
        }
        if (hostSite != null && hostSite.id != site.id) return null;
        fetch = context.read<GenericSiteApi>().getVideoDetail(site, item.url);
      }
      final detail = await fetch;
      if (!detail.countryBlocked && !detail.unavailable) {
        FeedDetailCache.put(item.url, detail);
      }
      return detail;
    } catch (_) {
      return null;
    }
  }

  Future<List<VideoItem>> _fetchPrewarmList(
    SiteDef site,
    SiteTag tag, {
    int page = 1,
  }) {
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
      case 'huangguo':
        // HuangGuo opens HuangGuoWebPage, which does not consume
        // FeedListCache — skip prewarm so we never spend network on a cache
        // nobody reads.
        return Future.value(const <VideoItem>[]);
      default:
        return context.read<GenericSiteApi>().fetchFeed(
          site,
          tagId: tag.id,
          page: page,
          limit: 12,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Watch the settings — enabledVideoSites / enabledLiveSites are derived
    // getters that build a new List on every call, so context.select can't
    // memoise them. Watching is fine here because the home screen is the
    // smallest list and it is also the source-of-truth for those toggles.
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
      body: Stack(
        children: [
          Column(
            children: [
              _HomeSearchBar(
                controller: _searchCtrl,
                focusNode: _focusNode,
                onSearch: _onHomeSearch,
              ),
              Expanded(
                // 探测结束（true→false）时重建一次，卡片据此刷新"域名异常"置灰。
                child: ValueListenableBuilder<bool>(
                  valueListenable: MirrorRanker.instance.probing,
                  builder: (context, _, __) => ListView(
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
                          down: MirrorRanker.instance.isSiteDown(s),
                          onLongPress: () => _showMirrorOverrideDialog(s),
                        ),
                      if (lives.isNotEmpty) ...[
                        const Padding(
                          padding: EdgeInsets.fromLTRB(4, 0, 4, 2),
                          child: Text(
                            '直播',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 12,
                            ),
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
              ),
            ],
          ),
          // 域名测速悬浮提示：正在后台探测最快域名时显示在左上角，
          // 探测结束自动消失 —— 左上角没有它 = 测速已完成，可正常使用。
          Positioned(top: 6, left: 6, child: _MirrorProbeBadge()),
        ],
      ),
    );
  }
  /// 长按卡片手动更换站点域名（设置开关开启时才可用）。
  /// 保存后走 MirrorRanker 持久化存储，重启仍生效；立即用于后续抓取。
  Future<void> _showMirrorOverrideDialog(SiteDef site) async {
    if (!mounted) return;
    final settings = context.read<AppSettings>();
    if (!settings.manualMirrorEnabled) return;
    final ranker = MirrorRanker.instance;
    final current = ranker.manualBase(site.id);
    final ctrl = TextEditingController(text: current ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: Text('更换 ${site.name} 域名',
            style: const TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              current == null
                  ? '输入一个新的域名（如 https://新域名.com），保存后立即生效并跨重启保留。'
                  : '当前手动域名：$current',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: TextInputType.url,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: const InputDecoration(
                hintText: 'https://example.com',
                hintStyle: TextStyle(color: Colors.white24),
                filled: true,
                fillColor: Color(0xFF1E1E1E),
                isDense: true,
                border: OutlineInputBorder(borderSide: BorderSide.none),
              ),
            ),
          ],
        ),
        actions: [
          if (current != null)
            TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: const Text('清除',
                  style: TextStyle(color: Colors.white54)),
            ),
          TextButton(
            onPressed: () => Navigator.pop(dctx, null),
            child: const Text('取消', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dctx, true),
            child:
                const Text('保存', style: TextStyle(color: Color(0xFFFF6B35))),
          ),
        ],
      ),
    );
    if (saved == null) return;
    if (!saved) {
      await ranker.clearManualBasePersisted(site.id);
      if (mounted) setState(() {});
      return;
    }
    // 规范化：补 scheme、去结尾斜杠，必须能解析出 host。
    var value = ctrl.text.trim();
    if (value.isEmpty) return;
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      value = 'https://$value';
    }
    final uri = Uri.tryParse(value);
    if (uri == null || uri.host.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('域名格式不对，请检查后重试'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }
    final normalized = value.replaceAll(RegExp(r'/$'), '');
    await ranker.setManualBasePersisted(site.id, normalized);
    if (mounted) setState(() {});
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
                style: const TextStyle(color: Colors.white, fontSize: 15),
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
    this.down = false,
    this.onLongPress,
  });

  final SiteDef site;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final String? subtitle;
  final bool swipeEnabled;
  // 所有域名都在失败 streak：置灰展示，提示用户该站域名有问题。
  final bool down;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final effectiveSubtitle = down
        ? '域名异常，长按卡片可更换域名'
        : subtitle;
    final tile = RepaintBoundary(
      child: Card(
        color: down ? const Color(0xFF161616) : const Color(0xFF2A2A2A),
        margin: const EdgeInsets.only(bottom: 6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: SizedBox(
          height: 76,
          child: Center(
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              leading: Opacity(
                opacity: down ? 0.35 : 1.0,
                child: SiteLogo(site: site, size: 40),
              ),
              title: Text(
                site.name,
                style: TextStyle(
                  color: down ? Colors.white54 : Colors.white,
                  fontSize: 16,
                ),
              ),
              subtitle: effectiveSubtitle == null
                  ? null
                  : Text(
                      effectiveSubtitle,
                      style: TextStyle(
                        color: down
                            ? const Color(0xFFC69A55)
                            : Colors.white38,
                        fontSize: 12,
                      ),
                    ),
              trailing: down
                  ? const Icon(
                      Icons.cloud_off_outlined,
                      color: Color(0xFFC69A55),
                      size: 22,
                    )
                  : const Icon(Icons.chevron_right, color: Colors.white38),
              onTap: onTap,
              onLongPress: onLongPress,
            ),
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

/// 域名测速进行中的左上角悬浮小标：探测结束（或无需探测）时自动消失。
class _MirrorProbeBadge extends StatelessWidget {
  const _MirrorProbeBadge();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: MirrorRanker.instance.probing,
      builder: (context, probing, _) {
        if (!probing) return const SizedBox.shrink();
        return Material(
          color: const Color(0xD91E1E1E),
          borderRadius: BorderRadius.circular(16),
          elevation: 3,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Color(0xFFFF6B35),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '正在测速最快域名…',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.85),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

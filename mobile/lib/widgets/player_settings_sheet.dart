import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../services/app_settings.dart';
import '../services/cache_manager.dart';
import '../services/layout_settings.dart';
import '../services/watch_history.dart';
import '../utils/privacy_wipe.dart';
import '../screens/hidden_sites_page.dart';

/// Settings: quality + restore channels (no proxy / global-search toggles).
Future<void> showPlayerSettingsSheet(
  BuildContext context, {
  VoidCallback? onQualityChanged,
  VoidCallback? onFastForward,
  List<int>? qualityHeights,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    enableDrag: false,
    isDismissible: true,
    backgroundColor: const Color(0xFF1E1E1E),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
    ),
    builder: (ctx) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
          child: Consumer2<AppSettings, LayoutSettings>(
            builder: (_, settings, layout, __) {
              final heights = <int>{
                0,
                ...(qualityHeights ?? const [360, 480, 720, 1080]),
              };
              final options = heights.toList()..sort();
              double topPull = 0;
              return NotificationListener<ScrollNotification>(
                onNotification: (notification) {
                  if (notification is ScrollStartNotification) {
                    topPull = 0;
                  } else if (notification is OverscrollNotification &&
                      notification.overscroll < 0) {
                    // Clamping physics (Android): incremental top overscroll.
                    topPull += -notification.overscroll;
                  } else if (notification is ScrollUpdateNotification) {
                    final m = notification.metrics;
                    // Bouncing physics (iOS): track deepest top overscroll.
                    final over = m.minScrollExtent - m.pixels;
                    if (over > topPull) topPull = over;
                  }
                  if (topPull >= 60) {
                    topPull = double.infinity;
                    final route = ModalRoute.of(ctx);
                    if (route != null && route.isCurrent) {
                      Navigator.of(ctx).pop();
                    }
                  }
                  return false;
                },
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 36,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 24, bottom: 6),
                        child: ListTile(
                          title: const Text(
                            '设置',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                            ),
                          ),
                          dense: true,
                          trailing: IconButton(
                            icon: const Icon(
                              Icons.close,
                              color: Colors.white70,
                            ),
                            tooltip: '返回',
                            onPressed: () => Navigator.pop(ctx),
                          ),
                        ),
                      ),
                      _GroupCard(
                        children: [
                          _SkipIntroGroup(settings: settings),
                          SwitchListTile(
                            title: const Text(
                              '自动横屏',
                              style: TextStyle(color: Colors.white),
                            ),
                            subtitle: const Text(
                              '接近完全横置才进、明显竖回才出。',
                              style: TextStyle(
                                color: Colors.white38,
                                fontSize: 12,
                              ),
                            ),
                            activeThumbColor: const Color(0xFFFF6B35),
                            value: settings.autoRotate,
                            onChanged: settings.setAutoRotate,
                          ),
                          SwitchListTile(
                            title: const Text(
                              '卡顿自动降画质',
                              style: TextStyle(color: Colors.white),
                            ),
                            subtitle: const Text(
                              '播放卡顿时自动切更低清晰度（仅本条）。',
                              style: TextStyle(
                                color: Colors.white38,
                                fontSize: 12,
                              ),
                            ),
                            activeThumbColor: const Color(0xFFFF6B35),
                            value: settings.autoLowerOnStall,
                            onChanged: settings.setAutoLowerOnStall,
                          ),
                        ],
                      ),
                      _GroupExpansion(
                        title: '画质',
                        subtitle: Text(
                          '当前 ${settings.qualityCap == 0 ? '自动' : '${settings.qualityCap}p'}',
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 12,
                          ),
                        ),
                        children: [
                          for (final h in options)
                            ListTile(
                              dense: true,
                              contentPadding: const EdgeInsets.only(
                                left: 36,
                                right: 24,
                              ),
                              title: Text(
                                h == 0 ? '自动（偏好 ≤720p）' : '${h}p',
                                style: const TextStyle(color: Colors.white),
                              ),
                              trailing: settings.qualityCap == h
                                  ? const Icon(
                                      Icons.check,
                                      color: Color(0xFFFF6B35),
                                    )
                                  : null,
                              onTap: () async {
                                await settings.setQualityCap(h);
                                onQualityChanged?.call();
                              },
                            ),
                        ],
                      ),
                      if (defaultTargetPlatform == TargetPlatform.iOS) ...[
                        _GroupExpansion(
                          title: '按钮显示',
                          subtitle: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '${[settings.showSiteBackButton, settings.showSearchBackButton, settings.showFullscreenButton, settings.showMuteButton, settings.showFastForwardButton].where((b) => b).length}/5',
                                style: const TextStyle(
                                  color: Colors.white38,
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(width: 10),
                              const Icon(
                                Icons.arrow_back,
                                color: Colors.white38,
                                size: 16,
                              ),
                              const SizedBox(width: 6),
                              const Icon(
                                Icons.fullscreen,
                                color: Colors.white38,
                                size: 16,
                              ),
                              const SizedBox(width: 6),
                              const Icon(
                                Icons.volume_up,
                                color: Colors.white38,
                                size: 16,
                              ),
                              const SizedBox(width: 6),
                              const Icon(
                                Icons.forward_30,
                                color: Colors.white38,
                                size: 16,
                              ),
                            ],
                          ),
                          children: [
                            SwitchListTile(
                              dense: true,
                              contentPadding: const EdgeInsets.only(
                                left: 36,
                                right: 24,
                              ),
                              title: const Text(
                                '站点页返回按钮',
                                style: TextStyle(color: Colors.white),
                              ),
                              subtitle: const Text(
                                '控制左上角返回按钮的显示与隐藏',
                                style: TextStyle(
                                  color: Colors.white38,
                                  fontSize: 12,
                                ),
                              ),
                              activeThumbColor: const Color(0xFFFF6B35),
                              value: settings.showSiteBackButton,
                              onChanged: settings.setShowSiteBackButton,
                            ),
                            SwitchListTile(
                              dense: true,
                              contentPadding: const EdgeInsets.only(
                                left: 36,
                                right: 24,
                              ),
                              title: const Text(
                                '搜索页返回按钮',
                                style: TextStyle(color: Colors.white),
                              ),
                              subtitle: const Text(
                                '控制播放页左上角返回按钮的显示与隐藏',
                                style: TextStyle(
                                  color: Colors.white38,
                                  fontSize: 12,
                                ),
                              ),
                              activeThumbColor: const Color(0xFFFF6B35),
                              value: settings.showSearchBackButton,
                              onChanged: settings.setShowSearchBackButton,
                            ),
                            SwitchListTile(
                              dense: true,
                              contentPadding: const EdgeInsets.only(
                                left: 36,
                                right: 24,
                              ),
                              title: const Text(
                                '全屏按钮',
                                style: TextStyle(color: Colors.white),
                              ),
                              subtitle: const Text(
                                '控制右上角全屏按钮的显示与隐藏',
                                style: TextStyle(
                                  color: Colors.white38,
                                  fontSize: 12,
                                ),
                              ),
                              activeThumbColor: const Color(0xFFFF6B35),
                              value: settings.showFullscreenButton,
                              onChanged: settings.setShowFullscreenButton,
                            ),
                            SwitchListTile(
                              dense: true,
                              contentPadding: const EdgeInsets.only(
                                left: 36,
                                right: 24,
                              ),
                              title: const Text(
                                '声音按钮',
                                style: TextStyle(color: Colors.white),
                              ),
                              subtitle: const Text(
                                '控制右下角声音按钮的显示与隐藏',
                                style: TextStyle(
                                  color: Colors.white38,
                                  fontSize: 12,
                                ),
                              ),
                              activeThumbColor: const Color(0xFFFF6B35),
                              value: settings.showMuteButton,
                              onChanged: settings.setShowMuteButton,
                            ),
                            SwitchListTile(
                              dense: true,
                              contentPadding: const EdgeInsets.only(
                                left: 36,
                                right: 24,
                              ),
                              title: const Text(
                                '快进 30 秒按钮',
                                style: TextStyle(color: Colors.white),
                              ),
                              subtitle: const Text(
                                '控制设置面板里“快进 30 秒”入口的显示',
                                style: TextStyle(
                                  color: Colors.white38,
                                  fontSize: 12,
                                ),
                              ),
                              activeThumbColor: const Color(0xFFFF6B35),
                              value: settings.showFastForwardButton,
                              onChanged: settings.setShowFastForwardButton,
                            ),
                            if (onFastForward != null &&
                                settings.showFastForwardButton)
                              ListTile(
                                dense: true,
                                contentPadding: const EdgeInsets.only(
                                  left: 36,
                                  right: 24,
                                ),
                                leading: const Icon(
                                  Icons.forward_30,
                                  color: Color(0xFFFF6B35),
                                ),
                                title: const Text(
                                  '立即快进 30 秒',
                                  style: TextStyle(color: Colors.white),
                                ),
                                onTap: () {
                                  Navigator.pop(ctx);
                                  onFastForward();
                                },
                              ),
                          ],
                        ),
                      ],
                      _GroupCard(
                        children: [
                          ListTile(
                            leading: const Icon(
                              Icons.add_link,
                              color: Color(0xFFFF6B35),
                            ),
                            title: const Text(
                              '添加网站',
                              style: TextStyle(color: Colors.white),
                            ),
                            subtitle: const Text(
                              '选择点播通用解析，或 Stripchat / Chaturbate 直播解析',
                              style: TextStyle(
                                color: Colors.white38,
                                fontSize: 12,
                              ),
                            ),
                            trailing: const Icon(
                              Icons.chevron_right,
                              color: Colors.white38,
                            ),
                            onTap: () => _showAddSiteDialog(ctx, layout),
                          ),
                          ListTile(
                            leading: const Icon(
                              Icons.visibility_off_outlined,
                              color: Color(0xFFFF6B35),
                            ),
                            title: const Text(
                              '隐藏网站',
                              style: TextStyle(color: Colors.white),
                            ),
                            subtitle: const Text(
                              '管理主页和搜索中显示的网站',
                              style: TextStyle(
                                color: Colors.white38,
                                fontSize: 12,
                              ),
                            ),
                            trailing: const Icon(
                              Icons.chevron_right,
                              color: Colors.white38,
                            ),
                            onTap: () => Navigator.of(ctx).push(
                              MaterialPageRoute(
                                builder: (_) => const HiddenSitesPage(),
                              ),
                            ),
                          ),
                          ListTile(
                            title: const Text(
                              '一键恢复频道',
                              style: TextStyle(color: Colors.white),
                            ),
                            subtitle: const Text(
                              '恢复默认网站列表与直播入口（不改画质）。',
                              style: TextStyle(
                                color: Colors.white38,
                                fontSize: 12,
                              ),
                            ),
                            trailing: const Icon(
                              Icons.restart_alt,
                              color: Color(0xFFFF6B35),
                            ),
                            onTap: () async {
                              final ok =
                                  await showDialog<bool>(
                                    context: ctx,
                                    builder: (d) => AlertDialog(
                                      backgroundColor: const Color(0xFF2A2A2A),
                                      title: const Text(
                                        '恢复默认频道？',
                                        style: TextStyle(color: Colors.white),
                                      ),
                                      content: const Text(
                                        '将重置主页网站列表与默认直播源。',
                                        style: TextStyle(color: Colors.white70),
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(d, false),
                                          child: const Text('取消'),
                                        ),
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(d, true),
                                          child: const Text(
                                            '恢复',
                                            style: TextStyle(
                                              color: Color(0xFFFF6B35),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ) ??
                                  false;
                              if (!ok) return;
                              await layout.restoreDefaultLayout();
                              if (ctx.mounted) {
                                Navigator.pop(ctx);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('已恢复默认频道'),
                                    behavior: SnackBarBehavior.floating,
                                  ),
                                );
                              }
                            },
                          ),
                        ],
                      ),
                      if (layout.customSites.isNotEmpty)
                        for (final custom in layout.customSites)
                          ListTile(
                            dense: true,
                            leading: Icon(
                              custom.kind.name == 'live'
                                  ? Icons.live_tv
                                  : Icons.movie_outlined,
                              color: Colors.white54,
                            ),
                            title: Text(
                              custom.site.name,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 13,
                              ),
                            ),
                            subtitle: Text(
                              _customParserLabel(custom.parser),
                              style: const TextStyle(
                                color: Colors.white38,
                                fontSize: 11,
                              ),
                            ),
                            trailing: IconButton(
                              icon: const Icon(
                                Icons.delete_outline,
                                color: Colors.white54,
                              ),
                              tooltip: '删除',
                              onPressed: () =>
                                  layout.removeCustomUrl(custom.url),
                            ),
                          ),
                      if (defaultTargetPlatform == TargetPlatform.iOS)
                        _GroupCard(
                          children: [
                            ListTile(
                              title: const Text(
                                '黄果短剧域名',
                                style: TextStyle(color: Colors.white),
                              ),
                              subtitle: Text(
                                settings.huangguoDomain,
                                style: const TextStyle(
                                  color: Colors.white38,
                                  fontSize: 12,
                                ),
                              ),
                              trailing: const Icon(
                                Icons.edit_location_alt,
                                color: Color(0xFFFF6B35),
                              ),
                              onTap: () =>
                                  _showHuangguoDomainDialog(ctx, settings),
                            ),
                          ],
                        ),
                      _GroupCard(
                        children: [
                          ListTile(
                            title: const Text(
                              '清除痕迹并退出',
                              style: TextStyle(color: Colors.white),
                            ),
                            subtitle: const Text(
                              '清理 WebView 缓存、Cookie、应用数据后退出。',
                              style: TextStyle(
                                color: Colors.white38,
                                fontSize: 12,
                              ),
                            ),
                            trailing: const Icon(
                              Icons.cleaning_services,
                              color: Color(0xFFFF6B35),
                            ),
                            onTap: () async {
                              final ok =
                                  await showDialog<bool>(
                                    context: ctx,
                                    builder: (d) => AlertDialog(
                                      backgroundColor: const Color(0xFF2A2A2A),
                                      title: const Text(
                                        '清除痕迹？',
                                        style: TextStyle(color: Colors.white),
                                      ),
                                      content: const Text(
                                        '将清理所有 WebView 缓存、Cookie、观看历史和应用数据后退出。',
                                        style: TextStyle(color: Colors.white70),
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(d, false),
                                          child: const Text('取消'),
                                        ),
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(d, true),
                                          child: const Text(
                                            '清理并退出',
                                            style: TextStyle(
                                              color: Color(0xFFFF6B35),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ) ??
                                  false;
                              if (!ok) return;
                              if (!ctx.mounted) return;
                              await ctx.read<WatchHistory>().clear();
                              await CacheManager.clearAllCache();
                              if (ctx.mounted) Navigator.pop(ctx);
                              await PrivacyWipe.nuclearWipe();
                              await PrivacyWipe.exitApp();
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      const Divider(color: Colors.white12),
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.only(bottom: 8),
                          child: _AppVersionLabel(),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      );
    },
  );
}

class _AppVersionLabel extends StatefulWidget {
  const _AppVersionLabel();

  @override
  State<_AppVersionLabel> createState() => _AppVersionLabelState();
}

/// 紧凑的可折叠设置分组：一行标题（可带当前值摘要），点开才露出子项，
/// 收起时面板保持干净。默认收起。
class _GroupExpansion extends StatelessWidget {
  const _GroupExpansion({
    required this.title,
    this.subtitle,
    required this.children,
  });

  final String title;
  final Widget? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        initiallyExpanded: false,
        tilePadding: const EdgeInsets.symmetric(horizontal: 8),
        childrenPadding: const EdgeInsets.only(bottom: 4),
        iconColor: Colors.white38,
        collapsedIconColor: Colors.white38,
        shape: const Border(),
        collapsedShape: const Border(),
        title: Text(
          title,
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
        subtitle: subtitle,
        children: children,
      ),
    );
  }
}

Future<void> _showAddSiteDialog(
  BuildContext context,
  LayoutSettings layout,
) async {
  final urlController = TextEditingController();
  var parser = 'generic_vod';
  final result = await showDialog<String>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: const Text('添加网站', style: TextStyle(color: Colors.white)),
        content: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.62,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: urlController,
                  keyboardType: TextInputType.url,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: '网站地址',
                    hintText: 'example.com',
                    labelStyle: TextStyle(color: Colors.white70),
                    hintStyle: TextStyle(color: Colors.white38),
                  ),
                ),
                const SizedBox(height: 14),
                DropdownButtonFormField<String>(
                  initialValue: parser,
                  dropdownColor: const Color(0xFF3A3A3A),
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: '解析方式',
                    labelStyle: TextStyle(color: Colors.white70),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'generic_vod',
                      child: Text('点播 · 通用解析'),
                    ),
                    DropdownMenuItem(
                      value: 'pornhub',
                      child: Text('点播 · Pornhub 解析'),
                    ),
                    DropdownMenuItem(
                      value: 'xvideos',
                      child: Text('点播 · XVideos 解析'),
                    ),
                    DropdownMenuItem(
                      value: 'mitao',
                      child: Text('点播 · Mitao 解析'),
                    ),
                    DropdownMenuItem(
                      value: 'huangguo',
                      child: Text('点播 · 黄果短剧 解析'),
                    ),
                    DropdownMenuItem(
                      value: 'xnxx',
                      child: Text('点播 · XNXX 解析'),
                    ),
                    DropdownMenuItem(
                      value: 'xhamster',
                      child: Text('点播 · xHamster 解析'),
                    ),
                    DropdownMenuItem(
                      value: 'tnaflix',
                      child: Text('点播 · TNAFlix 解析'),
                    ),
                    DropdownMenuItem(
                      value: 'jable',
                      child: Text('点播 · Jable 解析'),
                    ),
                    DropdownMenuItem(
                      value: 'stripchat',
                      child: Text('直播 · Stripchat'),
                    ),
                    DropdownMenuItem(
                      value: 'chaturbate',
                      child: Text('直播 · Chaturbate'),
                    ),
                  ],
                  onChanged: (value) =>
                      setState(() => parser = value ?? parser),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final raw = urlController.text.trim();
              final uri = Uri.tryParse(
                raw.startsWith('http') ? raw : 'https://$raw',
              );
              if (uri == null || uri.host.isEmpty || uri.scheme != 'https') {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('请输入有效的 HTTPS 网站地址')),
                );
                return;
              }
              Navigator.pop(dialogContext, '$parser\n${uri.toString()}');
            },
            child: const Text('添加'),
          ),
        ],
      ),
    ),
  );
  urlController.dispose();
  if (result == null) return;
  final split = result.split('\n');
  if (split.length != 2) return;
  await layout.addCustomSite(split[1], parser: split[0]);
}

Future<void> _showHuangguoDomainDialog(
  BuildContext context,
  AppSettings settings,
) async {
  final controller = TextEditingController(
    text: settings.huangguoDomain.replaceAll(RegExp(r'^https?://'), ''),
  );
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: const Color(0xFF2A2A2A),
      title: const Text('黄果短剧域名', style: TextStyle(color: Colors.white)),
      content: TextField(
        controller: controller,
        keyboardType: TextInputType.url,
        style: const TextStyle(color: Colors.white),
        decoration: const InputDecoration(
          labelText: '域名',
          hintText: 'huangguoai.com',
          labelStyle: TextStyle(color: Colors.white70),
          hintStyle: TextStyle(color: Colors.white38),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            settings.resetHuangguoDomain();
            Navigator.pop(dialogContext);
          },
          child: const Text('重置'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            settings.setHuangguoDomain(controller.text.trim());
            Navigator.pop(dialogContext);
          },
          child: const Text('保存'),
        ),
      ],
    ),
  );
  controller.dispose();
}

String _customParserLabel(String parser) => switch (parser) {
  'generic_vod' => '点播 · 通用解析',
  'pornhub' => '点播 · Pornhub 解析',
  'xvideos' => '点播 · XVideos 解析',
  'mitao' => '点播 · Mitao 解析',
  'huangguo' => '点播 · 黄果短剧 解析',
  'xnxx' => '点播 · XNXX 解析',
  'xhamster' => '点播 · xHamster 解析',
  'tnaflix' => '点播 · TNAFlix 解析',
  'jable' => '点播 · Jable 解析',
  'stripchat' => '直播 · Stripchat',
  'chaturbate' => '直播 · Chaturbate',
  _ => parser,
};

class _AppVersionLabelState extends State<_AppVersionLabel> {
  String _label = '';

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform()
        .then((info) {
          if (!mounted) return;
          setState(() => _label = 'v${info.version}');
        })
        .catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    if (_label.isEmpty) return const SizedBox.shrink();
    return Text(
      _label,
      style: const TextStyle(color: Colors.white24, fontSize: 11),
    );
  }
}

/// iOS 风格分组列表卡片：圆角深色容器 + 项间细分割线。
class _GroupCard extends StatelessWidget {
  const _GroupCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFF242424),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white10),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            children[i],
            if (i < children.length - 1)
              const Divider(
                height: 0.5,
                color: Colors.white12,
                indent: 16,
                endIndent: 16,
              ),
          ],
        ],
      ),
    );
  }
}

/// 「跳过片头」折叠配置：外层开关 + 展开后的分档规则输入。
/// 规则：视频时长超过对应档位阈值即跳过该档秒数，取满足的最大档；
/// 不足 45 秒不跳。第 1 档阈值按秒输入，第 2~4 档阈值按分钟输入。
class _SkipIntroGroup extends StatefulWidget {
  const _SkipIntroGroup({required this.settings});

  final AppSettings settings;

  @override
  State<_SkipIntroGroup> createState() => _SkipIntroGroupState();
}

class _SkipIntroGroupState extends State<_SkipIntroGroup> {
  bool _expanded = false;
  late final List<TextEditingController> _atCtrls;
  late final List<TextEditingController> _secCtrls;

  @override
  void initState() {
    super.initState();
    // skipIntroTiers 形如 (atSec, skipSec)；单文件分析下按位置访问更稳妥。
    final tiers = widget.settings.skipIntroTiers;
    _atCtrls = [
      for (var i = 0; i < tiers.length; i++)
        TextEditingController(
          text: i == 0 ? '${tiers[i].$1}' : '${tiers[i].$1 ~/ 60}',
        ),
    ];
    _secCtrls = [for (final t in tiers) TextEditingController(text: '${t.$2}')];
  }

  @override
  void dispose() {
    for (final c in _atCtrls) {
      c.dispose();
    }
    for (final c in _secCtrls) {
      c.dispose();
    }
    super.dispose();
  }

  void _apply(TextEditingController c, Future<void> Function(int) setter) {
    final v = int.tryParse(c.text.trim());
    if (v == null || v <= 0) return;
    // ignore: unawaited_futures
    setter(v);
  }

  void _onAtChanged(int index, TextEditingController c) => _apply(
    c,
    (v) => widget.settings.setSkipTierAtSec(index, index == 0 ? v : v * 60),
  );

  void _onSecChanged(int index, TextEditingController c) =>
      _apply(c, (v) => widget.settings.setSkipTierSec(index, v));

  Widget _tierRow(int index) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text('超过', style: TextStyle(color: Colors.white54, fontSize: 12)),
        const SizedBox(width: 6),
        SizedBox(
          width: 64,
          child: _NumField(
            controller: _atCtrls[index],
            label: '',
            hint: index == 0 ? '秒' : '分钟',
            onChanged: (c) => _onAtChanged(index, c),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          index == 0 ? '秒' : '分钟',
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
        const SizedBox(width: 8),
        const Text('跳过', style: TextStyle(color: Colors.white54, fontSize: 12)),
        const SizedBox(width: 6),
        SizedBox(
          width: 64,
          child: _NumField(
            controller: _secCtrls[index],
            label: '',
            hint: '秒',
            onChanged: (c) => _onSecChanged(index, c),
          ),
        ),
        const SizedBox(width: 6),
        const Text('秒', style: TextStyle(color: Colors.white54, fontSize: 12)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    final tiers = s.skipIntroTiers;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
            child: Row(
              children: [
                Switch(
                  activeThumbColor: const Color(0xFFFF6B35),
                  value: s.skipIntro,
                  onChanged: s.setSkipIntro,
                ),
                const SizedBox(width: 14),
                const Expanded(
                  child: Text('跳过片头', style: TextStyle(color: Colors.white)),
                ),
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  color: Colors.white38,
                ),
              ],
            ),
          ),
        ),
        if (_expanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '规则：视频时长超过对应档位即跳过该档秒数，取满足的最大档；不足 45 秒不跳。',
                  style: TextStyle(color: Colors.white38, fontSize: 11),
                ),
                const SizedBox(height: 8),
                for (var i = 0; i < tiers.length; i++) ...[
                  if (i > 0) const SizedBox(height: 8),
                  _tierRow(i),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

/// 紧凑数字输入行（键盘直接改数值，即输即存）。
class _NumField extends StatelessWidget {
  const _NumField({
    required this.controller,
    required this.label,
    this.hint,
    this.onChanged,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final void Function(TextEditingController c)? onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      style: const TextStyle(color: Colors.white, fontSize: 13),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: const TextStyle(color: Colors.white54, fontSize: 12),
        hintStyle: const TextStyle(color: Colors.white30, fontSize: 11),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        filled: true,
        fillColor: const Color(0xFF2A2A2A),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
      ),
      onChanged: onChanged == null ? null : (v) => onChanged!(controller),
    );
  }
}

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
                      SwitchListTile(
                        title: const Text(
                          '跳过片头',
                          style: TextStyle(color: Colors.white),
                        ),
                        subtitle: const Text(
                          '跳过片头广告；短视频自动关闭。',
                          style: TextStyle(color: Colors.white38, fontSize: 12),
                        ),
                        activeThumbColor: const Color(0xFFFF6B35),
                        value: settings.skipIntro,
                        onChanged: settings.setSkipIntro,
                      ),
                      SwitchListTile(
                        title: const Text(
                          '自动横屏',
                          style: TextStyle(color: Colors.white),
                        ),
                        subtitle: const Text(
                          '接近完全横置才进、明显竖回才出。',
                          style: TextStyle(color: Colors.white38, fontSize: 12),
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
                          style: TextStyle(color: Colors.white38, fontSize: 12),
                        ),
                        activeThumbColor: const Color(0xFFFF6B35),
                        value: settings.autoLowerOnStall,
                        onChanged: settings.setAutoLowerOnStall,
                      ),
                      SwitchListTile(
                        title: const Text(
                          '自动跳过无信号频道',
                          style: TextStyle(color: Colors.white),
                        ),
                        subtitle: const Text(
                          '频道确认不可用时自动切换；可随时在这里关闭。',
                          style: TextStyle(color: Colors.white38, fontSize: 12),
                        ),
                        activeThumbColor: const Color(0xFFFF6B35),
                        value: settings.autoSkipUnavailable,
                        onChanged: settings.setAutoSkipUnavailable,
                      ),
                      if (defaultTargetPlatform == TargetPlatform.iOS) ...[
                        const Divider(color: Colors.white12),
                        const ListTile(
                          title: Text(
                            '按钮显示',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                            ),
                          ),
                          dense: true,
                        ),
                        SwitchListTile(
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
                      ],
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
                          style: TextStyle(color: Colors.white38, fontSize: 12),
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
                          style: TextStyle(color: Colors.white38, fontSize: 12),
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
                      const Divider(color: Colors.white12),
                      ListTile(
                        title: const Text(
                          '一键恢复频道',
                          style: TextStyle(color: Colors.white),
                        ),
                        subtitle: const Text(
                          '恢复默认网站列表与直播入口（不改画质）。',
                          style: TextStyle(color: Colors.white38, fontSize: 12),
                        ),
                        trailing: const Icon(
                          Icons.restart_alt,
                          color: Color(0xFFFF6B35),
                        ),
                        onTap: () async {
                          final ok = await showDialog<bool>(
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
                                      onPressed: () => Navigator.pop(d, false),
                                      child: const Text('取消'),
                                    ),
                                    TextButton(
                                      onPressed: () => Navigator.pop(d, true),
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
                      const Divider(color: Colors.white12),
                      ListTile(
                        title: const Text(
                          '清除痕迹并退出',
                          style: TextStyle(color: Colors.white),
                        ),
                        subtitle: const Text(
                          '清理 WebView 缓存、Cookie、应用数据后退出。',
                          style: TextStyle(color: Colors.white38, fontSize: 12),
                        ),
                        trailing: const Icon(
                          Icons.cleaning_services,
                          color: Color(0xFFFF6B35),
                        ),
                        onTap: () async {
                          final ok = await showDialog<bool>(
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
                                      onPressed: () => Navigator.pop(d, false),
                                      child: const Text('取消'),
                                    ),
                                    TextButton(
                                      onPressed: () => Navigator.pop(d, true),
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
                      const Divider(color: Colors.white12),
                      const ListTile(
                        title: Text(
                          '画质',
                          style: TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                        dense: true,
                      ),
                      for (final h in options)
                        ListTile(
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
                            Navigator.pop(ctx);
                            await settings.setQualityCap(h);
                            onQualityChanged?.call();
                          },
                        ),
                      const SizedBox(height: 16),
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

String _customParserLabel(String parser) => switch (parser) {
      'generic_vod' => '点播 · 通用解析',
      'pornhub' => '点播 · Pornhub 解析',
      'xvideos' => '点播 · XVideos 解析',
      'mitao' => '点播 · Mitao 解析',
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
    PackageInfo.fromPlatform().then((info) {
      if (!mounted) return;
      setState(() => _label = 'v${info.version}');
    }).catchError((_) {});
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

library;

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

part 'player_settings_part_components.dart';
part 'player_settings_part_dialogs.dart';
part 'player_settings_part_skip_intro.dart';

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
                      _GroupCard(
                        children: [
                          _GroupExpansion(
                            title: const Text(
                              '画质',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 13,
                              ),
                            ),
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
                        ],
                      ),
                      if (defaultTargetPlatform == TargetPlatform.iOS) ...[
                        _GroupCard(
                          children: [
                            _GroupExpansion(
                              title: const Row(
                                children: [
                                  Text(
                                    '按钮显示',
                                    style: TextStyle(
                                      color: Colors.white70,
                                      fontSize: 13,
                                    ),
                                  ),
                                  Spacer(),
                                  Icon(
                                    Icons.arrow_back,
                                    color: Color(0xFFFF6B35),
                                    size: 17,
                                  ),
                                  SizedBox(width: 6),
                                  Icon(
                                    Icons.fullscreen,
                                    color: Color(0xFFFF6B35),
                                    size: 17,
                                  ),
                                  SizedBox(width: 6),
                                  Icon(
                                    Icons.volume_up,
                                    color: Color(0xFFFF6B35),
                                    size: 17,
                                  ),
                                  SizedBox(width: 6),
                                  Icon(
                                    Icons.forward_30,
                                    color: Color(0xFFFF6B35),
                                    size: 17,
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
                                    '控制播放器左下角快进 30 秒按钮的显示',
                                    style: TextStyle(
                                      color: Colors.white38,
                                      fontSize: 12,
                                    ),
                                  ),
                                  activeThumbColor: const Color(0xFFFF6B35),
                                  value: settings.showFastForwardButton,
                                  onChanged: settings.setShowFastForwardButton,
                                ),
                              ],
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
                          SwitchListTile(
                            title: const Text(
                              '长按卡片更换域名',
                              style: TextStyle(color: Colors.white),
                            ),
                            subtitle: const Text(
                              '开启后长按主页卡片可手动输入新域名，重启后仍生效。',
                              style: TextStyle(
                                color: Colors.white38,
                                fontSize: 12,
                              ),
                            ),
                            activeThumbColor: const Color(0xFFFF6B35),
                            value: settings.manualMirrorEnabled,
                            onChanged: settings.setManualMirrorEnabled,
                          ),
                          SwitchListTile(
                            title: const Text(
                              '激进预加载（实验）',
                              style: TextStyle(color: Colors.white),
                            ),
                            subtitle: const Text(
                              '默认关。开启后首页并行预热全部站点卡片的首个视频（含解码器预缓冲），点开卡片近乎秒播。耗流量耗电、发热明显；仅排最前的 2 个站点做解码器预缓冲。',
                              style: TextStyle(
                                color: Colors.white38,
                                fontSize: 12,
                              ),
                            ),
                            isThreeLine: true,
                            activeThumbColor: const Color(0xFFFF6B35),
                            value: settings.aggressivePrewarm,
                            onChanged: settings.setAggressivePrewarm,
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

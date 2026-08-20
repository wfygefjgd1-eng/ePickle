import 'package:flutter/material.dart';

import '../services/mirror_ranker.dart';
import '../services/source_catalog.dart';
import '../utils/playback_helpers.dart';

/// 站点域名选择面板（长按 tab 栏第一个「热」触发）。
///
/// 圆角面板 + radio 圆点选中 + 域名卡片列表。列出 [site] 的全部
/// 镜像域名 + 「自动优选」；选择固定在 MirrorRanker 的会话级 override
/// （进程存活期间该站点所有请求走所选域名，App 被杀后恢复自动优选）。
Future<void> showMirrorPickerSheet(BuildContext context, SiteDef site) async {
  final ranker = MirrorRanker.instance;
  final currentManual = ranker.manualBase(site.id);
  final mirrors = site.mirrors;
  String normalize(String b) => b.replaceAll(RegExp(r'/$'), '');

  final picked = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: Container(
        margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
        decoration: BoxDecoration(
          // 半透明 + 小圆角：克制的深色面板。
          color: const Color(0xF21C1C1C),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white10),
        ),
        child: Column(
          children: [
            Center(
              child: Container(
                width: 34,
                height: 4,
                margin: const EdgeInsets.only(bottom: 8, top: 2),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 标题长条：与卡片同款同宽，居中显示。
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2A2A2A),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Column(
                        children: [
                          const Text(
                            '切换为本站访问域名',
                            style: TextStyle(color: Colors.white, fontSize: 14),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            site.name,
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 3),
                          const Text(
                            '选择后本次使用期间对该站点生效，退出应用后恢复自动优选',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white38,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    // 自动优选 — radio 圆点（全程无选中勾选标记）。
                    GestureDetector(
                      onTap: () => Navigator.pop(ctx, ''),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2A2A2A),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              currentManual == null
                                  ? Icons.radio_button_checked
                                  : Icons.radio_button_unchecked,
                              size: 18,
                              color: currentManual == null
                                  ? const Color(0xFFFF6B35)
                                  : Colors.white30,
                            ),
                            const SizedBox(width: 10),
                            const Text(
                              '自动优选（最快镜像）',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                              ),
                            ),
                            const Spacer(),
                            const Text(
                              '按网络实测自动选择',
                              style: TextStyle(
                                color: Colors.white38,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    // 域名卡片 — 每个镜像一张全宽卡片，纵向排列。
                    for (final base in mirrors) ...[
                      Builder(
                        builder: (itemCtx) {
                          final active = currentManual == normalize(base);
                          return GestureDetector(
                            onTap: () => Navigator.pop(itemCtx, base),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 160),
                              curve: Curves.easeOut,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                color: active
                                    ? const Color(0x33FF6B35)
                                    : const Color(0xFF2A2A2A),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    active
                                        ? Icons.radio_button_checked
                                        : Icons.radio_button_unchecked,
                                    size: 16,
                                    color: active
                                        ? const Color(0xFFFF6B35)
                                        : Colors.white38,
                                  ),
                                  const SizedBox(width: 10),
                                  Text(
                                    _hostOf(base),
                                    style: TextStyle(
                                      color: active
                                          ? Colors.white
                                          : Colors.white70,
                                      fontSize: 14,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 8),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  if (!context.mounted) return;
  if (picked == null) return; // dismissed — keep whatever was active
  if (picked.isEmpty) {
    ranker.clearManualBase(site.id);
    PlaybackHelpers.toast(context, '已恢复自动优选域名');
    return;
  }
  ranker.setManualBase(site.id, picked);
  PlaybackHelpers.toast(context, '已固定使用 ${_hostOf(picked)}，本次使用有效');
}

String _hostOf(String base) {
  final uri = Uri.tryParse(base);
  if (uri != null && uri.host.isNotEmpty) return uri.host;
  return base.replaceAll(RegExp(r'^https?://'), '');
}

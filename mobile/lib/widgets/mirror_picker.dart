import 'package:flutter/material.dart';

import '../services/mirror_ranker.dart';
import '../services/source_catalog.dart';
import '../utils/playback_helpers.dart';

/// 站点域名选择面板（长按 tab 栏第一个「热」触发）。
///
/// iOS 风：圆角大面板 + radio 圆点选中 + 域名药丸。列出 [site] 的全部
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
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
        decoration: BoxDecoration(
          // Slightly translucent + heavy corners: glassy iOS look.
          color: const Color(0xF21C1C1C),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: Colors.white10),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 34,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const Text(
              '切换为本站访问域名',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              site.name,
              style: const TextStyle(color: Colors.white54, fontSize: 13),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              '选择后本次使用期间对该站点生效，退出应用后恢复自动优选',
              style: const TextStyle(color: Colors.white38, fontSize: 11),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 14),
            // 自动优选 — row with radio dot (no check marks anywhere).
            GestureDetector(
              onTap: () => Navigator.pop(ctx, ''),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 10),
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
                          color: Colors.white, fontSize: 14),
                    ),
                    const Spacer(),
                    const Text(
                      '按网络实测自动选择',
                      style: TextStyle(color: Colors.white38, fontSize: 11),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            // Domain pills — one capsule per mirror, radio dot inside.
            Flexible(
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  for (final base in mirrors)
                    Builder(builder: (itemCtx) {
                      final active = currentManual == normalize(base);
                      return GestureDetector(
                        onTap: () => Navigator.pop(itemCtx, base),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 160),
                          curve: Curves.easeOut,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: active
                                ? const Color(0x33FF6B35)
                                : const Color(0xFF2A2A2A),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: active
                                  ? const Color(0xFFFF6B35)
                                  : Colors.white24,
                              width: 1.2,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
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
                              const SizedBox(width: 6),
                              Text(
                                _hostOf(base),
                                style: TextStyle(
                                  color: active
                                      ? Colors.white
                                      : Colors.white70,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                ],
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
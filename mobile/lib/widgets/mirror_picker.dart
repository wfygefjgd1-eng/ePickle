import 'package:flutter/material.dart';

import '../services/mirror_ranker.dart';
import '../services/source_catalog.dart';
import '../utils/playback_helpers.dart';

/// 站点域名选择面板（长按 tab 栏第一个「热」触发）。
///
/// 列出 [site] 的全部镜像域名 + 「自动优选」；选择会固定在
/// MirrorRanker 的会话级 override 里（进程存活期间该站点所有请求走所选
/// 域名，App 被杀后恢复自动优选）。每个站点入口各自唤起，选择互不干扰。
Future<void> showMirrorPickerSheet(BuildContext context, SiteDef site) async {
  final ranker = MirrorRanker.instance;
  final currentManual = ranker.manualBase(site.id);
  final mirrors = site.mirrors;
  String normalize(String b) => b.replaceAll(RegExp(r'/$'), '');
  final picked = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: const Color(0xFF1E1E1E),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Text(
              '切换为本站访问域名（本次使用期间有效，退出应用后恢复自动优选）',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              site.name,
              style: const TextStyle(
                  color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
          ListTile(
            dense: true,
            leading: Icon(Icons.auto_awesome,
                color: currentManual == null
                    ? const Color(0xFFFF6B35)
                    : Colors.white38),
            title: const Text('自动优选（最快镜像）',
                style: TextStyle(color: Colors.white)),
            subtitle: const Text('按网络实测自动选择',
                style: TextStyle(color: Colors.white38, fontSize: 11)),
            trailing: currentManual == null
                ? const Icon(Icons.check, color: Color(0xFFFF6B35))
                : null,
            onTap: () => Navigator.pop(ctx, ''),
          ),
          const Divider(color: Colors.white10, height: 1),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final base in mirrors)
                  Builder(builder: (itemCtx) {
                    final active = currentManual == normalize(base);
                    return ListTile(
                      dense: true,
                      leading: Icon(Icons.public,
                          color: active
                              ? const Color(0xFFFF6B35)
                              : Colors.white38),
                      title: Text(_hostOf(base),
                          style: const TextStyle(color: Colors.white)),
                      trailing: active
                          ? const Icon(Icons.check, color: Color(0xFFFF6B35))
                          : null,
                      onTap: () => Navigator.pop(itemCtx, base),
                    );
                  }),
              ],
            ),
          ),
        ],
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
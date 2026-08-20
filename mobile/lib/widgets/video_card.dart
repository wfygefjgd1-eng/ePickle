import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/video_item.dart';
import '../services/mirror_ranker.dart';
import '../services/source_catalog.dart';
import '../utils/http_headers.dart';
import '../utils/playback_helpers.dart';

class VideoCard extends StatelessWidget {
  final VideoItem item;
  final VoidCallback onTap;

  /// Owning site. When non-null, the tiny gear in the thumbnail's top-right
  /// corner becomes active: LONG-PRESS on it opens the mirror picker for
  /// THIS card's site (session-scoped manual base override).
  final SiteDef? site;

  const VideoCard({
    super.key,
    required this.item,
    required this.onTap,
    this.site,
  });

  @override
  Widget build(BuildContext context) {
    final headers = AppHttpHeaders.forMediaUrl(item.thumb ?? item.url);
    final s = site;
    return RepaintBoundary(
      child: Card(
        color: const Color(0xFF2A2A2A),
        clipBehavior: Clip.antiAlias,
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: InkWell(
          onTap: onTap,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 140,
                height: 88,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (item.thumb != null && item.thumb!.isNotEmpty)
                      CachedNetworkImage(
                        imageUrl: item.thumb!,
                        httpHeaders: headers,
                        fit: BoxFit.cover,
                        // Decode near display size — less memory on long lists.
                        memCacheWidth: 280,
                        memCacheHeight: 176,
                        placeholder: (_, __) =>
                            Container(color: const Color(0xFF1A1A1A)),
                        errorWidget: (_, __, ___) => Container(
                          color: const Color(0xFF1A1A1A),
                          child: const Icon(Icons.broken_image,
                              color: Colors.grey),
                        ),
                      )
                    else
                      Container(
                        color: const Color(0xFF1A1A1A),
                        child: const Icon(Icons.play_circle_outline,
                            color: Colors.grey, size: 36),
                      ),
                    Positioned(
                      right: 4,
                      bottom: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: Colors.black87,
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(
                          item.duration,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ),
                    // 右上角设置钮：LONG-PRESS 弹出本卡片的域名选择（每个卡片
                    // 独立，选的是当前卡片所属站点的镜像域名，本次使用有效）。
                    if (s != null && s.mirrors.isNotEmpty)
                      Positioned(
                        right: 4,
                        top: 4,
                        child: GestureDetector(
                          onLongPress: () => _showMirrorPicker(context, s),
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: BoxDecoration(
                              color: Colors.black45,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(
                              Icons.settings,
                              size: 12,
                              color: Colors.white70,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                  child: Text(
                    item.title,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFFEEEEEE),
                      fontSize: 14,
                      height: 1.3,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Bottom sheet listing every mirror of [site] plus "auto". Returns null on
  /// dismiss, '' explicitly re-selecting auto, or the chosen base string.
  Future<void> _showMirrorPicker(BuildContext context, SiteDef site) async {
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
                '当前卡片的访问域名（本次使用期间有效，退出应用后恢复自动优选）',
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

  static String _hostOf(String base) {
    final uri = Uri.tryParse(base);
    if (uri != null && uri.host.isNotEmpty) return uri.host;
    return base.replaceAll(RegExp(r'^https?://'), '');
  }
}
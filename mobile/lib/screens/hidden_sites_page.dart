import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/layout_settings.dart';
import '../services/source_catalog.dart';

class HiddenSitesPage extends StatelessWidget {
  const HiddenSitesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final layout = context.watch<LayoutSettings>();
    final sites = layout.allManagedSites;
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: const Text('隐藏网站'),
        backgroundColor: const Color(0xFF1E1E1E),
        foregroundColor: Colors.white,
      ),
      body: sites.isEmpty
          ? const Center(
              child: Text('暂无网站', style: TextStyle(color: Colors.white54)))
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(8, 12, 8, 32),
              itemCount: sites.length,
              separatorBuilder: (_, __) =>
                  const Divider(color: Colors.white12, height: 1),
              itemBuilder: (_, index) {
                final site = sites[index];
                return SwitchListTile(
                  value: !layout.isSiteHidden(site),
                  activeThumbColor: const Color(0xFFFF6B35),
                  secondary: Icon(
                    site.kind == SiteKind.live
                        ? Icons.live_tv
                        : Icons.movie_outlined,
                    color: Colors.white54,
                  ),
                  title: Text(site.name,
                      style: const TextStyle(color: Colors.white)),
                  subtitle: Text(
                    site.kind == SiteKind.live ? '直播网站' : '点播网站',
                    style: const TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                  onChanged: (visible) async {
                    final ok = await layout.setSiteHidden(site, !visible);
                    if (!ok && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('至少保留一个视频站点'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    }
                  },
                );
              },
            ),
    );
  }
}

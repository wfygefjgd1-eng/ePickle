part of 'player_settings_sheet.dart';

class _AppVersionLabel extends StatefulWidget {
  const _AppVersionLabel();

  @override
  State<_AppVersionLabel> createState() => _AppVersionLabelState();
}

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

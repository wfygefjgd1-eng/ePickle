part of 'player_settings_sheet.dart';

/// 「跳过片头」折叠配置：外层开关 + 展开后的分档规则输入。
/// 规则：视频时长超过对应档位阈值即跳过该档秒数，取满足的最大档；
/// 不足 45 秒不跳。第 1 档阈值按秒输入，第 2~4 档阈值按分钟输入
/// （支持小数，如 1.5 = 90 秒）。
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
          text: i == 0 ? '${tiers[i].$1}' : _minutesLabel(tiers[i].$1),
        ),
    ];
    _secCtrls = [for (final t in tiers) TextEditingController(text: '${t.$2}')];
  }

  /// 分钟档显示：整分钟显示整数；非整分钟显示两位小数（去尾零），
  /// 保证按秒存储的历史值（如 90 → "1.5"）原样可见、编辑后按秒精确还原，
  /// 不再被 ~/60 截断成另一个值。
  static String _minutesLabel(int sec) {
    if (sec % 60 == 0) return '${sec ~/ 60}';
    var s = (sec / 60).toStringAsFixed(2);
    if (s.contains('.')) {
      s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
    }
    return s;
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

  /// 分钟档输入：允许小数（"1.5" → 90 秒），按秒四舍五入后写回。
  void _applyMinutes(TextEditingController c, Future<void> Function(int) setter) {
    final v = double.tryParse(c.text.trim());
    if (v == null || v <= 0) return;
    // ignore: unawaited_futures
    setter((v * 60).round());
  }

  void _onAtChanged(int index, TextEditingController c) {
    if (index == 0) {
      _apply(c, (v) => widget.settings.setSkipTierAtSec(index, v));
    } else {
      _applyMinutes(c, (v) => widget.settings.setSkipTierAtSec(index, v));
    }
  }

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

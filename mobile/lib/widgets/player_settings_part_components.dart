part of 'player_settings_sheet.dart';

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

/// 紧凑的可折叠设置分组：一行标题（可带当前值摘要），点开才露出子项，
/// 收起时面板保持干净。默认收起。
class _GroupExpansion extends StatelessWidget {
  const _GroupExpansion({
    required this.title,
    this.subtitle,
    required this.children,
  });

  final Widget title;
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
        title: title,
        subtitle: subtitle,
        children: children,
      ),
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

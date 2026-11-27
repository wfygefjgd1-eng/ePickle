import 'package:flutter/material.dart';

/// 「快进 45 秒」图标。Material 图标只有 forward_5/10/30，没有 45 变体：
/// 按 forward_30 的构图自绘 —— 左下数字 + 右侧双三角（fast_forward），
/// 颜色/阴影与调用处的普通 Icon 一致。
class Forward45Icon extends StatelessWidget {
  const Forward45Icon({
    super.key,
    required this.size,
    required this.color,
    this.shadows,
  });

  final double size;
  final Color color;
  final List<Shadow>? shadows;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            child: Center(
              child: Icon(
                Icons.fast_forward,
                size: size * 0.88,
                color: color,
                shadows: shadows,
              ),
            ),
          ),
          Positioned(
            left: size * 0.02,
            bottom: 0,
            child: Text(
              '45',
              style: TextStyle(
                fontSize: size * 0.38,
                height: 1.0,
                fontWeight: FontWeight.w600,
                color: color,
                shadows: shadows,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 「快进 45 秒」图标。Material 图标只有 forward_5/10/30，没有 45 变体：
/// 按 forward_30 的构图自绘 —— 顶部留缺口的顺时针圆弧箭头包住居中的
/// 「45」，颜色/阴影与调用处的普通 Icon 一致。
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
      child: CustomPaint(
        painter: _Forward45ArcPainter(color: color, shadows: shadows),
        child: Center(
          child: Text(
            '45',
            style: TextStyle(
              fontSize: size * 0.40,
              height: 1.0,
              fontWeight: FontWeight.w700,
              color: color,
              shadows: shadows,
            ),
          ),
        ),
      ),
    );
  }
}

/// 圆弧（stroke）+ 缺口右端实心箭头（fill），同为 [color]。
class _Forward45ArcPainter extends CustomPainter {
  _Forward45ArcPainter({required this.color, this.shadows});

  final Color color;
  final List<Shadow>? shadows;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final c = Offset(size.width / 2, size.height / 2);
    final r = s * 0.34;

    // 圆弧：顶部留 64° 缺口，从缺口右端顺时针绕到左端。
    const gapHalf = 32 * math.pi / 180;
    final arcStart = -math.pi / 2 + gapHalf; // 缺口右端
    final sweep = 2 * math.pi - gapHalf * 2;

    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.09
      ..strokeCap = StrokeCap.round
      ..color = color;
    final fill = Paint()..color = color;

    final arrow = _arrowPath(c, r, arcStart, s);

    // 阴影：弧线与箭头整体先画一遍带模糊的底色（调用处只传一颗）。
    if (shadows != null && shadows!.isNotEmpty) {
      for (final sh in shadows!) {
        final shadowPaint = Paint()
          ..color = sh.color
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, sh.blurRadius);
        canvas.save();
        canvas.translate(sh.offset.dx, sh.offset.dy);
        canvas.drawArc(Rect.fromCircle(center: c, radius: r), arcStart, sweep,
            false, shadowPaint);
        canvas.drawPath(arrow, shadowPaint);
        canvas.restore();
      }
    }

    canvas.drawArc(Rect.fromCircle(center: c, radius: r), arcStart, sweep,
        false, stroke);
    canvas.drawPath(arrow, fill);
  }

  /// 箭头：贴在缺口右端，指向顺时针切线方向（右上 → 右下），
  /// 底边略回撤盖住圆弧端点的圆头，形成自然衔接。
  Path _arrowPath(Offset c, double r, double arcStart, double s) {
    final dir = Offset(-math.sin(arcStart), math.cos(arcStart)); // 顺时针切向
    final p = c + Offset(math.cos(arcStart), math.sin(arcStart)) * r;
    const len = 0.17, width = 0.20; // 相对 size 的比例
    final tip = p + dir * len * s;
    final base = p - dir * len * s * 0.35;
    final perp = Offset(-dir.dy, dir.dx);
    final half = perp * (width * s / 2);
    return Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(base.dx + half.dx, base.dy + half.dy)
      ..lineTo(base.dx - half.dx, base.dy - half.dy)
      ..close();
  }

  @override
  bool shouldRepaint(_Forward45ArcPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.shadows != shadows;
}

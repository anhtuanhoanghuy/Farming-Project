import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

class WaveLogo extends StatelessWidget {
  const WaveLogo({
    super.key,
    this.size = 28,
    this.color = AppColors.primary,
  });

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size * 0.72,
      child: CustomPaint(
        painter: _WavePainter(color),
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.height * 0.14
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    for (var i = 0; i < 3; i++) {
      final dy = size.height * (0.22 + i * 0.28);
      final path = Path();
      path.moveTo(size.width * 0.06, dy);
      path.cubicTo(
        size.width * 0.22,
        dy - size.height * 0.22,
        size.width * 0.38,
        dy + size.height * 0.22,
        size.width * 0.52,
        dy,
      );
      path.cubicTo(
        size.width * 0.66,
        dy - size.height * 0.22,
        size.width * 0.82,
        dy + size.height * 0.22,
        size.width * 0.94,
        dy,
      );
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter oldDelegate) =>
      oldDelegate.color != color;
}

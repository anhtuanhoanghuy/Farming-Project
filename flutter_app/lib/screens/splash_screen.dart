import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/app_config.dart';
import '../navigation/app_routes.dart';
import '../services/auth_service.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    var signedIn = false;
    try {
      await Future.wait([
        AuthService.init(),
        Future<void>.delayed(const Duration(milliseconds: 1500)),
      ]);
      signedIn = AuthService.isSignedIn;
    } catch (_) {
      signedIn = false;
    }
    if (!mounted) return;
    Navigator.of(
      context,
    ).pushReplacementNamed(signedIn ? AppRoutes.shell : AppRoutes.login);
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFF0A3B28),
      body: _SplashArtwork(),
    );
  }
}

class _SplashArtwork extends StatelessWidget {
  const _SplashArtwork();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final iconTop = constraints.maxHeight * 0.394;
        final iconSize = constraints.maxWidth * 0.33;
        final brandTop = math.max(
          constraints.maxHeight * 0.585,
          iconTop + iconSize + 24,
        );
        return Stack(
          fit: StackFit.expand,
          children: [
            CustomPaint(painter: _SplashPatternPainter()),
            Positioned(
              top: iconTop,
              left: 0,
              right: 0,
              child: Center(
                child: SizedBox(
                  width: iconSize,
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(iconSize * 0.08),
                      child: Image.asset(
                        'assets/images/app_icon_source.png',
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: brandTop,
              left: 0,
              right: 0,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: RichText(
                  textAlign: TextAlign.center,
                  text: const TextSpan(
                    style: TextStyle(
                      fontSize: 38,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -1,
                    ),
                    children: [
                      TextSpan(
                        text: 'Sense',
                        style: TextStyle(color: Color(0xFFF2FAEE)),
                      ),
                      TextSpan(
                        text: 'Connect',
                        style: TextStyle(color: Color(0xFFA7E853)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              bottom: constraints.maxHeight * 0.065,
              left: 0,
              right: 0,
              child: Text(
                'Version: ${AppConfig.appVersion}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Color(0xFF5E9173),
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SplashPatternPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height * 0.437);
    final ringPaint = Paint()
      ..color = const Color(0xFF14553A)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (final radius in [0.23, 0.385, 0.55, 0.744]) {
      canvas.drawCircle(center, size.width * radius, ringPaint);
    }

    final dotPaint = Paint()..color = const Color(0xFF75CF8A);
    canvas
      ..drawCircle(
        Offset(size.width * 0.73, size.height * 0.348),
        size.width * 0.013,
        dotPaint,
      )
      ..drawCircle(
        Offset(size.width * 0.18, size.height * 0.39),
        size.width * 0.008,
        dotPaint,
      )
      ..drawCircle(
        Offset(size.width * 0.287, size.height * 0.556),
        size.width * 0.01,
        dotPaint,
      )
      ..drawCircle(
        Offset(size.width * 0.815, size.height * 0.556),
        size.width * 0.008,
        dotPaint,
      );
  }

  @override
  bool shouldRepaint(covariant _SplashPatternPainter oldDelegate) => false;
}

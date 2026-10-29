import 'dart:async';

import 'package:flutter/material.dart';

import '../core/error_text.dart';
import '../navigation/app_routes.dart';
import '../services/auth_service.dart';
import '../widgets/app_buttons.dart';
import '../widgets/hero_banner.dart';
import '../widgets/screen_scaffold.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  StreamSubscription? _sub;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    try {
      _sub = AuthService.onAuthStateChange.listen((state) {
        if (state.session != null) _goToApp();
      });
    } catch (_) {
      // Supabase not initialised (missing configuration); sign-in will report the error.
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _goToApp() {
    if (!mounted) return;
    _sub?.cancel();
    Navigator.of(
      context,
    ).pushNamedAndRemoveUntil(AppRoutes.shell, (r) => false);
  }

  Future<void> _signIn() async {
    setState(() => _loading = true);
    try {
      await AuthService.signInWithGoogle();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(userErrorText('Đăng nhập Google thất bại', e))),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final logoWidth = (MediaQuery.sizeOf(context).width * 0.4).clamp(
      150.0,
      280.0,
    );

    return ScreenScaffold(
      title: 'SenseConnect',
      showLogo: true,
      headerTrailing: Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Image.asset(
          'assets/images/nacentech_logo.png',
          width: logoWidth,
          height: logoWidth * 0.23,
          fit: BoxFit.contain,
          semanticLabel: 'Viện Đổi mới Sáng tạo Quốc gia',
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const HeroBanner(),
                  const SizedBox(height: 28),
                  PrimaryButton(
                    label: _loading
                        ? 'Đang mở Google...'
                        : 'Đăng nhập bằng Google',
                    icon: Icons.login_rounded,
                    onPressed: _loading ? null : _signIn,
                  ),
                ],
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Text(
              'Mã số đề tài: 11/2026/HĐ-ĐTCS',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ),
        ],
      ),
    );
  }
}

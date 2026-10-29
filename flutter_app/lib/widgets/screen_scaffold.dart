import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import 'app_bottom_nav.dart';
import 'app_header.dart';

class ScreenScaffold extends StatelessWidget {
  const ScreenScaffold({
    super.key,
    required this.title,
    required this.body,
    this.showBack = false,
    this.showLogo = false,
    this.leadingIcon,
    this.navIndex,
    this.onNavTap,
    this.onBack,
    this.embedInTab = false,
    this.titleTrailing,
    this.headerBottom,
    this.headerTrailing,
    this.showMore = false,
  });

  final String title;
  final Widget body;
  final bool showBack;
  final bool showLogo;
  final IconData? leadingIcon;
  final int? navIndex;
  final ValueChanged<int>? onNavTap;
  final VoidCallback? onBack;
  final bool embedInTab;
  final Widget? titleTrailing;
  final Widget? headerBottom;
  final Widget? headerTrailing;
  final bool showMore;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        bottom: navIndex == null && !embedInTab,
        child: Column(
          children: [
            AppHeader(
              title: title,
              showBack: showBack,
              showLogo: showLogo,
              leadingIcon: leadingIcon,
              onBack: onBack,
              titleTrailing: titleTrailing,
              bottom: headerBottom,
              trailing: headerTrailing,
              showMore: showMore,
            ),
            Expanded(child: body),
          ],
        ),
      ),
      bottomNavigationBar: navIndex == null
          ? null
          : AppBottomNav(currentIndex: navIndex!, onTap: onNavTap ?? (_) {}),
    );
  }
}

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';

class AppHeader extends StatelessWidget {
  const AppHeader({
    super.key,
    required this.title,
    this.showBack = false,
    this.showLogo = false,
    this.leadingIcon,
    this.onBack,
    this.titleTrailing,
    this.bottom,
    this.trailing,
    this.showMore = false,
  });
  final String title;
  final bool showBack;
  final bool showLogo;
  final IconData? leadingIcon;
  final VoidCallback? onBack;

  /// Shown right after the title (e.g. an edit pencil).
  final Widget? titleTrailing;

  /// Shown under the title (e.g. a status chip).
  final Widget? bottom;

  /// Replaces the default "more" button.
  final Widget? trailing;

  /// Whether to show the default (inactive) more button when [trailing] is null.
  final bool showMore;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 4, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (showBack)
            IconButton(
              onPressed: onBack ?? () => Navigator.of(context).maybePop(),
              icon: const Icon(
                Icons.arrow_back_ios_new_rounded,
                size: 18,
                color: AppColors.textPrimary,
              ),
            )
          else if (leadingIcon != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Icon(leadingIcon, size: 24, color: AppColors.primary),
            )
          else
            const SizedBox(width: 8),
          if (showLogo) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(7),
              child: Image.asset(
                'assets/images/app_icon_source.png',
                width: 30,
                height: 30,
              ),
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(title, style: AppTextStyles.appBarTitle),
                    ),
                    if (titleTrailing != null) ...[
                      const SizedBox(width: 2),
                      titleTrailing!,
                    ],
                  ],
                ),
                if (bottom != null) ...[const SizedBox(height: 6), bottom!],
              ],
            ),
          ),
          trailing ??
              (!showMore
                  ? const SizedBox(width: 8)
                  : IconButton(
                      onPressed: () {},
                      icon: const Icon(
                        Icons.more_vert,
                        color: AppColors.textPrimary,
                      ),
                    )),
        ],
      ),
    );
  }
}

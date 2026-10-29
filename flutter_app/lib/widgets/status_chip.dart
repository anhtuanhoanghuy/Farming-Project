import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';

enum StatusKind { online, degraded, offline, error, valid, enabled, full }

class StatusChip extends StatelessWidget {
  const StatusChip({
    super.key,
    required this.label,
    required this.kind,
  });

  final String label;
  final StatusKind kind;

  @override
  Widget build(BuildContext context) {
    late Color bg;
    late Color fg;
    switch (kind) {
      case StatusKind.online:
      case StatusKind.valid:
      case StatusKind.enabled:
        bg = AppColors.successBg;
        fg = AppColors.successText;
      case StatusKind.degraded:
        bg = AppColors.degradedBg;
        fg = AppColors.degradedText;
      case StatusKind.offline:
        bg = AppColors.offlineBg;
        fg = AppColors.offlineText;
      case StatusKind.error:
        bg = AppColors.errorSoft;
        fg = AppColors.errorText;
      case StatusKind.full:
        bg = AppColors.successBg;
        fg = AppColors.successText;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: AppTextStyles.chip.copyWith(color: fg),
      ),
    );
  }
}

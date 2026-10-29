import 'package:flutter/material.dart';

import '../models/provision_failure_args.dart';
import '../navigation/app_routes.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../widgets/app_buttons.dart';
import '../widgets/app_card.dart';
import '../widgets/screen_scaffold.dart';

class ProvisionFailureScreen extends StatelessWidget {
  const ProvisionFailureScreen({super.key, required this.args});

  final ProvisionFailureArgs args;

  @override
  Widget build(BuildContext context) {
    return ScreenScaffold(
      title: 'Hoàn tất',
      showBack: true,
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 28, 16, 24),
        child: Column(
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.danger, width: 2),
              ),
              child: const Icon(
                Icons.close_rounded,
                color: AppColors.danger,
                size: 36,
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'Thiết lập cấu hình thất bại',
              textAlign: TextAlign.center,
              style: AppTextStyles.heading,
            ),
            const SizedBox(height: 8),
            Text(
              args.message,
              textAlign: TextAlign.center,
              style: AppTextStyles.bodySecondary,
            ),
            const SizedBox(height: 22),
            const AppCard(
              child: Column(
                children: [
                  _FailureStep(
                    label: 'Thiết bị chưa xác nhận hoàn tất cấu hình',
                  ),
                  SizedBox(height: 12),
                  _FailureStep(label: 'Chưa xác nhận lưu cấu hình'),
                  SizedBox(height: 12),
                  _FailureStep(label: 'Chưa hoàn tất kiểm tra kết nối mạng'),
                ],
              ),
            ),
            const SizedBox(height: 16),
            OutlineAppButton(
              label: 'Về danh sách thiết bị',
              onPressed: () => Navigator.of(
                context,
              ).pushNamedAndRemoveUntil(AppRoutes.shell, (route) => false),
            ),
          ],
        ),
      ),
    );
  }
}

class _FailureStep extends StatelessWidget {
  const _FailureStep({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Icon(
        Icons.error_outline_rounded,
        size: 20,
        color: AppColors.danger,
      ),
      const SizedBox(width: 10),
      Expanded(child: Text(label, style: AppTextStyles.body)),
    ],
  );
}

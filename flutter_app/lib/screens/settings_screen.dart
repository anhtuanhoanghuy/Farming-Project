import 'package:flutter/material.dart';

import '../core/app_config.dart';
import '../navigation/app_routes.dart';
import '../services/auth_service.dart';
import '../services/device_repository.dart';
import '../services/device_transfer_watcher.dart';
import '../services/mqtt_session_manager.dart';
import '../state/developer_access_controller.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../widgets/app_card.dart';
import '../widgets/screen_scaffold.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.inShell = true, this.showBack = false});

  final bool inShell;
  final bool showBack;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const _versionTapLimit = 30;
  int _versionTapCount = 0;

  void _onVersionTap() {
    final access = DeveloperAccessController.instance;
    if (access.hasAccess) return;

    _versionTapCount++;
    if (_versionTapCount < _versionTapLimit) return;

    _versionTapCount = 0;
    access.setAccess(true);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Đã cấp lại quyền nhà phát triển')),
    );
  }

  Future<void> _revokeDeveloperAccess() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        title: const Text(
          'Thu hồi quyền nhà phát triển?',
          style: AppTextStyles.sectionTitle,
        ),
        content: const Text(
          'Chế độ nhà phát triển sẽ bị ẩn.',
          style: AppTextStyles.bodySecondary,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(
              'Hủy',
              style: AppTextStyles.link.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              'Thu hồi',
              style: AppTextStyles.link.copyWith(color: AppColors.errorText),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      DeveloperAccessController.instance.setAccess(false);
      _versionTapCount = 0;
    }
  }

  String get _accountEmail {
    try {
      return AuthService.email ?? '—';
    } catch (_) {
      return '—';
    }
  }

  Future<void> _signOut() async {
    final navigator = Navigator.of(context, rootNavigator: true);
    try {
      await MqttSessionManager.instance.stop();
    } catch (error) {
      debugPrint('[MQTT] Disconnect khi đăng xuất thất bại: $error');
    }
    DeviceRepository.instance.clear();
    DeviceTransferWatcher.instance.stop();
    try {
      await AuthService.signOut();
    } catch (_) {}
    if (navigator.mounted) {
      navigator.pushNamedAndRemoveUntil(AppRoutes.login, (r) => false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ScreenScaffold(
      showMore: false,
      title: 'Cài đặt',
      showBack: widget.showBack,
      leadingIcon: Icons.settings,
      embedInTab: widget.inShell,
      navIndex: widget.inShell ? null : 2,
      onNavTap: widget.inShell ? null : (i) => AppRoutes.openTab(context, i),
      body: ListenableBuilder(
        listenable: DeveloperAccessController.instance,
        builder: (context, _) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Ứng dụng', style: AppTextStyles.sectionTitle),
              const SizedBox(height: 12),
              AppCard(
                child: Column(
                  children: [
                    _KvRow(
                      left: 'Phiên bản ứng dụng',
                      right: AppConfig.appVersion,
                      onTap: _onVersionTap,
                    ),
                    SizedBox(height: 10),
                    const _KvRow(left: 'Nền tảng', right: 'Android'),
                    SizedBox(height: 10),
                    const _KvRow(left: 'Ngôn ngữ', right: 'Tiếng Việt'),
                    SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Hỗ trợ · 0963657345',
                        style: AppTextStyles.caption,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              const Text('Tài khoản', style: AppTextStyles.sectionTitle),
              const SizedBox(height: 12),
              AppCard(
                child: _KvRow(left: 'Đăng nhập Google', right: _accountEmail),
              ),
              if (DeveloperAccessController.instance.hasAccess) ...[
                const SizedBox(height: 12),
                AppCard(
                  color: AppColors.mint,
                  borderColor: AppColors.primarySoft,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          'Chế độ nhà phát triển',
                          style: AppTextStyles.chip.copyWith(
                            color: AppColors.primary,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: OutlinedButton(
                          onPressed: _revokeDeveloperAccess,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.errorText,
                            backgroundColor: AppColors.surface,
                            side: const BorderSide(color: AppColors.border),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            textStyle: AppTextStyles.buttonPrimary.copyWith(
                              color: AppColors.errorText,
                            ),
                          ),
                          child: const Text('Thu hồi chế độ nhà phát triển'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 22),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: TextButton.icon(
                  onPressed: _signOut,
                  icon: const Icon(Icons.logout_rounded, size: 20),
                  label: const Text('Đăng xuất'),
                  style: TextButton.styleFrom(
                    backgroundColor: AppColors.errorBg,
                    foregroundColor: AppColors.errorText,
                    textStyle: AppTextStyles.buttonPrimary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                      side: const BorderSide(color: AppColors.errorSoft),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _KvRow extends StatelessWidget {
  const _KvRow({required this.left, required this.right, this.onTap});

  final String left;
  final String right;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Row(
        children: [
          Expanded(child: Text(left, style: AppTextStyles.bodySecondary)),
          Text(right, style: AppTextStyles.bodyMedium),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_update_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';

/// Blocks the app until the user installs the new release; declining closes the app.
class ForceUpdateDialog extends StatefulWidget {
  const ForceUpdateDialog({super.key, required this.release});

  final AppRelease release;

  static Future<void> show(BuildContext context, AppRelease release) =>
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => ForceUpdateDialog(release: release),
      );

  @override
  State<ForceUpdateDialog> createState() => _ForceUpdateDialogState();
}

class _ForceUpdateDialogState extends State<ForceUpdateDialog> {
  bool _busy = false;
  double? _progress;
  String? _error;

  Future<void> _install() async {
    setState(() {
      _busy = true;
      _progress = null;
      _error = null;
    });
    try {
      await AppUpdateService.downloadAndInstall(
        widget.release,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
    } on UpdateException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Cập nhật thất bại: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final notes = widget.release.notes;
    return PopScope(
      canPop: false,
      child: AlertDialog(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Có bản cập nhật', style: AppTextStyles.sectionTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Phiên bản ${widget.release.versionName} đã sẵn sàng. '
              'Bạn cần cập nhật để tiếp tục sử dụng ứng dụng.',
              style: AppTextStyles.bodyMedium,
            ),
            if (notes != null && notes.trim().isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(notes, style: AppTextStyles.bodySecondary),
            ],
            if (_busy) ...[
              const SizedBox(height: 14),
              LinearProgressIndicator(value: _progress),
              const SizedBox(height: 6),
              Text(
                _progress == null
                    ? 'Đang tải...'
                    : 'Đang tải ${(_progress! * 100).round()}%',
                style: AppTextStyles.caption,
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: AppTextStyles.bodySecondary.copyWith(
                  color: AppColors.errorText,
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => SystemNavigator.pop(),
            child: Text(
              'Thoát',
              style: AppTextStyles.link.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
          ),
          FilledButton(
            onPressed: _busy ? null : _install,
            child: Text(_error == null ? 'Cài đặt' : 'Thử lại'),
          ),
        ],
      ),
    );
  }
}

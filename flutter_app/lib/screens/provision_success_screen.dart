import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/error_text.dart';
import '../models/device_selection.dart';
import '../models/provision_success_args.dart';
import '../navigation/app_routes.dart';
import '../protocol/device_snapshot.dart';
import '../protocol/mqtt_topics.dart';
import 'dashboard_screen.dart';
import '../services/crud_api.dart';
import '../services/device_repository.dart';
import '../services/mqtt_session_manager.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../widgets/app_buttons.dart';
import '../widgets/app_card.dart';
import '../widgets/screen_scaffold.dart';

class ProvisionSuccessScreen extends StatefulWidget {
  const ProvisionSuccessScreen({super.key, required this.args});

  final ProvisionSuccessArgs args;

  @override
  State<ProvisionSuccessScreen> createState() => _ProvisionSuccessScreenState();
}

class _ProvisionSuccessScreenState extends State<ProvisionSuccessScreen> {
  /// True once the device is saved in the database and added to MQTT (or
  /// that failed): only then can the user leave for the dashboard.
  bool _registered = false;

  /// How long to wait for the device's first snapshot, which carries its name.
  static const _snapshotWait = Duration(seconds: 10);

  /// The name the device reports; the BLE name until it is known.
  late String _name = widget.args.deviceName;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _registerDevice();
    });
  }

  Future<void> _registerDevice() async {
    try {
      await _register();
    } finally {
      if (mounted) setState(() => _registered = true);
    }
  }

  void _openDashboard() {
    final navigator = Navigator.of(context);
    navigator.pushNamedAndRemoveUntil(AppRoutes.shell, (route) => false);
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => DashboardScreen(
          device: DeviceSelection(deviceId: widget.args.deviceId, name: _name),
          inShell: false,
        ),
      ),
    );
  }

  Future<void> _register() async {
    final maxSensorCount = widget.args.result.maxSensorCount;
    final maxLoadCount = widget.args.result.maxLoadCount;
    if (maxSensorCount == null || maxLoadCount == null) {
      throw StateError('Provisioning result is missing device capacities');
    }
    var mqttReady = false;
    try {
      await MqttSessionManager.instance.startForUser(widget.args.userId);
      await MqttSessionManager.instance.addDevice(
        widget.args.deviceId,
        name: widget.args.deviceName,
      );
      mqttReady = true;
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(userErrorText('Không thể đăng ký thiết bị MQTT', error)),
          ),
        );
      }
    }
    // The name comes from the MQTT snapshot. Capacities come from BLE
    // provisioning so registration does not depend on MQTT timing.
    final reported = mqttReady ? await _reportedSnapshot() : null;
    final reportedName = reported?.deviceName?.trim();
    final name = reportedName != null && reportedName.isNotEmpty
        ? reportedName
        : widget.args.deviceName;
    if (mounted) setState(() => _name = name);
    try {
      await CrudApi.run(
        'Provisioning BLE hoàn tất (state=done, saved=true) → đăng ký thiết bị',
        () => CrudApi.addDevice(
          macAddress: widget.args.deviceId,
          name: name,
          maxSensorCount: maxSensorCount,
          maxLoadCount: maxLoadCount,
        ),
      );
      await DeviceRepository.instance.refresh();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              userErrorText('Không lưu được thiết bị vào database', error),
            ),
          ),
        );
      }
    }
  }

  /// The device's first snapshot on the `status` topic (it carries
  /// `device_name` and `capabilities`), or null when none arrives within
  /// [_snapshotWait].
  Future<DeviceSnapshot?> _reportedSnapshot() async {
    final manager = MqttSessionManager.instance;
    final deviceId = widget.args.deviceId;
    DeviceSnapshot? parse(MqttDeviceMessage? message) {
      if (message == null) return null;
      try {
        final json = jsonDecode(message.payload);
        return json is Map
            ? DeviceSnapshot.tryParse(json, message.receivedAt)
            : null;
      } on FormatException {
        return null;
      }
    }

    final known = parse(manager.latestSnapshot(deviceId));
    if (known != null) return known;
    try {
      final message = await manager.messages
          .where(
            (m) =>
                m.deviceId == deviceId &&
                m.kind == MqttDeviceTopicKind.status &&
                parse(m) != null,
          )
          .first
          .timeout(_snapshotWait);
      return parse(message);
    } on TimeoutException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final warning = widget.args.result.status == 'WARNING';
    final resultColor = warning ? AppColors.warningText : AppColors.primary;
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
                border: Border.all(color: resultColor, width: 2),
              ),
              child: Icon(
                warning ? Icons.warning_amber_rounded : Icons.check_rounded,
                color: resultColor,
                size: 36,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              warning
                  ? 'Thiết lập hoàn tất có cảnh báo'
                  : 'Thiết lập cấu hình thành công',
              textAlign: TextAlign.center,
              style: AppTextStyles.heading,
            ),
            const SizedBox(height: 8),
            Text(
              warning
                  ? widget.args.result.message ??
                        widget.args.result.reason ??
                        'Thiết bị đã lưu cấu hình nhưng báo trạng thái kết nối cần chú ý.'
                  : 'Thiết bị đã lưu cấu hình và hoàn tất kiểm tra kết nối mạng.',
              textAlign: TextAlign.center,
              style: AppTextStyles.bodySecondary,
            ),
            const SizedBox(height: 22),
            AppCard(
              child: Column(
                children: [
                  const _StepRow(
                    icon: Icons.check_rounded,
                    label: 'Đã nhận cấu hình',
                    done: true,
                  ),
                  const SizedBox(height: 12),
                  _StepRow(
                    icon: widget.args.result.saved == true
                        ? Icons.check_rounded
                        : Icons.error_outline,
                    label: widget.args.result.saved == true
                        ? 'Đã lưu cấu hình'
                        : 'Chưa xác nhận lưu cấu hình',
                    done: widget.args.result.saved == true,
                  ),
                  const SizedBox(height: 12),
                  _StepRow(
                    icon: warning
                        ? Icons.warning_amber_rounded
                        : Icons.check_rounded,
                    label: warning
                        ? 'Kết nối mạng có cảnh báo'
                        : 'Đã kiểm tra kết nối mạng',
                    done: !warning,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            PrimaryButton(
              label: _registered
                  ? 'Mở bảng điều khiển'
                  : 'Đang đăng ký thiết bị...',
              icon: Icons.dashboard_rounded,
              onPressed: _registered ? _openDashboard : null,
            ),
            const SizedBox(height: 12),
            OutlineAppButton(
              label: 'Về danh sách thiết bị',
              onPressed: () {
                Navigator.of(
                  context,
                ).pushNamedAndRemoveUntil(AppRoutes.shell, (route) => false);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({required this.icon, required this.label, required this.done});

  final IconData icon;
  final String label;
  final bool done;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          icon,
          size: 20,
          color: done ? AppColors.primary : AppColors.textSecondary,
        ),
        const SizedBox(width: 10),
        Text(label, style: AppTextStyles.body),
      ],
    );
  }
}

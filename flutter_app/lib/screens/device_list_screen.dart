import 'package:flutter/material.dart';

import '../models/device_record.dart';
import '../models/device_selection.dart';
import '../navigation/app_routes.dart';
import '../services/crud_api.dart';
import '../services/device_repository.dart';
import '../services/mqtt_session_manager.dart';
import '../state/device_health.dart';
import '../state/device_presence.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../widgets/app_buttons.dart';
import '../widgets/app_card.dart';
import '../widgets/screen_scaffold.dart';
import '../widgets/status_chip.dart';

class DeviceListScreen extends StatefulWidget {
  const DeviceListScreen({super.key, this.inShell = false});

  final bool inShell;

  @override
  State<DeviceListScreen> createState() => _DeviceListScreenState();
}

class _DeviceListScreenState extends State<DeviceListScreen> {
  final _repository = DeviceRepository.instance;

  @override
  void initState() {
    super.initState();
    DevicePresence.instance.start();
    DeviceHealth.instance.start();
    _repository.refresh();
  }

  /// Pull-to-refresh: reloads the devices with a CRUD `SELECT`, shown in the
  /// CRUD log in developer mode.
  Future<void> _reload() => CrudApi.run(
    'Kéo xuống làm mới danh sách thiết bị',
    _repository.refresh,
  );

  /// Chip from the device's retained presence message (LWT).
  static (String, StatusKind) _presenceChip(bool connected, bool? online) {
    if (!connected) return ('Đang đồng bộ', StatusKind.degraded);
    return switch (online) {
      true => ('Trực tuyến', StatusKind.online),
      false => ('Ngoại tuyến', StatusKind.offline),
      null => ('Đang chờ trạng thái', StatusKind.degraded),
    };
  }

  @override
  Widget build(BuildContext context) {
    final manager = MqttSessionManager.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([
        _repository,
        manager,
        DevicePresence.instance,
        DeviceHealth.instance,
      ]),
      builder: (context, _) {
        final devices = _repository.devices;
        final error = _repository.error;
        final loadingFirst = _repository.isLoading && devices.isEmpty;
        return ScreenScaffold(
          showMore: false,
          title: 'Danh sách thiết bị',
          leadingIcon: Icons.developer_board,
          embedInTab: widget.inShell,
          navIndex: widget.inShell ? null : 0,
          onNavTap: widget.inShell ? null : (i) => AppRoutes.openTab(context, i),
          body: RefreshIndicator(
            onRefresh: _reload,
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${devices.length} thiết bị',
                    style: AppTextStyles.heading,
                  ),
                  const SizedBox(height: 16),
                  PrimaryButton(
                    label: 'Thêm thiết bị',
                    icon: Icons.add,
                    onPressed: () {
                      Navigator.of(
                        context,
                        rootNavigator: true,
                      ).pushNamed(AppRoutes.bleScan);
                    },
                  ),
                  const SizedBox(height: 16),
                  if (error != null) ...[
                    _ErrorCard(
                      message: devices.isEmpty
                          ? error
                          : '$error\nĐang hiển thị danh sách đã lưu trên máy.',
                      retrying: _repository.isLoading,
                      onRetry: _reload,
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (loadingFirst)
                    const AppCard(
                      child: Row(
                        children: [
                          SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          SizedBox(width: 12),
                          Text(
                            'Đang tải danh sách thiết bị...',
                            style: AppTextStyles.bodySecondary,
                          ),
                        ],
                      ),
                    )
                  else if (devices.isEmpty && error == null)
                    const AppCard(
                      child: Text(
                        'Chưa có thiết bị được đăng ký. Hãy thêm thiết bị.',
                        style: AppTextStyles.bodySecondary,
                      ),
                    ),
                  for (var i = 0; i < devices.length; i++) ...[
                    if (i > 0) const SizedBox(height: 12),
                    Builder(
                      builder: (context) {
                        final online = DevicePresence.instance.isOnline(
                          devices[i].macAddress,
                        );
                        final (label, kind) = _presenceChip(
                          manager.isConnected,
                          online,
                        );
                        return _DeviceCard(
                          name: devices[i].name,
                          network: devices[i].macAddress,
                          detail: _detail(devices[i]),
                          chipLabel: label,
                          kind: kind,
                          // The "!" is for a device that is online and reports
                          // an error: nothing is flagged without one.
                          hasError:
                              online == true &&
                              DeviceHealth.instance.hasErrors(
                                devices[i].macAddress,
                              ),
                          onView: () => Navigator.of(context).pushNamed(
                            AppRoutes.dashboard,
                            arguments: DeviceSelection(
                              deviceId: devices[i].macAddress,
                              name: devices[i].name,
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  static String _detail(DeviceRecord device) {
    String count(int? value, String unit) =>
        value == null ? '? $unit' : '$value $unit';
    return 'Tối đa ${count(device.maxSensorCount, 'cảm biến')} · '
        '${count(device.maxLoadCount, 'tải')}';
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({
    required this.message,
    required this.retrying,
    required this.onRetry,
  });

  final String message;
  final bool retrying;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            message,
            style: AppTextStyles.bodySecondary.copyWith(
              color: AppColors.errorText,
            ),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: retrying ? null : onRetry,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: Text(retrying ? 'Đang tải...' : 'Thử lại'),
          ),
        ],
      ),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({
    required this.name,
    required this.network,
    required this.detail,
    required this.chipLabel,
    required this.kind,
    required this.hasError,
    required this.onView,
  });

  final String name;
  final String network;
  final String detail;
  final String chipLabel;
  final StatusKind kind;
  final bool hasError;
  final VoidCallback onView;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onView,
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(name, style: AppTextStyles.cardTitle),
                      ),
                      if (hasError) ...[
                        const SizedBox(width: 6),
                        const Icon(
                          Icons.error_rounded,
                          size: 18,
                          color: AppColors.errorText,
                        ),
                      ],
                    ],
                  ),
                ),
                StatusChip(label: chipLabel, kind: kind),
              ],
            ),
            const SizedBox(height: 2),
            Text(network, style: AppTextStyles.bodyMedium),
            const SizedBox(height: 8),
            Text(detail, style: AppTextStyles.bodySecondary),
          ],
        ),
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/error_text.dart';
import '../models/device_selection.dart';
import '../navigation/app_routes.dart';
import '../protocol/device_snapshot.dart';
import '../protocol/mqtt_payloads.dart';
import '../protocol/port_ids.dart';
import '../services/crud_api.dart' show appMessengerKey;
import '../services/load_sync.dart';
import '../services/mqtt_session_manager.dart';
import '../state/device_state.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../widgets/app_buttons.dart';
import '../widgets/app_card.dart';
import '../widgets/screen_scaffold.dart';
import '../widgets/status_chip.dart';

class SensorCapacityScreen extends StatelessWidget {
  const SensorCapacityScreen({
    super.key,
    required this.device,
    this.inShell = true,
  });

  final DeviceSelection device;
  final bool inShell;

  /// Sensors come from the snapshot the ESP32 publishes after each change.
  List<SensorInput> _inputsOf(DeviceSnapshot? snapshot, String type) =>
      [
        for (final input in snapshot?.inputs ?? const <SensorInput>[])
          if (input.interfaceType == type &&
              !DeviceState.instance.isSensorHidden(input.portId))
            input,
      ]..sort((a, b) => a.portId.compareTo(b.portId));

  SensorConfigSelection _selectionFor(SensorInput sensor) =>
      SensorConfigSelection(
        device: device,
        interfaceType: sensor.interfaceType,
        portId: sensor.portId,
        name: sensor.name,
        slaveId: sensor.slaveId,
        enabled: sensor.enabled,

      );

  Future<void> _openConfig(
    BuildContext context,
    SensorConfigSelection selection,
  ) => Navigator.of(
    context,
  ).pushNamed(AppRoutes.sensorConfig, arguments: selection);

  /// New sensor: starts as the first type that still has a free port; the type
  /// can be changed on the configuration screen.
  Future<void> _add(BuildContext context, DeviceSnapshot? snapshot) async {
    for (final type in PortIds.interfaceTypes) {
      final ports = snapshot?.freePortsFor(type) ?? PortIds.defaultPorts(type);
      if (ports.isEmpty) continue;
      return _openConfig(
        context,
        SensorConfigSelection(
          device: device,
          interfaceType: type,
          portId: ports.first,
          name: 'new_sensor',
        ),
      );
    }
  }

  Future<void> _confirmDelete(BuildContext context, SensorInput sensor) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        title: const Text('Xóa cảm biến', style: AppTextStyles.sectionTitle),
        content: Text(
          'Bạn có chắc chắn muốn xóa cảm biến ${sensor.name}?',
          style: AppTextStyles.bodySecondary,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Hủy'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              'Đồng ý',
              style: AppTextStyles.link.copyWith(color: AppColors.errorText),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    DeviceState.instance.hideSensor(sensor.portId);
    try {
      await MqttSessionManager.instance.publishCommandAndWaitForAck(
        device.deviceId,
        MqttPayloads.deleteSensor(
          cmdId: MqttPayloads.newCommandId(),
          sensorId: sensor.portId,
        ),
      );
      DeviceState.instance.confirmSensorHidden(sensor.portId);
    } catch (error) {
      DeviceState.instance.restoreSensor(sensor.portId);
      appMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text(userErrorText('Không xóa được cảm biến', error))),
      );
      unawaited(LoadSync.instance.requestStatus());
    }
  }

  @override
  Widget build(BuildContext context) {
    return ScreenScaffold(
      showMore: false,
      title: 'Quản lý cảm biến',
      showBack: true,
      embedInTab: inShell,
      navIndex: inShell ? null : 0,
      onNavTap: inShell ? null : (i) => AppRoutes.openTab(context, i),
      body: RefreshIndicator(
        onRefresh: LoadSync.instance.requestStatus,
        child: ListenableBuilder(
          listenable: DeviceState.instance,
          builder: (context, _) {
            final snapshot = DeviceState.instance.snapshot;
            final sensors = [
              for (final type in PortIds.interfaceTypes)
                ..._inputsOf(snapshot, type),
            ];
            final total = PortIds.interfaceTypes.fold<int>(
              0,
              (sum, type) =>
                  sum +
                  (snapshot?.portsFor(type) ?? PortIds.defaultPorts(type))
                      .length,
            );
            final isFull = PortIds.interfaceTypes.every(
              (type) =>
                  (snapshot?.freePortsFor(type) ?? PortIds.defaultPorts(type))
                      .isEmpty,
            );
            return SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: Column(
                children: [
                  if (snapshot == null) ...[
                    const AppCard(
                      child: Text(
                        'Đang chờ đồng bộ...',
                        style: AppTextStyles.bodySecondary,
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  _CapacityCard(used: sensors.length, total: total),
                  for (final sensor in sensors) ...[
                    const SizedBox(height: 12),
                    _SensorItem(
                      sensor: sensor,
                      onEdit: () => _openConfig(context, _selectionFor(sensor)),
                      onDelete: () => _confirmDelete(context, sensor),
                    ),
                  ],
                  const SizedBox(height: 12),
                  if (isFull)
                    const GhostButton(label: 'Thêm cảm biến', onPressed: null)
                  else
                    OutlineAppButton(
                      label: 'Thêm cảm biến',
                      icon: Icons.add,
                      onPressed: () => _add(context, snapshot),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _CapacityCard extends StatelessWidget {
  const _CapacityCard({required this.used, required this.total});

  final int used;
  final int total;

  @override
  Widget build(BuildContext context) {
    final free = total - used;
    return AppCard(
      color: AppColors.mint,
      borderColor: AppColors.primarySoft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Dung lượng cổng đầu vào',
                  style: AppTextStyles.bodySecondary,
                ),
              ),
              Text('$used / $total đã cấu hình', style: AppTextStyles.mono),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            free == 0
                ? 'Đã dùng hết số lượng cổng. Chỉ có thể sửa các cảm biến đã cấu hình.'
                : 'Còn $free cổng trống. Có thể thêm cảm biến mới.',
            style: AppTextStyles.chip.copyWith(color: AppColors.primary),
          ),
        ],
      ),
    );
  }
}

class _SensorItem extends StatelessWidget {
  const _SensorItem({
    required this.sensor,
    required this.onEdit,
    required this.onDelete,
  });

  final SensorInput sensor;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(sensor.name, style: AppTextStyles.cardTitle),
              ),
              StatusChip(
                label: sensor.enabled ? 'Đã bật' : 'Đã tắt',
                kind: sensor.enabled ? StatusKind.enabled : StatusKind.degraded,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text('Cổng: ${sensor.portId}', style: AppTextStyles.mono),
          const SizedBox(height: 12),
          OutlineAppButton(
            label: 'Sửa cấu hình',
            height: 46,
            onPressed: onEdit,
          ),
        ],
      ),
    );
  }
}

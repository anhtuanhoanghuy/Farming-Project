import 'dart:async';

import 'package:flutter/material.dart';

import '../core/error_text.dart';
import '../models/device_selection.dart';
import '../models/load_control_selection.dart';
import '../navigation/app_routes.dart';
import '../protocol/device_snapshot.dart';
import '../protocol/device_telemetry.dart';
import '../protocol/mqtt_payloads.dart';
import '../protocol/port_ids.dart';
import '../services/crud_api.dart';
import '../services/device_api.dart';
import '../services/device_repository.dart';
import '../services/device_transfer_watcher.dart';
import '../services/load_sync.dart';
import '../services/mqtt_session_manager.dart';
import '../state/device_presence.dart';
import '../state/device_state.dart';
import '../state/load_controller.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../widgets/app_buttons.dart';
import '../widgets/app_card.dart';
import '../widgets/app_more_menu.dart';
import '../widgets/rename_dialog.dart';
import '../widgets/screen_scaffold.dart';
import '../widgets/status_chip.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key, required this.device, this.inShell = true});

  final DeviceSelection device;
  final bool inShell;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with WidgetsBindingObserver {
  int _tab = 0;
  late String _name = widget.device.name;
  StreamSubscription<String>? _transferSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _transferSubscription = DeviceTransferWatcher.instance.transfers.listen((
      deviceId,
    ) {
      if (deviceId == widget.device.deviceId && mounted) {
        Navigator.of(context).maybePop();
      }
    });
    unawaited(LoadSync.instance.attach(widget.device.deviceId));
  }

  @override
  void dispose() {
    _transferSubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    LoadSync.instance.detach();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(LoadSync.instance.requestStatus());
    }
  }

  /// Rename: the ESP32 gets `SET_DEVICE_NAME`; once it acknowledges, the name
  /// in the `devices` table follows.
  Future<void> _rename() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => RenameDialog(
        title: 'Đổi tên thiết bị',
        hint: 'Tên thiết bị',
        initial: _name,
      ),
    );
    final v = name?.trim();
    if (v == null || v.isEmpty || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final previousName = _name;
    setState(() => _name = v);
    try {
      await MqttSessionManager.instance.publishCommandAndWaitForAck(
        widget.device.deviceId,
        MqttPayloads.setDeviceName(cmdId: MqttPayloads.newCommandId(), name: v),
      );
    } catch (error) {
      if (mounted) setState(() => _name = previousName);
      messenger.showSnackBar(
        SnackBar(
          content: Text(userErrorText('Không đổi được tên thiết bị', error)),
        ),
      );
      unawaited(LoadSync.instance.requestStatus());
      return;
    }
    try {
      await CrudApi.run(
        'Thiết bị đã xác nhận đổi tên thiết bị → "$v"',
        () => CrudApi.renameDevice(widget.device.deviceId, v),
      );
      await DeviceRepository.instance.refresh();
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            userErrorText(
              'Thiết bị đã đổi tên nhưng chưa cập nhật được database',
              error,
            ),
          ),
        ),
      );
    }
  }

  Future<void> _confirmEmergencyStop() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Dừng khẩn cấp', style: AppTextStyles.sectionTitle),
        content: const Text(
          'Tắt mọi tải, xóa hẹn giờ, điều kiện và lịch hẹn của các tải, và '
          'vô hiệu hóa tất cả cảm biến. Bạn phải bật lại từng cảm biến.',
          style: AppTextStyles.bodySecondary,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              'Hủy',
              style: AppTextStyles.link.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              'Dừng khẩn cấp',
              style: AppTextStyles.link.copyWith(color: AppColors.errorText),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) await _emergencyStop();
  }

  Future<void> _emergencyStop() async {
    final messenger = ScaffoldMessenger.of(context);
    final before = [
      for (final load in LoadController.loads) load.captureLive(),
    ];
    for (final load in LoadController.loads) {
      load
        ..cancelDelay()
        ..setOn(false);
    }
    try {
      await MqttSessionManager.instance.publishCommandAndWaitForAck(
        widget.device.deviceId,
        MqttPayloads.emergencyStop(cmdId: MqttPayloads.newCommandId()),
      );
    } catch (error) {
      for (var i = 0; i < before.length; i++) {
        LoadController.loads[i].restoreLive(before[i]);
      }
      messenger.showSnackBar(
        SnackBar(
          content: Text(userErrorText('Không dừng khẩn cấp được', error)),
        ),
      );
      unawaited(LoadSync.instance.requestStatus());
    }
  }

  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Xóa thiết bị', style: AppTextStyles.sectionTitle),
        content: Text(
          'Bạn có chắc chắn muốn xóa thiết bị $_name?',
          style: AppTextStyles.bodySecondary,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              'Hủy',
              style: AppTextStyles.link.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
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
    if (confirmed != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      await CrudApi.run(
        'Nhấn Đồng ý xóa thiết bị "$_name"',
        () => DeviceApi.deleteDevice(widget.device.deviceId),
      );
      await DeviceRepository.instance.refresh();
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(userErrorText('Không xóa được thiết bị', error)),
        ),
      );
      return;
    }
    messenger.showSnackBar(const SnackBar(content: Text('Đã xóa thiết bị')));
    if (mounted) navigator.maybePop();
  }

  @override
  Widget build(BuildContext context) {
    return ScreenScaffold(
      title: 'Bảng điều khiển',
      showBack: true,
      embedInTab: widget.inShell,
      navIndex: widget.inShell ? null : 0,
      onNavTap: widget.inShell ? null : (i) => AppRoutes.openTab(context, i),
      headerTrailing: AppMoreMenu<String>(
        onSelected: (_) => _confirmDelete(),
        itemBuilder: (_) => const [
          PopupMenuItem(
            value: 'delete',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.delete_outline_rounded,
                  size: 20,
                  color: AppColors.errorText,
                ),
                SizedBox(width: 10),
                Text(
                  'Xóa thiết bị',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: AppColors.errorText,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: LoadSync.instance.requestTelemetry,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _DeviceSummaryCard(
                deviceId: widget.device.deviceId,
                name: _name,
                onRename: _rename,
                onEmergencyStop: _confirmEmergencyStop,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Row(
                  children: [
                    _SegChip(
                      label: 'Cảm biến',
                      selected: _tab == 0,
                      onTap: () => setState(() => _tab = 0),
                    ),
                    const SizedBox(width: 8),
                    _SegChip(
                      label: 'Tải',
                      selected: _tab == 1,
                      onTap: () => setState(() => _tab = 1),
                    ),
                  ],
                ),
              ),
              if (_tab == 0)
                _SensorsTab(device: widget.device)
              else
                _LoadsTab(device: widget.device),
            ],
          ),
        ),
      ),
    );
  }
}

class _SegChip extends StatelessWidget {
  const _SegChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? AppColors.primary : AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.border,
          ),
        ),
        child: Text(
          label,
          style: AppTextStyles.bodyMedium.copyWith(
            color: selected ? AppColors.textOnPrimary : AppColors.textSecondary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// Alerts the ESP32 raises in its snapshot. The emergency stop is not shown
/// here: it is recorded in the diagnostics error log.
class _DeviceAlerts extends StatelessWidget {
  const _DeviceAlerts();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: DeviceState.instance,
      builder: (context, _) {
        final snapshot = DeviceState.instance.snapshot;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (snapshot?.interlockTripped == true) ...[
              const _AlertCard(message: 'Interlock đã ngắt tải.'),
              const SizedBox(height: 20),
            ],
          ],
        );
      },
    );
  }
}

/// One card per enabled sensor of the snapshot; telemetry fills in the values
/// (shown as "_" until telemetry has arrived).
class _SensorsTab extends StatelessWidget {
  const _SensorsTab({required this.device});

  final DeviceSelection device;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: DeviceState.instance,
      builder: (context, _) {
        final state = DeviceState.instance;
        final snapshot = state.snapshot;
        final enabled = [
          for (final input in snapshot?.inputs ?? const <SensorInput>[])
            if (input.enabled && !PortIds.isReservedLoadSensorName(input.name))
              input,
        ];
        final faulty = [
          for (final input in enabled)
            if (state.reading(input.portId) case final live? when !live.valid)
              input,
        ].firstOrNull;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _DeviceAlerts(),
            if (faulty != null) ...[
              _AlertCard(
                message:
                    'Cảm biến ${faulty.name}: không đọc được. Kiểm tra cảm biến '
                    'và đường truyền.',
              ),
              const SizedBox(height: 20),
            ],
            const Text('Cảm biến hiện tại', style: AppTextStyles.sectionTitle),
            const SizedBox(height: 12),
            if (enabled.isEmpty)
              AppCard(
                child: Text(
                  snapshot == null
                      ? 'Đang chờ đồng bộ từ thiết bị...'
                      : 'Chưa có cảm biến nào được bật.',
                  style: AppTextStyles.bodySecondary,
                ),
              )
            else
              for (final sensor in enabled) ...[
                _SensorCard(input: sensor, live: state.reading(sensor.portId)),
                const SizedBox(height: 12),
              ],
            const SizedBox(height: 2),
            OutlineAppButton(
              label: 'Tùy chỉnh',
              icon: Icons.tune_rounded,
              onPressed: () => Navigator.of(
                context,
              ).pushNamed(AppRoutes.sensorCapacity, arguments: device),
            ),
          ],
        );
      },
    );
  }
}

class _SensorCard extends StatelessWidget {
  const _SensorCard({required this.input, required this.live});

  final SensorInput input;

  /// Latest telemetry of this sensor; null until it has arrived.
  final TelemetryInput? live;

  @override
  Widget build(BuildContext context) {
    final sensor = live;
    final values = sensor?.values ?? const <TelemetryValue>[];
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(input.name, style: AppTextStyles.cardTitle),
          const SizedBox(height: 8),
          if (values.isEmpty)
            // No reading yet: an unknown value has no unit.
            const _Metric(value: '_', unit: '', caption: ''),
          if (values.isNotEmpty)
            Wrap(
              spacing: 24,
              runSpacing: 12,
              children: [
                for (final value in values)
                  _Metric(
                    value: value.display,
                    unit: value.unit,
                    caption: value.name,
                  ),
              ],
            ),
          // Nếu sensor tồn tại và không hợp lệ (lỗi)
          if (sensor != null) ...[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                sensor.valid
                    ? const StatusChip(
                        label: 'Đang hoạt động',
                        kind: StatusKind.valid,
                      )
                    : const StatusChip(label: 'Lỗi', kind: StatusKind.error),
                const Spacer(),
                if (!sensor.valid)
                  const Text(
                    'Không đọc được cảm biến.',
                    style: AppTextStyles.caption,
                  )
                else
                  const SizedBox.shrink(), // Giữ khoảng trống hoặc ẩn đi nếu hợp lệ
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _DeviceSummaryCard extends StatelessWidget {
  const _DeviceSummaryCard({
    required this.deviceId,
    required this.name,
    required this.onRename,
    required this.onEmergencyStop,
  });

  final String deviceId;
  final String name;
  final VoidCallback onRename;
  final VoidCallback onEmergencyStop;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Hàng 1: Tên thiết bị, nút sửa và nút Dừng khẩn cấp
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Phần tên và nút sửa co giãn linh hoạt ở bên trái
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        style: AppTextStyles.heading,
                        overflow: TextOverflow
                            .ellipsis, // Tránh tràn giao diện nếu tên quá dài
                      ),
                    ),
                    IconButton(
                      onPressed: onRename,
                      tooltip: 'Đổi tên thiết bị',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(
                        Icons.edit_rounded,
                        size: 18,
                        color: AppColors.primary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Nút dừng khẩn cấp cố định bên phải, không bị ép co lại
              SizedBox(
                height: 40,
                child: ElevatedButton.icon(
                  onPressed: onEmergencyStop,
                  icon: const Icon(Icons.stop_circle_rounded),
                  label: const Text('Dừng khẩn cấp'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.errorText,
                    foregroundColor: AppColors.textOnPrimary,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    textStyle: AppTextStyles.button.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Hàng 2: Trạng thái trực tuyến và Wi-Fi căn thẳng hàng tuyệt đối
          ListenableBuilder(
            listenable: Listenable.merge([
              DevicePresence.instance,
              MqttSessionManager.instance,
              DeviceState.instance,
            ]),
            builder: (context, _) {
              final connected = MqttSessionManager.instance.isConnected;
              final online = DevicePresence.instance.isOnline(deviceId);
              final (label, kind) = !connected
                  ? ('Đang đồng bộ', StatusKind.degraded)
                  : switch (online) {
                      true => ('Trực tuyến', StatusKind.online),
                      false => ('Ngoại tuyến', StatusKind.offline),
                      null => ('Đang chờ trạng thái', StatusKind.degraded),
                    };
              final net = connected && online == true
                  ? switch (DeviceState.instance.internetMethod) {
                      'WIFI' => 'Wi-Fi · đã kết nối',
                      'ETH' => 'Ethernet · đã kết nối',
                      _ => null,
                    }
                  : null;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  StatusChip(label: label, kind: kind),
                  const Spacer(),
                  if (net != null) Text(net, style: AppTextStyles.bodyMedium),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _AlertCard extends StatelessWidget {
  const _AlertCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      color: AppColors.errorBg,
      borderColor: AppColors.errorSoft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Có cảnh báo',
            style: AppTextStyles.bodyMedium.copyWith(
              color: AppColors.errorText,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            style: AppTextStyles.body.copyWith(color: AppColors.errorText),
          ),
        ],
      ),
    );
  }
}

class _LoadsTab extends StatelessWidget {
  const _LoadsTab({required this.device});

  final DeviceSelection device;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge(LoadController.loads),
    builder: (context, _) {
      final enabledLoads = [
        for (final load in LoadController.loads)
          if (load.enabled) load,
      ];
      final disabledLoads = [
        for (final load in LoadController.loads)
          if (!load.enabled) load,
      ];

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _DeviceAlerts(),
          Text(
            'Tải hiện tại · ${LoadController.loads.length} tải',
            style: AppTextStyles.sectionTitle,
          ),
          const SizedBox(height: 12),
          for (var i = 0; i < enabledLoads.length; i++) ...[
            _LoadCard(load: enabledLoads[i], device: device),
            if (i < enabledLoads.length - 1) const SizedBox(height: 12),
          ],
          if (disabledLoads.isNotEmpty) ...[
            if (enabledLoads.isNotEmpty) const SizedBox(height: 12),
            _DisabledLoadsDropdown(loads: disabledLoads, device: device),
          ],
        ],
      );
    },
  );
}

class _DisabledLoadsDropdown extends StatelessWidget {
  const _DisabledLoadsDropdown({required this.loads, required this.device});

  final List<LoadController> loads;
  final DeviceSelection device;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: EdgeInsets.zero,
      child: ExpansionTile(
        title: const Text('Tải bị vô hiệu hóa', style: AppTextStyles.cardTitle),
        subtitle: Text('${loads.length} tải'),
        shape: const Border(),
        collapsedShape: const Border(),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        children: [
          for (var i = 0; i < loads.length; i++) ...[
            _LoadCard(load: loads[i], device: device),
            if (i < loads.length - 1) const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }
}

class _LoadCard extends StatelessWidget {
  const _LoadCard({required this.load, required this.device});

  final LoadController load;
  final DeviceSelection device;

  /// SET_LOAD_STATE: the switch moves at once and the command goes out after a
  /// short quiet time, with the last state only. When the ESP32 refuses or
  /// stays silent for 5 s the switch goes back and the real state is requested.
  void _setState(BuildContext context, bool state) {
    load.requestOnOff(
      state,
      send: (state) => MqttSessionManager.instance.publishCommandAndWaitForAck(
        device.deviceId,
        MqttPayloads.setLoadState(
          cmdId: MqttPayloads.newCommandId(),
          loadId: load.portId,
          on: state,
        ),
      ),
      onError: (error) {
        appMessengerKey.currentState?.showSnackBar(
          SnackBar(
            content: Text(userErrorText('Không điều khiển được tải', error)),
          ),
        );
        unawaited(LoadSync.instance.requestStatus());
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        load,
        DeviceState.instance,
        DevicePresence.instance,
        MqttSessionManager.instance,
      ]),
      builder: (context, _) {
        final connected = MqttSessionManager.instance.isConnected;
        final online = DevicePresence.instance.isOnline(device.deviceId);
        final known = load.stateKnown && connected && online != false;
        final on = known && load.isOn && load.enabled;
        return AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(load.title, style: AppTextStyles.cardTitle),
                  ),
                  Switch(
                    value: known && load.isOn,
                    onChanged: load.enabled && known
                        ? (value) => _setState(context, value)
                        : null,
                  ),
                ],
              ),
              Text('Cổng ${load.portId}', style: AppTextStyles.monoCaption),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          !load.enabled
                              ? 'Không cho phép'
                              : !known
                              ? 'Chưa rõ'
                              : (on ? 'Đang bật' : 'Đang tắt'),
                          style: AppTextStyles.metric,
                        ),
                        const SizedBox(height: 4),
                      ],
                    ),
                  ),
                  if (load.delayActive)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          load.delayCountdown,
                          style: AppTextStyles.countdown,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          load.delayTargetOn
                              ? 'còn lại trước tự bật'
                              : 'còn lại trước tự tắt',
                          style: AppTextStyles.caption,
                        ),
                      ],
                    ),
                ],
              ),
              const SizedBox(height: 12),
              const Divider(height: 1, color: AppColors.divider),
              InkWell(
                onTap: () {
                  Navigator.of(context).pushNamed(
                    AppRoutes.loadControl,
                    arguments: LoadControlSelection(device: device, load: load),
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.only(top: 14, bottom: 2),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Điều khiển & cấu hình Load ${load.id}',
                          style: AppTextStyles.link,
                        ),
                      ),
                      const Icon(
                        Icons.arrow_forward_rounded,
                        color: AppColors.primary,
                        size: 22,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.value,
    required this.unit,
    required this.caption,
  });

  final String value;
  final String unit;
  final String caption;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(caption, style: AppTextStyles.monoCaption),
        const SizedBox(height: 4),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(value, style: AppTextStyles.metric),
            const SizedBox(width: 6),
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(unit, style: AppTextStyles.unit),
            ),
          ],
        ),
      ],
    );
  }
}

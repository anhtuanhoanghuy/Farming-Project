import 'dart:async';

import 'package:flutter/material.dart';

import '../core/error_text.dart';
import '../models/device_record.dart';
import '../navigation/app_routes.dart';
import '../protocol/device_errors.dart';
import '../protocol/device_snapshot.dart';
import '../protocol/mqtt_payloads.dart';
import '../protocol/port_ids.dart';
import '../services/device_repository.dart';
import '../services/load_sync.dart';
import '../services/mqtt_session_manager.dart';
import '../state/developer_access_controller.dart';
import '../state/device_presence.dart';
import '../state/device_health.dart';
import '../state/device_state.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../widgets/app_buttons.dart';
import '../widgets/app_card.dart';
import '../widgets/app_text_field.dart';
import '../widgets/screen_scaffold.dart';
import '../widgets/status_chip.dart';
import 'console_screen.dart' show ConsoleArgs;

/// Chip of a device row, from the presence the ESP32 reported (LWT/snapshot).
(String, StatusKind) presenceChip({required bool connected, bool? online}) {
  if (!connected) return ('Đang đồng bộ', StatusKind.degraded);
  return switch (online) {
    true => ('Trực tuyến', StatusKind.online),
    false => ('Ngoại tuyến', StatusKind.offline),
    null => ('Đang chờ trạng thái', StatusKind.degraded),
  };
}

/// "14/10/2026 09:41:05".
String _formatTime(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(t.day)}/${two(t.month)}/${t.year} '
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

/// "2 ngày 3 giờ", "5 giờ 12 phút", "42 giây".
String formatUptime(int ms) {
  final total = ms ~/ 1000;
  final days = total ~/ 86400;
  final hours = (total % 86400) ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = total % 60;
  if (days > 0) return '$days ngày $hours giờ';
  if (hours > 0) return '$hours giờ $minutes phút';
  if (minutes > 0) return '$minutes phút $seconds giây';
  return '$seconds giây';
}

class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({
    super.key,
    this.inShell = true,
    this.showBack = false,
    this.repository,
  });

  final bool inShell;
  final bool showBack;

  /// The device list; the app-wide one unless a test gives its own.
  final DeviceRepository? repository;

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  late final DeviceRepository _repository =
      widget.repository ?? DeviceRepository.instance;

  @override
  void initState() {
    super.initState();
    DevicePresence.instance.start();
    DeviceHealth.instance.start();
    unawaited(_repository.refresh());
  }

  void _openDevice(DeviceRecord device) {
    unawaited(DeviceHealth.instance.load(device.macAddress));
    // The state shown below is the one of the attached device.
    if (DeviceState.instance.deviceId != device.macAddress) {
      unawaited(LoadSync.instance.attach(device.macAddress));
    } else {
      unawaited(LoadSync.instance.requestStatus());
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _DeviceDiagnosticsScreen(
          device: device,
          repository: _repository,
          inShell: widget.inShell,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ScreenScaffold(
      showMore: false,
      title: 'Chẩn đoán',
      showBack: widget.showBack,
      leadingIcon: Icons.show_chart,
      embedInTab: widget.inShell,
      navIndex: widget.inShell ? null : 1,
      onNavTap: widget.inShell ? null : (i) => AppRoutes.openTab(context, i),
      body: _DeviceList(repository: _repository, onSelect: _openDevice),
    );
  }
}

class _DeviceDiagnosticsScreen extends StatefulWidget {
  const _DeviceDiagnosticsScreen({
    required this.device,
    required this.repository,
    required this.inShell,
  });

  final DeviceRecord device;
  final DeviceRepository repository;
  final bool inShell;

  @override
  State<_DeviceDiagnosticsScreen> createState() =>
      _DeviceDiagnosticsScreenState();
}

class _DeviceDiagnosticsScreenState extends State<_DeviceDiagnosticsScreen> {
  @override
  void initState() {
    super.initState();
    widget.repository.addListener(_onDevicesChanged);
  }

  @override
  void dispose() {
    widget.repository.removeListener(_onDevicesChanged);
    super.dispose();
  }

  void _onDevicesChanged() {
    if (widget.repository.devices.any(
      (device) => device.macAddress == widget.device.macAddress,
    )) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).maybePop();
    });
  }

  @override
  Widget build(BuildContext context) => ScreenScaffold(
    showMore: false,
    title: 'Chẩn đoán',
    showBack: true,
    leadingIcon: Icons.show_chart,
    onBack: () => Navigator.of(context).maybePop(),
    embedInTab: widget.inShell,
    navIndex: widget.inShell ? null : 1,
    onNavTap: widget.inShell ? null : (i) => AppRoutes.openTab(context, i),
    body: _DeviceDiagnostics(device: widget.device),
  );
}

class _DeviceList extends StatelessWidget {
  const _DeviceList({required this.repository, required this.onSelect});

  final DeviceRepository repository;
  final ValueChanged<DeviceRecord> onSelect;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        repository,
        MqttSessionManager.instance,
        DevicePresence.instance,
      ]),
      builder: (context, _) {
        final devices = repository.devices;
        return RefreshIndicator(
          onRefresh: repository.refresh,
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Thiết bị', style: AppTextStyles.sectionTitle),
                const SizedBox(height: 4),
                const Text(
                  'Chọn thiết bị để xem lỗi đang hoạt động.',
                  style: AppTextStyles.bodySecondary,
                ),
                if (devices.isEmpty) ...[
                  const SizedBox(height: 12),
                  AppCard(
                    child: Text(
                      repository.isLoading
                          ? 'Đang tải danh sách thiết bị...'
                          : 'Chưa có thiết bị nào được đăng ký.',
                      style: AppTextStyles.bodySecondary,
                    ),
                  ),
                ],
                for (final device in devices) ...[
                  const SizedBox(height: 12),
                  _DeviceRow(device: device, onTap: () => onSelect(device)),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({required this.device, required this.onTap});

  final DeviceRecord device;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (label, kind) = presenceChip(
      connected: MqttSessionManager.instance.isConnected,
      online: DevicePresence.instance.isOnline(device.macAddress),
    );
    return GestureDetector(
      onTap: onTap,
      child: AppCard(
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          device.name,
                          style: AppTextStyles.cardTitle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      StatusChip(label: label, kind: kind),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'device_id: ${device.macAddress}',
                    style: AppTextStyles.monoCaption,
                  ),
                ],
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
    );
  }
}

class _DeviceDiagnostics extends StatelessWidget {
  const _DeviceDiagnostics({required this.device});

  final DeviceRecord device;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: LoadSync.instance.requestStatus,
      child: ListenableBuilder(
        listenable: Listenable.merge([
          DeviceState.instance,
          DevicePresence.instance,
          MqttSessionManager.instance,
          DeveloperAccessController.instance,
        ]),
        builder: (context, _) {
          final state = DeviceState.instance;
          final snapshot = state.deviceId == device.macAddress
              ? state.snapshot
              : null;
          final connected = MqttSessionManager.instance.isConnected;
          final online = DevicePresence.instance.isOnline(device.macAddress);
          final (label, kind) = presenceChip(
            connected: connected,
            online: online,
          );
          return SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ConnectionCard(
                  device: device,
                  chipLabel: label,
                  kind: kind,
                  snapshot: snapshot,
                  netInterface: snapshot?.netInterface ?? state.internetMethod,
                ),
                const SizedBox(height: 20),
                if (snapshot == null)
                  AppCard(
                    child: Text(
                      !connected
                          ? 'App chưa kết nối MQTT nên chưa đọc được chẩn đoán.'
                          : online == false
                          ? 'Thiết bị đang ngoại tuyến. Chẩn đoán sẽ hiện khi thiết bị trực tuyến trở lại.'
                          : 'Đang chờ đồng bộ... Kéo xuống để tải lại.',
                      style: AppTextStyles.bodySecondary,
                    ),
                  )
                else ...[
                  _ErrorsSection(snapshot: snapshot),
                  _HealthLog(deviceId: device.macAddress),
                  _SensorFaults(snapshot: snapshot),
                  if (DeveloperAccessController.instance.hasAccess) ...[
                    _SystemSection(
                      snapshot: snapshot,
                      deviceId: device.macAddress,
                    ),
                    const SizedBox(height: 16),
                    OutlineAppButton(
                      label: 'Xem nhật ký kỹ thuật',
                      onPressed: () => Navigator.of(context).pushNamed(
                        AppRoutes.console,
                        arguments: ConsoleArgs(
                          name: device.name,
                          deviceId: device.macAddress,
                        ),
                      ),
                    ),
                  ],
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value, {this.warn = false});

  final String label;
  final String value;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(label, style: AppTextStyles.bodySecondary)),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: AppTextStyles.bodyMedium.copyWith(
                color: warn ? AppColors.errorText : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({
    required this.device,
    required this.chipLabel,
    required this.kind,
    required this.snapshot,
    required this.netInterface,
  });

  final DeviceRecord device;
  final String chipLabel;
  final StatusKind kind;
  final DeviceSnapshot? snapshot;
  final String? netInterface;

  @override
  Widget build(BuildContext context) {
    final snap = snapshot;
    final at = snap?.receivedAt;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(device.name, style: AppTextStyles.heading)),
              StatusChip(label: chipLabel, kind: kind),
            ],
          ),
          const SizedBox(height: 8),
          _InfoRow('Device Id', device.macAddress),
          _InfoRow('Kết nối mạng', switch (netInterface) {
            'WIFI' => 'Wi-Fi',
            'ETH' => 'Ethernet',
            _ => 'Chưa rõ',
          }),
          _InfoRow(
            'SSID',
            netInterface == 'ETH'
                ? 'Mạng có dây'
                : (snap?.ssid?.isNotEmpty == true ? snap!.ssid! : 'Chưa rõ'),
          ),
          _InfoRow(
            'IP address',
            snap?.ipAddress?.isNotEmpty == true ? snap!.ipAddress! : 'Chưa rõ',
          ),
          if (snap?.bootId != null) _InfoRow('Boot Id', snap!.bootId!),
          if (snap?.uptimeMs != null)
            _InfoRow('Thời gian chạy', formatUptime(snap!.uptimeMs!)),
          if (at != null) _InfoRow('Snapshot gần nhất', _formatTime(at)),
        ],
      ),
    );
  }
}

class _ErrorsSection extends StatelessWidget {
  const _ErrorsSection({required this.snapshot});

  final DeviceSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final mask = snapshot.errorMask;
    final errors = DeviceError.fromMask(mask);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Lỗi đang hoạt động', style: AppTextStyles.sectionTitle),
        const SizedBox(height: 4),
        Text(
          'error_mask = $mask · 0x${mask.toRadixString(16).padLeft(2, '0')} · '
          '${errors.isEmpty ? 'Không có lỗi' : '${errors.length} lỗi'}',
          style: AppTextStyles.bodySecondary,
        ),
        const SizedBox(height: 12),
        if (errors.isEmpty)
          AppCard(
            color: AppColors.successBg,
            borderColor: AppColors.primarySoft,
            child: Text(
              'Thiết bị hoạt động bình thường.',
              style: AppTextStyles.body.copyWith(color: AppColors.textPrimary),
            ),
          )
        else
          for (final error in errors) ...[
            AppCard(
              color: error.severe ? AppColors.errorBg : AppColors.warningBg,
              borderColor: error.severe
                  ? AppColors.errorSoft
                  : const Color(0xFFF3E6B8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${error.bit + 1} · ${error.code}',
                    style: AppTextStyles.bodyMedium.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(error.title, style: AppTextStyles.bodyMedium),
                  const SizedBox(height: 6),
                  Text(
                    'Nguyên nhân: ${error.cause}',
                    style: AppTextStyles.bodySecondary,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Cách xử lý: ${error.advice}',
                    style: AppTextStyles.bodySecondary,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
        const SizedBox(height: 8),
      ],
    );
  }
}

/// Every error, emergency stop and interlock the device reported, newest
/// first, with the time it was noticed. The last 100 are kept.
class _HealthLog extends StatefulWidget {
  const _HealthLog({required this.deviceId});

  final String deviceId;

  @override
  State<_HealthLog> createState() => _HealthLogState();
}

class _HealthLogState extends State<_HealthLog> {
  static const _collapsed = 10;
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: DeviceHealth.instance,
      builder: (context, _) {
        final history = DeviceHealth.instance.history(widget.deviceId);
        final shown = _expanded || history.length <= _collapsed
            ? history
            : history.sublist(0, _collapsed);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Nhật ký', style: AppTextStyles.sectionTitle),
            const SizedBox(height: 4),
            Text(
              '${history.length}/${DeviceHealth.maxEntries} mục gần nhất',
              style: AppTextStyles.bodySecondary,
            ),
            const SizedBox(height: 12),
            if (history.isEmpty)
              const AppCard(
                child: Text(
                  'Chưa ghi nhận lỗi hoặc dừng khẩn cấp nào.',
                  style: AppTextStyles.bodySecondary,
                ),
              )
            else
              AppCard(
                child: Column(
                  children: [
                    for (var i = 0; i < shown.length; i++) ...[
                      if (i > 0)
                        const Divider(height: 20, color: AppColors.divider),
                      _HealthRow(entry: shown[i]),
                    ],
                  ],
                ),
              ),
            if (history.length > _collapsed)
              TextButton(
                onPressed: () => setState(() => _expanded = !_expanded),
                child: Text(
                  _expanded ? 'Thu gọn' : 'Xem tất cả (${history.length} mục)',
                ),
              ),
            const SizedBox(height: 12),
          ],
        );
      },
    );
  }
}

class _HealthRow extends StatelessWidget {
  const _HealthRow({required this.entry});

  final HealthEntry entry;

  @override
  Widget build(BuildContext context) {
    final problem = entry.kind.isProblem;
    final icon = switch (entry.kind) {
      HealthKind.errorRaised => Icons.error_rounded,
      HealthKind.errorCleared => Icons.check_circle_rounded,
      HealthKind.emergency => Icons.report_rounded,
      HealthKind.emergencyCleared => Icons.check_circle_rounded,
      HealthKind.interlock => Icons.lock_rounded,
      HealthKind.interlockCleared => Icons.lock_open_rounded,
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          icon,
          size: 20,
          color: problem ? AppColors.errorText : AppColors.primary,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_formatTime(entry.time), style: AppTextStyles.monoCaption),
              if (entry.code != null)
                Text(
                  entry.code!,
                  style: AppTextStyles.bodyMedium.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              const SizedBox(height: 2),
              Text(entry.message, style: AppTextStyles.bodySecondary),
            ],
          ),
        ),
      ],
    );
  }
}

class _SensorFaults extends StatelessWidget {
  const _SensorFaults({required this.snapshot});

  final DeviceSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final enabled = [
      for (final input in snapshot.inputs)
        if (input.enabled && !PortIds.isReservedLoadSensorName(input.name))
          input,
    ];
    if (enabled.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Cảm biến', style: AppTextStyles.sectionTitle),
        const SizedBox(height: 12),
        AppCard(
          child: Column(
            children: [
              for (final input in enabled)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${input.name} · ${input.portId}',
                          style: AppTextStyles.bodyMedium,
                        ),
                      ),
                      StatusChip(
                        label: input.valid ? 'Đọc được' : 'Đọc lỗi',
                        kind: input.valid ? StatusKind.valid : StatusKind.error,
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 20),
      ],
    );
  }
}

class _SystemSection extends StatelessWidget {
  const _SystemSection({required this.snapshot, required this.deviceId});

  final DeviceSnapshot snapshot;
  final String deviceId;

  static const _lowHeapBytes = 30000;

  String _kb(int? bytes) =>
      bytes == null ? '-' : '${(bytes / 1024).toStringAsFixed(0)} KB';

  String _n(int? value) => value == null ? '-' : '$value';

  @override
  Widget build(BuildContext context) {
    final lowHeap = (snapshot.heapMinFree ?? _lowHeapBytes) < _lowHeapBytes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Hệ thống', style: AppTextStyles.sectionTitle),
        const SizedBox(height: 12),
        _TelemetryIntervalSetting(
          deviceId: deviceId,
          currentInterval: snapshot.telemetryIntervalSeconds,
        ),
        const SizedBox(height: 12),
        AppCard(
          child: Column(
            children: [
              _InfoRow('Heap còn trống', _kb(snapshot.heapFree)),
              _InfoRow(
                'Heap thấp nhất',
                _kb(snapshot.heapMinFree),
                warn: lowHeap,
              ),
              _InfoRow('MQTT kết nối lại', _n(snapshot.mqttReconnects)),
              _InfoRow(
                'Bản tin bị từ chối',
                _n(snapshot.mqttRxRejected),
                warn: (snapshot.mqttRxRejected ?? 0) > 0,
              ),
              _InfoRow(
                'Gửi thất bại',
                _n(snapshot.mqttTxFail),
                warn: (snapshot.mqttTxFail ?? 0) > 0,
              ),
              _InfoRow(
                'Telemetry bị bỏ',
                _n(snapshot.telemetryDropped),
                warn: (snapshot.telemetryDropped ?? 0) > 0,
              ),
            ],
          ),
        ),
        if (lowHeap) ...[
          const SizedBox(height: 8),
          const Text(
            'Heap thấp nhất dưới 30 KB: thiết bị từng gần hết bộ nhớ.',
            style: AppTextStyles.caption,
          ),
        ],
      ],
    );
  }
}

class _TelemetryIntervalSetting extends StatefulWidget {
  const _TelemetryIntervalSetting({
    required this.deviceId,
    required this.currentInterval,
  });

  final String deviceId;
  final int? currentInterval;

  @override
  State<_TelemetryIntervalSetting> createState() =>
      _TelemetryIntervalSettingState();
}

class _TelemetryIntervalSettingState extends State<_TelemetryIntervalSetting> {
  final _controller = TextEditingController();
  bool _saving = false;

  int? get _validInterval {
    final value = _controller.text.trim();
    if (!RegExp(r'^\d+$').hasMatch(value)) return null;
    final seconds = int.tryParse(value);
    return seconds != null && seconds >= 5 && seconds <= 600 ? seconds : null;
  }

  // Kiểm tra xem giá trị nhập vào có trùng với giá trị hiện tại hay không
  bool get _isUnchanged {
    final seconds = _validInterval;
    return seconds != null &&
        widget.currentInterval != null &&
        seconds == widget.currentInterval;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final seconds = _validInterval;
    if (seconds == null || _saving || _isUnchanged) return;
    setState(() => _saving = true);
    try {
      await MqttSessionManager.instance.publishCommandAndWaitForAck(
        widget.deviceId,
        MqttPayloads.setTelemetryInterval(
          cmdId: MqttPayloads.newCommandId(),
          intervalSeconds: seconds,
        ),
      );
      _controller.clear();
      unawaited(LoadSync.instance.requestStatus());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Đã lưu tần suất gửi telemetry.')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              userErrorText('Không lưu được tần suất telemetry', error),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final interval = _validInterval;
    final raw = _controller.text.trim();
    final invalid = raw.isNotEmpty && interval == null;

    // Điều kiện cho phép bấm lưu: hợp lệ, không trùng giá trị cũ và không trong trạng thái đang lưu
    final bool canSave = interval != null && !_isUnchanged && !_saving;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Tần suất gửi telemetry', style: AppTextStyles.cardTitle),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: AppTextField(
                  label: 'Chu kỳ mới (giây)',
                  controller: _controller,
                  keyboardType: TextInputType.number,
                  hint: widget.currentInterval?.toString() ?? 'Chưa rõ',
                  enabled: !_saving,
                  errorText: invalid ? 'Nhập số nguyên từ 5 đến 600.' : null,
                  helper: 'Từ 5 giây đến 10 phút.',
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 10),
              Padding(
                padding: const EdgeInsets.only(top: 30),
                child: FilledButton(
                  onPressed: canSave ? _save : null,
                  child: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Lưu'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

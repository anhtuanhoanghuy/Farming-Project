import 'dart:async';
import 'dart:convert';

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
import '../state/developer_access_controller.dart';
import '../state/device_state.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../widgets/app_buttons.dart';
import '../widgets/app_card.dart';
import '../widgets/app_choice_buttons.dart';
import '../widgets/app_more_menu.dart';
import '../widgets/app_text_field.dart';
import '../widgets/screen_scaffold.dart';

class SensorConfigScreen extends StatefulWidget {
  const SensorConfigScreen({
    super.key,
    required this.selection,
    this.inShell = true,
  });

  final SensorConfigSelection selection;
  final bool inShell;

  @override
  State<SensorConfigScreen> createState() => _SensorConfigScreenState();
}

class _SensorConfigScreenState extends State<SensorConfigScreen> {
  late String _type = widget.selection.interfaceType;
  late String _portId = widget.selection.portId;
  late bool _enabled = widget.selection.enabled;
  bool _saving = false;
  late final _slave = TextEditingController(
    text:
        widget.selection.slaveId?.toString() ??
        (_isRs485Type(widget.selection.interfaceType)
            ? _defaultSlaveId(widget.selection.portId).toString()
            : '1'),
  );
  late final _name = TextEditingController(text: widget.selection.name);

  /// A sensor already on its port keeps its type and port; only a new one
  /// can choose them.
  late final bool _typeLocked = _savedInput(_portId) != null;

  @override
  void dispose() {
    _slave.dispose();
    _name.dispose();
    super.dispose();
  }

  static bool _isRs485Type(String type) => type == PortIds.rs485Type;

  static int _defaultSlaveId(String portId) {
    final suffix = RegExp(r'\d+$').firstMatch(portId)?.group(0);
    final portNumber = int.tryParse(suffix ?? '') ?? 1;
    return 100 + portNumber;
  }

  bool get _isRs485 => _isRs485Type(_type);

  /// The sensor the ESP32 holds on [portId] (from its latest snapshot).
  SensorInput? _savedInput(String portId) =>
      DeviceState.instance.snapshot?.input(portId);

  List<String> _freePorts(String type) =>
      DeviceState.instance.snapshot?.freePortsFor(type) ??
      PortIds.defaultPorts(type);

  /// Ports offered in the dropdown: the sensor's own port when it is saved,
  /// otherwise the ports without a sensor.
  List<String> get _portOptions {
    if (_typeLocked) return [_portId];
    final free = _freePorts(_type);
    return free.contains(_portId) ? free : [_portId, ...free];
  }

  void _selectType(String type) {
    if (type == _type || _typeLocked) return;
    final free = _freePorts(type);
    if (free.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Loại này không còn cổng trống.')),
      );
      return;
    }
    setState(() {
      _type = type;
      _portId = free.first;
      if (_isRs485Type(type)) {
        _slave.text = _defaultSlaveId(_portId).toString();
      }
    });
  }

  /// Sends [payload] after the screen is already gone. When the ESP32 refuses
  /// or stays silent for 5 s the failure is shown on the app-level messenger
  /// and the real state is requested.
  void _sendDetached(
    String deviceId,
    Map<String, Object?> payload,
    String failure, {
    VoidCallback? onAcked,
    VoidCallback? onFailed,
  }) {
    unawaited(() async {
      try {
        await MqttSessionManager.instance.publishCommandAndWaitForAck(
          deviceId,
          payload,
        );
        onAcked?.call();
      } catch (error) {
        onFailed?.call();
        appMessengerKey.currentState?.showSnackBar(
          SnackBar(content: Text(userErrorText(failure, error))),
        );
        unawaited(LoadSync.instance.requestStatus());
      }
    }());
  }

  /// Adds the sensor when its port has none, modifies it otherwise. The screen
  /// closes only after the device acknowledges the configuration.
  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    var commandSent = false;
    try {
      final name = _name.text.trim();
      if (name.isEmpty) {
        throw const FormatException('Tên cảm biến không được để trống.');
      }
      if (utf8.encode(name).length > 31) {
        throw const FormatException('Tên cảm biến tối đa 31 byte UTF-8.');
      }
      final saved = _savedInput(_portId);
      final int? slaveId;
      if (_isRs485) {
        slaveId = int.tryParse(_slave.text.trim());
        if (slaveId == null || slaveId < 1 || slaveId > 247) {
          throw const FormatException(
            'Địa chỉ Modbus phải là số nguyên từ 1 đến 247.',
          );
        }
      } else {
        slaveId = null;
      }
      final payload = MqttPayloads.sensorConfig(
        cmdId: MqttPayloads.newCommandId(),
        add: saved == null,
        enabled: _enabled,
        sensorId: _portId,
        name: name,
        slaveId: slaveId,
      );
      commandSent = true;
      await MqttSessionManager.instance.publishCommandAndWaitForAck(
        widget.selection.device.deviceId,
        payload,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            userErrorText('Không lưu được cấu hình cảm biến', error),
          ),
        ),
      );
      if (commandSent) unawaited(LoadSync.instance.requestStatus());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Xóa cảm biến', style: AppTextStyles.sectionTitle),
        content: Text(
          'Bạn có chắc chắn muốn xóa cảm biến "${_savedInput(_portId)?.name ?? _name.text}"?',
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
    final navigator = Navigator.of(context);
    final port = _portId;
    DeviceState.instance.hideSensor(port);
    _sendDetached(
      widget.selection.device.deviceId,
      MqttPayloads.deleteSensor(
        cmdId: MqttPayloads.newCommandId(),
        sensorId: port,
      ),
      'Không xóa được cảm biến',
      onAcked: () => DeviceState.instance.confirmSensorHidden(port),
      onFailed: () => DeviceState.instance.restoreSensor(port),
    );
    navigator.maybePop(true);
  }

  /// "Cho phép cảm biến": a saved sensor is switched at once with
  /// TOGGLE_SENSOR_CAPABILITY; a new one only takes the value into its
  /// SENSOR_CONFIG. The switch moves immediately and goes back when the ESP32
  /// refuses or does not answer within 5 s.
  Future<void> _setEnabled(bool enabled) async {
    if (!_typeLocked) {
      setState(() => _enabled = enabled);
      return;
    }
    final previous = _enabled;
    setState(() => _enabled = enabled);
    try {
      await MqttSessionManager.instance.publishCommandAndWaitForAck(
        widget.selection.device.deviceId,
        MqttPayloads.toggleSensorCapability(
          cmdId: MqttPayloads.newCommandId(),
          sensorId: _portId,
          enabled: enabled,
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _enabled = previous);
      appMessengerKey.currentState?.showSnackBar(
        SnackBar(
          content: Text(
            userErrorText('Không đổi được trạng thái cảm biến', error),
          ),
        ),
      );
      unawaited(LoadSync.instance.requestStatus());
    }
  }

  InputDecoration get _dropdownDecoration => InputDecoration(
    filled: true,
    fillColor: AppColors.surface,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: AppColors.border),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: AppColors.border),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: DeviceState.instance,
      builder: (context, _) => ScreenScaffold(
        title: 'Cấu hình cảm biến',
        showBack: true,
        embedInTab: widget.inShell,
        navIndex: widget.inShell ? null : 0,
        onNavTap: widget.inShell ? null : (i) => AppRoutes.openTab(context, i),
        headerTrailing: !_typeLocked
            ? null
            : AppMoreMenu<String>(
                onSelected: (_) => _confirmDelete(),
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: 'delete',
                    child: Row(
                      children: [
                        Icon(
                          Icons.delete_outline,
                          color: AppColors.errorText,
                          size: 20,
                        ),
                        SizedBox(width: 8),
                        Text(
                          'Xóa cảm biến',
                          style: TextStyle(color: AppColors.errorText),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppCard(
                child: SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Cho phép cảm biến'),
                  value: _enabled,
                  onChanged: _setEnabled,
                ),
              ),
              const SizedBox(height: 18),
              const Text('Loại cảm biến', style: AppTextStyles.label),
              const SizedBox(height: 10),
              AppChoiceButtons<String>(
                options: const [
                  (PortIds.rs485Type, 'RS485'),
                  (PortIds.analogType, 'Current'),
                  (PortIds.diType, 'DI'),
                ],
                selected: _type,
                onChanged: _typeLocked ? null : _selectType,
              ),
              if (_typeLocked)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text(
                    'Không đổi được loại của cảm biến đã lưu; hãy xóa rồi thêm lại.',
                    style: AppTextStyles.caption,
                  ),
                ),
              const SizedBox(height: 18),
              const Text('Cổng', style: AppTextStyles.label),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                key: ValueKey('port-$_type-$_portId-${_portOptions.length}'),
                initialValue: _portId,
                decoration: _dropdownDecoration,
                items: [
                  for (final port in _portOptions)
                    DropdownMenuItem<String>(value: port, child: Text(port)),
                ],
                onChanged: _typeLocked
                    ? null
                    : (port) {
                        if (port == null) return;
                        setState(() {
                          _portId = port;
                          if (_isRs485) {
                            _slave.text = _defaultSlaveId(port).toString();
                          }
                        });
                      },
              ),
              const SizedBox(height: 18),
              AppTextField(
                label: 'Tên cảm biến',
                controller: _name,
                helper: 'Tối đa 31 kí tự.',
              ),
              ListenableBuilder(
                listenable: DeveloperAccessController.instance,
                builder: (context, _) {
                  if (!DeveloperAccessController.instance.hasAccess ||
                      !_isRs485) {
                    return const SizedBox.shrink();
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 16),
                      AppTextField(
                        label: 'Địa chỉ Modbus',
                        controller: _slave,
                        keyboardType: TextInputType.number,
                        helper: _typeLocked
                            ? 'Lưu sẽ đổi ID từ địa chỉ hiện tại (phải duy nhất trên bus). ID mới: 1–247.'
                            : 'ID mặc định theo cổng: ${_defaultSlaveId(_portId)}. Cảm biến mới được giả định đang ở ID 1; hãy cô lập khi đổi ID.',
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 20),
              PrimaryButton(
                label: _saving ? 'Đang chờ thiết bị xác nhận...' : 'Lưu',
                icon: _saving ? Icons.sync : Icons.send_rounded,
                enabled: !_saving,
                onPressed: _saving ? null : _save,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

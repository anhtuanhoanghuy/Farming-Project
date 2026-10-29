import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../protocol/device_snapshot.dart';
import '../protocol/device_telemetry.dart';
import '../protocol/mqtt_payloads.dart';
import '../protocol/mqtt_topics.dart';
import '../protocol/port_ids.dart';
import '../state/device_presence.dart';
import '../state/device_state.dart';
import '../state/load_controller.dart';
import 'mqtt_session_manager.dart';

/// Keeps [DeviceState] and the [LoadController]s equal to what the ESP32 of
/// the open device reports.
///
/// The retained `SNAPSHOT` (and the one the ESP32 publishes after every
/// successful command) is the source of truth for configuration, relay state
/// and the delay timers; `EVENT`s update the relay state at once; `telemetry`
/// carries the sensor values. `GET_STATUS` and `GET_TELEMETRY` are sent when the device is opened,
/// when MQTT reconnects, when the device comes back online, when the app
/// resumes and when a local delay countdown reaches zero.
class LoadSync {
  LoadSync({
    Stream<MqttDeviceMessage>? messages,
    Future<void> Function(String deviceId, Map<String, Object?> payload)?
    publish,
    bool Function()? isConnected,
    Listenable? connection,
    List<LoadController>? loads,
    DeviceState? state,
    DevicePresence? presence,
    MqttDeviceMessage? Function(String deviceId)? latestSnapshot,
    this.statusRetryDelay = const Duration(seconds: 2),
  }) : _messages = messages ?? MqttSessionManager.instance.messages,
       _publish = publish ?? MqttSessionManager.instance.publishCommand,
       _isConnected =
           isConnected ?? (() => MqttSessionManager.instance.isConnected),
       _connection = connection ?? MqttSessionManager.instance,
       _state = state ?? DeviceState.instance,
       _presence = presence ?? DevicePresence.instance,
       _latestSnapshot =
           latestSnapshot ?? MqttSessionManager.instance.latestSnapshot,
       _loads = loads ?? LoadController.loads;

  static final instance = LoadSync();

  final Stream<MqttDeviceMessage> _messages;
  final Future<void> Function(String, Map<String, Object?>) _publish;
  final bool Function() _isConnected;
  final Listenable _connection;
  final DeviceState _state;
  final DevicePresence _presence;
  final MqttDeviceMessage? Function(String) _latestSnapshot;
  final List<LoadController> _loads;
  final Duration statusRetryDelay;

  String? _deviceId;
  StreamSubscription<MqttDeviceMessage>? _subscription;
  bool _wasConnected = false;
  bool? _lastOnline;

  String? get deviceId => _deviceId;

  /// Starts mirroring [deviceId]: show the snapshot the app already holds,
  /// then ask the ESP32 for a fresh one. Until a snapshot is known the relay
  /// state is unknown.
  Future<void> attach(String deviceId) async {
    detach();
    for (final load in _loads) {
      load.cancelDelay();
      load.markUnknown();
    }
    _deviceId = deviceId;
    _state.reset(deviceId);
    _lastOnline = _presence.isOnline(deviceId);
    LoadController.onDelayElapsed = _onElapsed;
    _subscription = _messages.listen(handleMessage);
    _wasConnected = _isConnected();
    _connection.addListener(_onConnectionChanged);
    _presence
      ..start()
      ..addListener(_onPresenceChanged);
    final cached = _latestSnapshot(deviceId);
    if (cached != null) handleMessage(cached);
    await requestStatus();
    await requestTelemetry();
  }

  void detach() {
    _subscription?.cancel();
    _subscription = null;
    _connection.removeListener(_onConnectionChanged);
    _presence.removeListener(_onPresenceChanged);
    if (LoadController.onDelayElapsed == _onElapsed) {
      LoadController.onDelayElapsed = null;
    }
    _deviceId = null;
  }

  Future<void> requestStatus() async {
    final deviceId = _deviceId;
    if (deviceId == null) return;
    if (!_isConnected()) {
      _log('MQTT chưa kết nối → chờ kết nối lại để đọc snapshot.');
      return;
    }
    try {
      await _publish(
        deviceId,
        MqttPayloads.getStatus(cmdId: MqttPayloads.newCommandId()),
      );
    } catch (error) {
      _log('Không gửi được GET_STATUS: $error');
    }
  }

  Future<void> requestTelemetry() async {
    final deviceId = _deviceId;
    if (deviceId == null) return;
    if (!_isConnected()) {
      _log('MQTT chưa kết nối → chưa thể yêu cầu telemetry.');
      return;
    }
    try {
      await _publish(
        deviceId,
        MqttPayloads.getTelemetry(cmdId: MqttPayloads.newCommandId()),
      );
    } catch (error) {
      _log('Không gửi được GET_TELEMETRY: $error');
    }
  }

  void _onConnectionChanged() {
    final connected = _isConnected();
    if (connected && !_wasConnected) {
      _log('MQTT vừa kết nối lại → đọc lại snapshot.');
      unawaited(requestStatus());
      unawaited(requestTelemetry());
    } else if (!connected && _wasConnected) {
      _log('Mất kết nối MQTT → trạng thái tải và giá trị cảm biến chưa rõ.');
      _forgetLive();
    }
    _wasConnected = connected;
  }

  void _onPresenceChanged() {
    final deviceId = _deviceId;
    if (deviceId == null) return;
    final online = _presence.isOnline(deviceId);
    final wasOffline = _lastOnline == false;
    if (online == _lastOnline) return;
    _lastOnline = online;
    if (online == false) {
      _log(
        'Thiết bị ngoại tuyến (LWT) → trạng thái tải và giá trị cảm biến chưa rõ.',
      );
      _forgetLive();
    } else if (online == true && wasOffline) {
      _log('Thiết bị trực tuyến trở lại → đọc lại snapshot.');
      unawaited(requestStatus());
      unawaited(requestTelemetry());
    }
  }

  /// Nothing read earlier may be shown as current once the device or the
  /// connection is gone.
  void _forgetLive() {
    _state.clearLive();
    for (final load in _loads) {
      load.cancelDelay();
      load.markUnknown();
    }
  }

  void _onElapsed(LoadController load) {
    _log(
      'Tải ${load.id}: đếm ngược local về 0 → đọc snapshot mới từ Thiết bị.',
    );
    Timer(statusRetryDelay, () => unawaited(requestStatus()));
  }

  // -------------------------------------------------------------- messages

  void handleMessage(MqttDeviceMessage message) {
    if (message.deviceId != _deviceId) return;
    final isStatus = message.kind == MqttDeviceTopicKind.status;
    final isTelemetry = message.kind == MqttDeviceTopicKind.telemetry;
    if (!isStatus && !isTelemetry) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(message.payload);
    } on FormatException {
      return;
    }
    if (decoded is! Map) return;
    if (isTelemetry) {
      _applyTelemetry(decoded, message.receivedAt);
      return;
    }
    switch (decoded['type']) {
      case 'SNAPSHOT':
        _applySnapshot(decoded, message.receivedAt);
      case 'EVENT':
        _applyEvent(decoded);
    }
  }

  void _applyTelemetry(Map<dynamic, dynamic> json, DateTime at) {
    final telemetry = DeviceTelemetry.tryParse(json, at);
    // A buffered reading is old data the ESP32 stored while offline.
    if (telemetry == null || telemetry.buffered) return;
    _state.applyTelemetry(telemetry);
    for (final input in telemetry.inputs) {
      final loadId = PortIds.loadFeedbackLoadId(input.name);
      final value = input.values.firstOrNull?.value;
      if (loadId == null || !input.valid || value is! bool) continue;
      final load = _loads.where((item) => item.portId == loadId).firstOrNull;
      load?.setOnFromDevice(value);
    }
  }

  LoadController? _controller(Object? loadId) =>
      _loads.where((load) => load.portId == loadId).firstOrNull;

  void _applySnapshot(Map<dynamic, dynamic> json, DateTime receivedAt) {
    final snapshot = DeviceSnapshot.tryParse(json, receivedAt);
    if (snapshot == null) return;
    _state.applySnapshot(snapshot);
    for (final item in snapshot.loads) {
      _controller(item.loadId)?.applySnapshot(item, receivedAt);
    }
  }

  void _applyEvent(Map<dynamic, dynamic> event) {
    switch (event['event']) {
      case 'LOAD_CHANGED':
        final state = event['state'];
        if (state is bool) {
          _controller(event['load_id'])?.setOnFromDevice(state);
        }
      case 'EMERGENCY_STOP':
        for (final load in _loads) {
          load.cancelDelay();
          load.setOn(false);
        }
    }
  }

  void _log(String message) => debugPrint('[LoadSync] $message');
}

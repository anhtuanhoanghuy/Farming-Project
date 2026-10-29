import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../protocol/device_snapshot.dart';
import '../protocol/device_telemetry.dart';
import '../protocol/mqtt_payloads.dart';
import '../protocol/mqtt_topics.dart';
import '../services/mqtt_session_manager.dart';

/// Tracks device presence using MQTT status snapshots, telemetry, and LWT.
class DevicePresence extends ChangeNotifier {
  DevicePresence({
    Stream<MqttDeviceMessage>? messages,
    Listenable? connection,
    bool Function()? isConnected,
    Future<void> Function(String, Map<String, Object?>)? publishCommand,
    Set<String> Function()? deviceIds,
    this.statusPollInterval = const Duration(seconds: 15),
    @visibleForTesting Duration? presenceSilenceTimeout,
  }) : _messages = messages,
       _connection = connection,
       _isConnected = isConnected,
       _publishCommand =
           publishCommand ?? MqttSessionManager.instance.publishCommand,
       _deviceIds = deviceIds ?? (() => MqttSessionManager.instance.deviceIds),
       _presenceSilenceTimeout = presenceSilenceTimeout;

  static final instance = DevicePresence();

  static const presenceSilenceTimeoutDefault = Duration(seconds: 15);

  final Stream<MqttDeviceMessage>? _messages;
  final Listenable? _connection;
  final bool Function()? _isConnected;
  final Future<void> Function(String, Map<String, Object?>) _publishCommand;
  final Set<String> Function() _deviceIds;
  final Duration? _presenceSilenceTimeout;
  final Duration statusPollInterval;

  final _online = <String, bool>{};
  final _presenceTimers = <String, Timer>{};
  StreamSubscription<MqttDeviceMessage>? _subscription;
  Timer? _statusPollTimer;
  Listenable? _listenedConnection;
  bool _started = false;
  bool _wasConnected = false;

  /// True/false as reported by the device; null when not known.
  bool? isOnline(String deviceId) => _online[deviceId];

  /// Starts listening; safe to call many times.
  void start() {
    if (_started) return;
    _started = true;
    final manager = MqttSessionManager.instance;
    final connected = _isConnected ?? (() => manager.isConnected);
    _wasConnected = connected();
    _subscription = (_messages ?? manager.messages).listen(_onMessage);
    _listenedConnection = _connection ?? manager;
    _listenedConnection!.addListener(_onConnectionChanged);
    if (_wasConnected) _startStatusPolling();
  }

  void _onConnectionChanged() {
    final connected =
        (_isConnected ?? (() => MqttSessionManager.instance.isConnected))();
    if (!connected && _wasConnected) {
      _statusPollTimer?.cancel();
      _statusPollTimer = null;
      _online.clear();
      for (final timer in _presenceTimers.values) {
        timer.cancel();
      }
      _presenceTimers.clear();
      notifyListeners();
    } else if (connected && !_wasConnected) {
      _startStatusPolling();
    }
    _wasConnected = connected;
  }

  void _startStatusPolling() {
    _statusPollTimer?.cancel();
    unawaited(_requestStatuses());
    _statusPollTimer = Timer.periodic(statusPollInterval, (_) {
      unawaited(_requestStatuses());
    });
  }

  Future<void> _requestStatuses() async {
    if (!(_isConnected ?? (() => MqttSessionManager.instance.isConnected))()) {
      return;
    }
    for (final deviceId in _deviceIds()) {
      try {
        await _publishCommand(
          deviceId,
          MqttPayloads.getStatus(cmdId: MqttPayloads.newCommandId()),
        );
      } catch (error) {
        debugPrint('[DevicePresence] GET_STATUS failed for $deviceId: $error');
      }
    }
  }

  @visibleForTesting
  void handleMessage(MqttDeviceMessage message) => _onMessage(message);

  void _onMessage(MqttDeviceMessage message) {
    if (message.kind == MqttDeviceTopicKind.telemetry) {
      _onTelemetry(message);
      return;
    }
    if (message.kind != MqttDeviceTopicKind.status) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(message.payload);
    } on FormatException {
      return;
    }
    if (decoded is! Map) return;
    switch (decoded['type']) {
      case 'SNAPSHOT':
        if (DeviceSnapshot.tryParse(decoded, message.receivedAt) != null) {
          _markOnline(message.deviceId);
        }
        return;
      case 'LWT':
        if (decoded['state'] != 'offline') return;
        _presenceTimers.remove(message.deviceId)?.cancel();
        if (_online[message.deviceId] == false) return;
        _online[message.deviceId] = false;
        notifyListeners();
        return;
      default:
        return;
    }
  }

  void _markOnline(String deviceId) {
    final wasOnline = _online[deviceId] == true;
    _online[deviceId] = true;
    _presenceTimers.remove(deviceId)?.cancel();
    _presenceTimers[deviceId] = Timer(
      _presenceSilenceTimeout ?? presenceSilenceTimeoutDefault,
      () {
        _presenceTimers.remove(deviceId);
        if (_online[deviceId] == true) {
          _online.remove(deviceId);
          notifyListeners();
        }
      },
    );
    if (!wasOnline) notifyListeners();
  }

  void _onTelemetry(MqttDeviceMessage message) {
    final Object? decoded;
    try {
      decoded = jsonDecode(message.payload);
    } on FormatException {
      return;
    }
    if (decoded is! Map ||
        DeviceTelemetry.tryParse(decoded, message.receivedAt) == null) {
      return;
    }

    _markOnline(message.deviceId);
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _listenedConnection?.removeListener(_onConnectionChanged);
    _statusPollTimer?.cancel();
    for (final timer in _presenceTimers.values) {
      timer.cancel();
    }
    _presenceTimers.clear();
    super.dispose();
  }
}

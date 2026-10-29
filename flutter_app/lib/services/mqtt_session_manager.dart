import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_config.dart';
import '../protocol/mqtt_ack.dart';
import '../protocol/mqtt_log.dart';
import '../protocol/mqtt_topics.dart';
import 'traffic_log.dart';

enum MqttSessionStatus {
  idle,
  notConfigured,
  connecting,
  connected,
  reconnecting,
  disconnected,
  error,
}

class MqttDeviceMessage {
  const MqttDeviceMessage({
    required this.deviceId,
    required this.topic,
    required this.kind,
    required this.payload,
    required this.receivedAt,
  });

  final String deviceId;
  final String topic;
  final MqttDeviceTopicKind kind;
  final String payload;
  final DateTime receivedAt;
}

typedef MqttTestPublisher =
    Future<void> Function(String deviceId, Map<String, Object?> payload);

class MqttSessionManager extends ChangeNotifier {
  MqttSessionManager._({MqttTestPublisher? testPublisher})
    : _testPublisher = testPublisher;

  /// A manager with no broker: commands go to [publisher] and incoming
  /// messages are fed through [dispatch].
  @visibleForTesting
  MqttSessionManager.test({
    required Set<String> devices,
    required MqttTestPublisher publisher,
  }) : _testPublisher = publisher,
       _status = MqttSessionStatus.connected {
    _deviceIds.addAll(devices);
  }

  static final instance = MqttSessionManager._();

  static const _clientIdPreferenceKey = 'mqtt.client_id';
  static const _devicePreferencePrefix = 'mqtt.devices.';
  static const _deviceNamePreferencePrefix = 'mqtt.device_name.';

  final MqttTestPublisher? _testPublisher;
  final _messages = StreamController<MqttDeviceMessage>.broadcast();
  final Set<String> _deviceIds = {};
  final Map<String, String> _deviceNames = {};
  final Set<String> _subscribedTopics = {};
  final Map<String, Completer<MqttAck>> _pendingAcks = {};
  final Map<String, MqttDeviceMessage> _latestSnapshots = {};

  MqttServerClient? _client;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _updates;
  String? _userId;
  String? _lastError;
  MqttSessionStatus _status = MqttSessionStatus.idle;
  int _generation = 0;

  Stream<MqttDeviceMessage> get messages => _messages.stream;
  Set<String> get deviceIds => Set.unmodifiable(_deviceIds);
  String? get userId => _userId;
  String? get lastError => _lastError;
  MqttSessionStatus get status => _status;
  bool get isConnected => _status == MqttSessionStatus.connected;
  String deviceName(String deviceId) => _deviceNames[deviceId] ?? deviceId;

  Future<void> startForUser(String userId) async {
    final normalizedUserId = userId.trim();
    if (normalizedUserId.isEmpty) {
      throw ArgumentError.value(userId, 'userId', 'Must not be empty');
    }
    if (_userId == normalizedUserId &&
        (_status == MqttSessionStatus.connecting ||
            _status == MqttSessionStatus.connected ||
            _status == MqttSessionStatus.reconnecting)) {
      return;
    }

    final generation = ++_generation;
    await _disconnectClient();
    if (generation != _generation) return;
    _userId = normalizedUserId;
    _deviceIds.clear();
    _deviceNames.clear();
    _setStatus(MqttSessionStatus.connecting);
    try {
      final preferences = await SharedPreferences.getInstance();
      if (generation != _generation) return;
      _deviceIds.addAll(
        preferences.getStringList(_devicePreferenceKey(normalizedUserId)) ?? [],
      );
      for (final deviceId in _deviceIds) {
        final name = preferences.getString(
          _deviceNamePreferenceKey(normalizedUserId, deviceId),
        );
        if (name != null && name.isNotEmpty) _deviceNames[deviceId] = name;
      }

      if (!AppConfig.isMqttConfigured) {
        _setStatus(
          MqttSessionStatus.notConfigured,
          error: 'Thiếu MQTT_HOST trong cấu hình ứng dụng.',
        );
        return;
      }

      final clientId = await _loadOrCreateClientId(preferences);
      if (generation != _generation) return;
      final client = MqttServerClient.withPort(
        AppConfig.mqttHost.trim(),
        clientId,
        AppConfig.mqttPort,
      );
      client
        ..secure = AppConfig.mqttTls
        ..autoReconnect = true
        ..resubscribeOnAutoReconnect = true
        ..keepAlivePeriod = 30
        ..connectTimeoutPeriod = 10000
        ..logging(on: false);
      client.onConnected = () => _onConnected(generation);
      client.onDisconnected = () => _onDisconnected(generation);
      client.onAutoReconnect = () => _onAutoReconnect(generation);
      client.onAutoReconnected = () => _onAutoReconnected(generation);
      client.connectionMessage = MqttConnectMessage()
          .withClientIdentifier(clientId)
          .startClean();
      _client = client;

      final username = AppConfig.mqttUsername;
      final password = AppConfig.mqttPassword;
      final result = await client.connect(
        username.isEmpty ? null : username,
        password.isEmpty ? null : password,
      );
      if (generation != _generation) {
        client.disconnect();
        return;
      }
      if (result?.state != MqttConnectionState.connected) {
        final reason = result?.returnCode?.name ?? 'unknown';
        throw StateError('Broker từ chối kết nối ($reason).');
      }
      _listenForUpdates(client, generation);
      _setStatus(MqttSessionStatus.connected);
      _subscribeKnownDevices();
    } catch (error) {
      if (generation != _generation) return;
      await _disconnectClient();
      _setStatus(
        MqttSessionStatus.error,
        error: 'Không khởi tạo/kết nối được MQTT broker: $error',
      );
    }
  }

  Future<void> addDevice(String deviceId, {String? name}) async {
    final id = deviceId.trim();
    if (id.isEmpty) {
      throw ArgumentError.value(deviceId, 'deviceId', 'Must not be empty');
    }
    final userId = _userId;
    if (userId == null) {
      throw StateError('Chưa khởi tạo phiên MQTT cho người dùng.');
    }
    MqttDeviceTopics.forDevice(userId: userId, deviceId: id);
    final preferences = await SharedPreferences.getInstance();
    final isNewDevice = _deviceIds.add(id);
    if (isNewDevice) {
      await preferences.setStringList(
        _devicePreferenceKey(userId),
        _deviceIds.toList()..sort(),
      );
    }
    final normalizedName = name?.trim();
    if (normalizedName != null && normalizedName.isNotEmpty) {
      _deviceNames[id] = normalizedName;
      await preferences.setString(
        _deviceNamePreferenceKey(userId, id),
        normalizedName,
      );
    }
    if (isConnected && isNewDevice) _subscribeDevice(id);
    notifyListeners();
  }

  Future<void> removeDevice(String deviceId) async {
    final userId = _userId;
    if (userId == null || !_deviceIds.remove(deviceId)) return;
    _deviceNames.remove(deviceId);
    final topics = MqttDeviceTopics.forDevice(
      userId: userId,
      deviceId: deviceId,
    );
    final client = _client;
    _latestSnapshots.remove(deviceId);
    for (final topic in topics.subscriptions) {
      if (_subscribedTopics.remove(topic) &&
          client?.connectionStatus?.state == MqttConnectionState.connected) {
        client!.unsubscribe(topic);
      }
    }
    final preferences = await SharedPreferences.getInstance();
    await preferences.setStringList(
      _devicePreferenceKey(userId),
      _deviceIds.toList()..sort(),
    );
    await preferences.remove(_deviceNamePreferenceKey(userId, deviceId));
    notifyListeners();
  }

  /// Publishes [payload] on `commands` without waiting for the ACK.
  Future<void> publishCommand(String deviceId, Map<String, Object?> payload) =>
      _publish(deviceId, payload);

  /// Publishes [payload] on `commands` and waits for the ESP32's ACK with the
  /// same `cmd_id`. Returns the ACK when its result is `ok`; throws
  /// [MqttCommandException] when the ESP32 refuses the command (with `code`
  /// and `reason`), does not answer within [timeout], or the broker is not
  /// connected.
  Future<MqttAck> publishCommandAndWaitForAck(
    String deviceId,
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final cmdId = payload['cmd_id'];
    if (cmdId is! String || cmdId.isEmpty) {
      throw ArgumentError.value(payload['cmd_id'], 'cmd_id');
    }
    final completer = Completer<MqttAck>();
    _pendingAcks[cmdId] = completer;
    try {
      await _publish(deviceId, payload);
      final ack = await completer.future.timeout(
        timeout,
        onTimeout: () => throw MqttCommandException(
          'Thiết bị không phản hồi lệnh '
          'trong ${timeout.inSeconds} giây.',
        ),
      );
      if (!ack.isSuccess) throw MqttCommandException.rejected(ack);
      return ack;
    } finally {
      _pendingAcks.remove(cmdId);
    }
  }

  /// The newest `SNAPSHOT` received for [deviceId] (the retained one when the
  /// app connected); null after the device's LWT or before any snapshot.
  MqttDeviceMessage? latestSnapshot(String deviceId) =>
      _latestSnapshots[deviceId];

  /// Feeds a received message through the same path as the broker traffic.
  @visibleForTesting
  void dispatch(MqttDeviceMessage message) => _dispatch(message);

  void _dispatch(MqttDeviceMessage message) {
    debugPrint(MqttLog.rx(message.deviceId, message.kind, message.payload));
    TrafficLog.instance.addRx(
      message.deviceId,
      message.topic,
      message.kind,
      message.payload,
    );
    final Object? decoded;
    try {
      decoded = jsonDecode(message.payload);
    } on FormatException {
      return;
    }
    if (decoded is Map) {
      if (message.kind == MqttDeviceTopicKind.status) {
        switch (decoded['type']) {
          case 'SNAPSHOT':
            _latestSnapshots[message.deviceId] = message;
          case 'LWT':
            _latestSnapshots.remove(message.deviceId);
        }
      } else if (message.kind == MqttDeviceTopicKind.ack) {
        _completeAck(decoded);
      }
    }
    _messages.add(message);
  }

  void _completeAck(Map<dynamic, dynamic> json) {
    final completer = _pendingAcks[json['cmd_id']];
    if (completer == null || completer.isCompleted) return;
    try {
      completer.complete(MqttAck.fromJson(Map<String, Object?>.from(json)));
    } on FormatException catch (error, stackTrace) {
      completer.completeError(error, stackTrace);
    }
  }

  /// The bytes of a command. `addString` would turn every character above
  /// U+00FF into garbage, so Vietnamese names would be refused by the ESP32;
  /// the payload must be UTF-8.
  @visibleForTesting
  static MqttClientPayloadBuilder jsonPayload(String json) =>
      MqttClientPayloadBuilder()..addUTF8String(json);

  Future<void> _publish(String deviceId, Map<String, Object?> payload) async {
    final testPublisher = _testPublisher;
    if (testPublisher != null) {
      debugPrint(MqttLog.tx(payload));
      TrafficLog.instance.addTx(deviceId, 'commands', payload);
      return testPublisher(deviceId, payload);
    }
    final client = _client;
    final userId = _userId;
    if (client == null ||
        userId == null ||
        client.connectionStatus?.state != MqttConnectionState.connected) {
      throw const MqttCommandException('MQTT broker chưa kết nối.');
    }
    if (!_deviceIds.contains(deviceId)) {
      throw const MqttCommandException(
        'Thiết bị chưa được đăng ký trong phiên MQTT.',
      );
    }
    final topic = MqttDeviceTopics.forDevice(
      userId: userId,
      deviceId: deviceId,
    ).commands;
    final json = jsonEncode(payload);
    final builder = jsonPayload(json);
    final messageId = client.publishMessage(
      topic,
      MqttQos.atLeastOnce,
      builder.payload!,
    );
    if (messageId <= 0) {
      throw const MqttCommandException('MQTT không chấp nhận bản tin gửi đi.');
    }
    debugPrint(MqttLog.tx(payload));
    TrafficLog.instance.addTx(deviceId, topic, payload);
  }

  Future<void> stop() async {
    _generation++;
    await _disconnectClient();
    _userId = null;
    _deviceIds.clear();
    _deviceNames.clear();
    _setStatus(MqttSessionStatus.disconnected);
  }

  Future<void> _disconnectClient() async {
    final client = _client;
    _client = null;
    client?.disconnect();
    final updates = _updates;
    _updates = null;
    _subscribedTopics.clear();
    _latestSnapshots.clear();
    await updates?.cancel();
  }

  Future<void> retry() async {
    final userId = _userId;
    if (userId == null) {
      throw StateError('Chưa có người dùng để khởi tạo lại phiên MQTT.');
    }
    await startForUser(userId);
  }

  Future<String> _loadOrCreateClientId(SharedPreferences preferences) async {
    final saved = preferences.getString(_clientIdPreferenceKey);
    if (saved != null && saved.isNotEmpty) return saved;
    final random = Random.secure();
    final id =
        'mobile-${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    await preferences.setString(_clientIdPreferenceKey, id);
    return id;
  }

  String _devicePreferenceKey(String userId) =>
      '$_devicePreferencePrefix$userId';

  String _deviceNamePreferenceKey(String userId, String deviceId) =>
      '$_deviceNamePreferencePrefix$userId.$deviceId';

  /// `client.updates` only exists once `connect` has started, so the listener
  /// cannot be attached before it.
  void _listenForUpdates(MqttServerClient client, int generation) {
    if (_updates != null) return;
    _updates = client.updates?.listen(
      (messages) => _onMessages(messages, generation),
    );
  }

  void _onConnected(int generation) {
    if (generation != _generation) return;
    final client = _client;
    if (client != null) _listenForUpdates(client, generation);
    _setStatus(MqttSessionStatus.connected);
    _subscribeKnownDevices();
  }

  void _onDisconnected(int generation) {
    if (generation != _generation || _client == null) return;
    _setStatus(MqttSessionStatus.disconnected);
  }

  void _onAutoReconnect(int generation) {
    if (generation == _generation) {
      _setStatus(MqttSessionStatus.reconnecting);
    }
  }

  void _onAutoReconnected(int generation) {
    if (generation != _generation) return;
    _setStatus(MqttSessionStatus.connected);
    _subscribeKnownDevices();
  }

  void _subscribeKnownDevices() {
    for (final id in _deviceIds) {
      _subscribeDevice(id);
    }
  }

  void _subscribeDevice(String deviceId) {
    final client = _client;
    final userId = _userId;
    if (client?.connectionStatus?.state != MqttConnectionState.connected ||
        userId == null) {
      return;
    }
    final topics = MqttDeviceTopics.forDevice(
      userId: userId,
      deviceId: deviceId,
    );
    for (final topic in topics.subscriptions) {
      if (_subscribedTopics.add(topic)) {
        client!.subscribe(
          topic,
          topic == topics.telemetry ? MqttQos.atMostOnce : MqttQos.atLeastOnce,
        );
      }
    }
  }

  void _onMessages(
    List<MqttReceivedMessage<MqttMessage>> messages,
    int generation,
  ) {
    if (generation != _generation) return;
    final userId = _userId;
    if (userId == null) return;
    for (final received in messages) {
      final kind = MqttDeviceTopics.kindFromTopic(received.topic);
      final deviceId = MqttDeviceTopics.deviceIdFromTopic(
        received.topic,
        userId: userId,
      );
      if (kind == null || deviceId == null || !_deviceIds.contains(deviceId)) {
        continue;
      }
      final publish = received.payload as MqttPublishMessage;
      _dispatch(
        MqttDeviceMessage(
          deviceId: deviceId,
          topic: received.topic,
          kind: kind,
          payload: utf8.decode(publish.payload.message, allowMalformed: true),
          receivedAt: DateTime.now(),
        ),
      );
    }
  }

  void _setStatus(MqttSessionStatus status, {String? error}) {
    _status = status;
    _lastError = error;
    notifyListeners();
  }

  @override
  void dispose() {
    _updates?.cancel();
    _client?.disconnect();
    _messages.close();
    super.dispose();
  }
}

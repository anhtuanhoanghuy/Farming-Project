import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../protocol/mqtt_payloads.dart';
import '../protocol/mqtt_topics.dart';

/// One MQTT message the app sent or received, for the technical log.
class TrafficEntry {
  TrafficEntry({
    required this.id,
    required this.time,
    required this.direction,
    required this.type,
    required this.deviceId,
    required this.topic,
    required this.summary,
    this.payload,
    this.raw,
  });

  final int id;
  final DateTime time;

  /// `TX` (app → ESP32) or `RX` (ESP32 → app).
  final String direction;

  /// One of [TrafficLog.types].
  final String type;
  final String deviceId;
  final String topic;
  final String summary;

  /// The decoded JSON body; null when it was not a JSON object.
  final Map<String, Object?>? payload;

  /// The body as received when it could not be decoded.
  final String? raw;

  String get timeText {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  }

  String get header => '$timeText  $direction · MQTT · $type';

  String get prettyPayload => payload != null
      ? const JsonEncoder.withIndent('  ').convert(payload)
      : (raw ?? '');
}

/// The last MQTT messages of the session, newest last. The telemetry arrives
/// every couple of seconds, so it has a smaller share of the buffer than the
/// commands, ACKs and status messages it would otherwise push out.
class TrafficLog extends ChangeNotifier {
  TrafficLog({this.capacity = 600, this.telemetryCapacity = 120});

  static final instance = TrafficLog();

  static const types = ['Telemetry', 'Command', 'Config', 'ACK', 'Status', 'Event'];

  /// Commands that change a stored setting rather than the live state.
  static const _liveCommands = {
    'SET_LOAD_STATE',
    'SET_LOAD_DELAY',
    'STOP_LOAD_DELAY',
    'EMERGENCY_STOP',
    'GET_STATUS',
  };

  final int capacity;
  final int telemetryCapacity;
  final _entries = <TrafficEntry>[];
  int _nextId = 1;
  int _telemetryCount = 0;

  List<TrafficEntry> get entries => List.unmodifiable(_entries);

  List<TrafficEntry> entriesOf(String deviceId) => [
    for (final entry in _entries)
      if (entry.deviceId == deviceId) entry,
  ];

  void clear([String? deviceId]) {
    if (deviceId == null) {
      _entries.clear();
      _telemetryCount = 0;
    } else {
      _entries.removeWhere((e) => e.deviceId == deviceId);
      _telemetryCount = _entries.where((e) => e.type == 'Telemetry').length;
    }
    notifyListeners();
  }

  /// A command the app published on `commands`.
  void addTx(String deviceId, String topic, Map<String, Object?> payload) {
    final name = MqttPayloads.commandName(payload);
    _add(
      direction: 'TX',
      type: _liveCommands.contains(name) ? 'Command' : 'Config',
      deviceId: deviceId,
      topic: topic,
      summary: '$name · cmd_id=${payload['cmd_id']}',
      payload: payload,
    );
  }

  /// A message received on `ack`, `status` or `telemetry`.
  void addRx(
    String deviceId,
    String topic,
    MqttDeviceTopicKind kind,
    String body,
  ) {
    Map<String, Object?>? json;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) json = Map<String, Object?>.from(decoded);
    } on FormatException {
      json = null;
    }
    final (type, summary) = _describe(kind, json);
    _add(
      direction: 'RX',
      type: type,
      deviceId: deviceId,
      topic: topic,
      summary: summary,
      payload: json,
      raw: json == null ? body : null,
    );
  }

  static (String, String) _describe(
    MqttDeviceTopicKind kind,
    Map<String, Object?>? json,
  ) {
    if (json == null) {
      return (
        switch (kind) {
          MqttDeviceTopicKind.telemetry => 'Telemetry',
          MqttDeviceTopicKind.ack => 'ACK',
          _ => 'Status',
        },
        'Bản tin không phải JSON hợp lệ',
      );
    }
    switch (kind) {
      case MqttDeviceTopicKind.telemetry:
        final input = json['input'];
        return (
          'Telemetry',
          'seq=${json['seq']} · ${input is List ? input.length : 0} cảm biến'
              ' · ${json['net_interface'] ?? '-'}'
              '${json['buffered'] == true ? ' · buffered' : ''}',
        );
      case MqttDeviceTopicKind.ack:
        final ok = json['result'] == 'ok';
        return (
          'ACK',
          '${json['cmd'] ?? '?'} · ${ok ? 'ok' : 'LỖI ${json['code']}'}'
              '${json['reason'] != null ? ' · ${json['reason']}' : ''}'
              '${json['dup'] == true ? ' · dup' : ''}',
        );
      case MqttDeviceTopicKind.status:
      case MqttDeviceTopicKind.commands:
        switch (json['type']) {
          case 'SNAPSHOT':
            final loads = json['loads'];
            final input = json['input'];
            final errors = json['errors'];
            return (
              'Status',
              'SNAPSHOT · ${loads is List ? loads.length : 0} tải · '
                  '${input is List ? input.length : 0} cảm biến · '
                  'error_mask=${errors is Map ? errors['code_mask'] : '-'}',
            );
          case 'LWT':
            return ('Status', 'LWT · ${json['state']}');
          case 'EVENT':
            final detail = [
              for (final key in ['load_id', 'state', 'source', 'reason'])
                if (json[key] != null) '$key=${json[key]}',
            ].join(' ');
            return ('Event', '${json['event']}${detail.isEmpty ? '' : ' · $detail'}');
        }
        return ('Status', '${json['type'] ?? 'status'}');
    }
  }

  void _add({
    required String direction,
    required String type,
    required String deviceId,
    required String topic,
    required String summary,
    Map<String, Object?>? payload,
    String? raw,
  }) {
    _entries.add(
      TrafficEntry(
        id: _nextId++,
        time: DateTime.now(),
        direction: direction,
        type: type,
        deviceId: deviceId,
        topic: topic,
        summary: summary,
        payload: payload,
        raw: raw,
      ),
    );
    if (type == 'Telemetry') {
      _telemetryCount++;
      if (_telemetryCount > telemetryCapacity) {
        final index = _entries.indexWhere((e) => e.type == 'Telemetry');
        if (index >= 0) _entries.removeAt(index);
        _telemetryCount--;
      }
    }
    while (_entries.length > capacity) {
      final removed = _entries.removeAt(0);
      if (removed.type == 'Telemetry') _telemetryCount--;
    }
    notifyListeners();
  }
}

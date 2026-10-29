import 'dart:convert';

import 'mqtt_payloads.dart';
import 'mqtt_topics.dart';

/// One-line descriptions of the MQTT traffic for the debug console, in the
/// form `[MQTT] TX cmd=SET_LOAD_STATE cmd_id=... payload=...`.
abstract final class MqttLog {
  static const prefix = '[MQTT]';

  static String tx(Map<String, Object?> payload) =>
      '$prefix TX cmd=${MqttPayloads.commandName(payload)} '
      'cmd_id=${payload['cmd_id']} payload=${jsonEncode(payload)}';

  static String rx(String deviceId, MqttDeviceTopicKind kind, String payload) {
    final Object? decoded;
    try {
      decoded = jsonDecode(payload);
    } on FormatException {
      return '$prefix RX ${kind.name} device=$deviceId invalid JSON: $payload';
    }
    if (decoded is! Map) {
      return '$prefix RX ${kind.name} device=$deviceId unexpected payload: $payload';
    }
    switch (kind) {
      case MqttDeviceTopicKind.ack:
        return '$prefix RX ack cmd_id=${decoded['cmd_id']} '
            'result=${decoded['result']} code=${decoded['code']} '
            'reason=${decoded['reason']} dup=${decoded['dup']}';
      case MqttDeviceTopicKind.telemetry:
        final input = decoded['input'];
        return '$prefix RX telemetry device=$deviceId seq=${decoded['seq']} '
            'inputs=${input is List ? input.length : 0} '
            'buffered=${decoded['buffered']}';
      case MqttDeviceTopicKind.status:
        return switch (decoded['type']) {
          'SNAPSHOT' => '$prefix RX snapshot device=$deviceId '
              'boot_id=${decoded['boot_id']} ts=${decoded['ts']} '
              'loads=${_count(decoded['loads'])} '
              'inputs=${_count(decoded['input'])} '
              'emergency=${_emergency(decoded)}',
          'LWT' => '$prefix RX status LWT device=$deviceId '
              'state=${decoded['state']} boot_id=${decoded['boot_id']}',
          'EVENT' => '$prefix RX event device=$deviceId payload=$payload',
          _ => '$prefix RX status device=$deviceId payload=$payload',
        };
      case MqttDeviceTopicKind.commands:
        return '$prefix RX commands device=$deviceId payload=$payload';
    }
  }

  static int _count(Object? list) => list is List ? list.length : 0;

  static Object? _emergency(Map<dynamic, dynamic> snapshot) {
    final emergency = snapshot['emergency'];
    return emergency is Map ? emergency['active'] : null;
  }
}

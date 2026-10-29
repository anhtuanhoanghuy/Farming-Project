import 'port_ids.dart';

/// One measured value of a sensor, with the name and unit the ESP32 sent.
/// Digital inputs report a [bool]; everything else a number.
class TelemetryValue {
  const TelemetryValue({
    required this.name,
    required this.unit,
    required this.value,
  });

  final String name;
  final String unit;
  final Object value;

  /// The value as shown on screen: numbers as sent, booleans as "Có"/"Không".
  String get display => switch (value) {
    true => '1',
    false => '0',
    _ => '$value',
  };
}

/// One sensor of the `telemetry` message. [values] is empty when [valid] is
/// false.
class TelemetryInput {
  const TelemetryInput({
    required this.interfaceType,
    required this.portId,
    required this.name,
    required this.valid,
    required this.values,
  });

  static TelemetryInput? tryParse(Object? json) {
    if (json is! Map ||
        json['port_id'] is! String ||
        !PortIds.isSensor(json['port_id'] as String)) {
      return null;
    }
    return TelemetryInput(
      interfaceType: json['interface_type'] is String
          ? json['interface_type'] as String
          : '',
      portId: json['port_id'] as String,
      name: json['name'] is String ? json['name'] as String : '',
      valid: json['valid'] == true,
      values: [
        if (json['values'] is List)
          for (final item in json['values'] as List)
            if (item is Map &&
                item['name'] is String &&
                (item['value'] is num || item['value'] is bool))
              TelemetryValue(
                name: item['name'] as String,
                unit: item['unit'] is String ? item['unit'] as String : '',
                value: item['value'] as Object,
              ),
      ],
    );
  }

  final String interfaceType;
  final String portId;
  final String name;
  final bool valid;
  final List<TelemetryValue> values;
}

/// The periodic `telemetry` message: values of the enabled sensors only.
class DeviceTelemetry {
  const DeviceTelemetry({
    required this.receivedAt,
    required this.seq,
    required this.inputs,
    this.bootId,
    this.uptimeMs,
    this.buffered = false,
    this.netInterface,
    this.ts,
    this.errorMask = 0,
  });

  /// Null when [json] has no `input` list.
  static DeviceTelemetry? tryParse(Map<dynamic, dynamic> json, DateTime at) {
    final input = json['input'];
    if (input is! List) return null;
    final errors = json['errors'];
    final method = json['net_interface'];
    return DeviceTelemetry(
      receivedAt: at,
      seq: json['seq'] is num ? (json['seq'] as num).toInt() : 0,
      bootId: json['boot_id'] is String ? json['boot_id'] as String : null,
      uptimeMs: json['uptime_ms'] is num
          ? (json['uptime_ms'] as num).toInt()
          : null,
      buffered: json['buffered'] == true,
      netInterface: method == 'WIFI' || method == 'ETH'
          ? method as String
          : null,
      ts: json['ts'] is num ? (json['ts'] as num).toInt() : null,
      inputs: [for (final item in input) ?TelemetryInput.tryParse(item)],
      errorMask: errors is Map && errors['code_mask'] is num
          ? (errors['code_mask'] as num).toInt()
          : 0,
    );
  }

  final DateTime receivedAt;
  final int seq;
  final String? bootId;
  final int? uptimeMs;

  /// True when the ESP32 sends a reading it stored while offline.
  final bool buffered;

  /// `WIFI` or `ETH`.
  final String? netInterface;
  final int? ts;
  final List<TelemetryInput> inputs;
  final int errorMask;

  TelemetryInput? input(String portId) =>
      inputs.where((s) => s.portId == portId).firstOrNull;
}

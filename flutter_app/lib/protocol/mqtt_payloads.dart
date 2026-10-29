import 'dart:convert';
import 'dart:math';

import 'port_ids.dart';

/// Builders of every command the app sends on the `commands` topic. The field
/// names and values follow `mqtt_protocol.md`; each builder validates its
/// arguments so the ESP32 never receives a malformed command.
class MqttPayloads {
  MqttPayloads._();

  static const version = 1;
  static final _random = Random.secure();
  static final _cmdIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,36}$');
  static final _timePattern = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$');

  static String newCommandId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }

  /// Command name as the ESP32 identifies it: the string `type`.
  static String commandName(Map<String, Object?> payload) {
    final type = payload['type'];
    return type is String ? type : 'UNKNOWN';
  }

  // ------------------------------------------------------------------ loads

  static Map<String, Object?> setLoadState({
    required String cmdId,
    required String loadId,
    required bool on,
  }) => _command(cmdId, 'SET_LOAD_STATE', {
    'load_id': _loadId(loadId),
    'action': on,
  });

  /// One-shot delay. [offThenOn] false = wait [delayMin] then ON for
  /// [duration] minutes then OFF; true = the opposite. A [duration] of 0 means
  /// the load changes state once after [delayMin] and the delay then ends.
  static Map<String, Object?> setLoadDelay({
    required String cmdId,
    required String loadId,
    required bool offThenOn,
    required int delayMin,
    required int duration,
  }) {
    _range(delayMin, 0, 1440, 'delayMin');
    _range(duration, 0, 1440, 'duration');
    return _command(cmdId, 'SET_LOAD_DELAY', {
      'load_id': _loadId(loadId),
      'mode': offThenOn,
      'delay_min': delayMin,
      'duration': duration,
    });
  }

  static Map<String, Object?> stopLoadDelay({
    required String cmdId,
    required String loadId,
  }) => _command(cmdId, 'STOP_LOAD_DELAY', {'load_id': _loadId(loadId)});

  static Map<String, Object?> setLoadName({
    required String cmdId,
    required String loadId,
    required String name,
  }) => _command(cmdId, 'SET_LOAD_NAME', {
    'load_id': _loadId(loadId),
    'name': _name(name),
  });

  static Map<String, Object?> toggleLoadCapability({
    required String cmdId,
    required String loadId,
    required bool enabled,
  }) => _command(cmdId, 'TOGGLE_LOAD_CAPABILITY', {
    'load_id': _loadId(loadId),
    'action': enabled,
  });

  // ------------------------------------------------------------- conditions

  static Map<String, Object?> addLoadCondition({
    required String cmdId,
    required String loadId,
    required String conditionId,
  }) => _command(cmdId, 'ADD_LOAD_CONDITION', {
    'load_id': _loadId(loadId),
    'condition_id': _conditionId(conditionId),
  });

  /// [action] true = turn the load on when the condition holds. [greater]
  /// true = `>` threshold, false = `<` threshold.
  static Map<String, Object?> setLoadCondition({
    required String cmdId,
    required String loadId,
    required String conditionId,
    required bool conditionEnabled,
    required bool action,
    required String sensorId,
    required String valueName,
    required bool greater,
    required double threshold,
  }) {
    if (!threshold.isFinite || threshold < -1e6 || threshold > 1e6) {
      throw ArgumentError.value(threshold, 'threshold');
    }
    if (valueName.trim().isEmpty) {
      throw ArgumentError.value(valueName, 'valueName');
    }
    return _command(cmdId, 'SET_LOAD_CONDITION', {
      'condition_id': _conditionId(conditionId),
      'condition_enabled': conditionEnabled,
      'load_id': _loadId(loadId),
      'action': action,
      'sensor_id': _sensorId(sensorId),
      'value_name': valueName,
      'operator': greater,
      'threshold': threshold,
    });
  }

  static Map<String, Object?> toggleLoadCondition({
    required String cmdId,
    required String loadId,
    required String conditionId,
    required bool enabled,
  }) => _command(cmdId, 'TOGGLE_LOAD_CONDITION', {
    'load_id': _loadId(loadId),
    'condition_id': _conditionId(conditionId),
    'action': enabled,
  });

  static Map<String, Object?> deleteLoadCondition({
    required String cmdId,
    required String loadId,
    required String conditionId,
  }) => _command(cmdId, 'DELETE_LOAD_CONDITION', {
    'condition_id': _conditionId(conditionId),
    'load_id': _loadId(loadId),
  });

  // -------------------------------------------------------------- schedules

  static Map<String, Object?> addLoadScheduler({
    required String cmdId,
    required String loadId,
    required String schedulerId,
  }) => _command(cmdId, 'ADD_LOAD_SCHEDULER', {
    'load_id': _loadId(loadId),
    'scheduler_id': _schedulerId(schedulerId),
  });

  /// [daysMask]: Monday = 1 ... Sunday = 64. Times are UTC `HH:MM`.
  static Map<String, Object?> setLoadSchedule({
    required String cmdId,
    required String loadId,
    required String schedulerId,
    required bool schedulerEnabled,
    required int daysMask,
    required String onTimeUtc,
    required String offTimeUtc,
  }) {
    _range(daysMask, 0, 127, 'daysMask');
    return _command(cmdId, 'SET_LOAD_SCHEDULE', {
      'scheduler_id': _schedulerId(schedulerId),
      'load_id': _loadId(loadId),
      'scheduler_enabled': schedulerEnabled,
      'days_mask': daysMask,
      'on_time_utc': _time(onTimeUtc, 'onTimeUtc'),
      'off_time_utc': _time(offTimeUtc, 'offTimeUtc'),
    });
  }

  static Map<String, Object?> toggleLoadScheduler({
    required String cmdId,
    required String loadId,
    required String schedulerId,
    required bool enabled,
  }) => _command(cmdId, 'TOGGLE_LOAD_SCHEDULER', {
    'load_id': _loadId(loadId),
    'scheduler_id': _schedulerId(schedulerId),
    'action': enabled,
  });

  static Map<String, Object?> deleteLoadScheduler({
    required String cmdId,
    required String loadId,
    required String schedulerId,
  }) => _command(cmdId, 'DELETE_LOAD_SCHEDULER', {
    'scheduler_id': _schedulerId(schedulerId),
    'load_id': _loadId(loadId),
  });

  // ---------------------------------------------------------------- sensors

  /// [add] true adds a sensor on a free port, false modifies the sensor of
  /// the port. RS485 needs [slaveId]; analog and DI must not have one.
  static Map<String, Object?> sensorConfig({
    required String cmdId,
    required bool add,
    required bool enabled,
    required String sensorId,
    required String name,
    int? slaveId,
  }) {
    final interfaceType = PortIds.interfaceTypeOfPort(_sensorId(sensorId))!;
    if (interfaceType == PortIds.rs485Type) {
      if (slaveId == null) {
        throw ArgumentError('RS485 sensor requires slave_id');
      }
      _range(slaveId, 1, 247, 'slaveId');
    } else if (slaveId != null) {
      throw ArgumentError.value(slaveId, 'slaveId', 'Only RS485 has slave_id');
    }
    return _command(cmdId, 'SENSOR_CONFIG', {
      'action': add,
      'enabled': enabled,
      'interface_type': interfaceType,
      'sensor_id': sensorId,
      'slave_id': ?slaveId,
      'name': _name(name),
    });
  }

  static Map<String, Object?> deleteSensor({
    required String cmdId,
    required String sensorId,
  }) => _command(cmdId, 'DELETE_SENSOR', {'sensor_id': _sensorId(sensorId)});

  static Map<String, Object?> toggleSensorCapability({
    required String cmdId,
    required String sensorId,
    required bool enabled,
  }) => _command(cmdId, 'TOGGLE_SENSOR_CAPABILITY', {
    'sensor_id': _sensorId(sensorId),
    'action': enabled,
  });

  // ----------------------------------------------------------------- device

  static Map<String, Object?> setDeviceName({
    required String cmdId,
    required String name,
  }) => _command(cmdId, 'SET_DEVICE_NAME', {'name': _name(name)});

  static Map<String, Object?> setTelemetryInterval({
    required String cmdId,
    required int intervalSeconds,
  }) {
    _range(intervalSeconds, 5, 600, 'intervalSeconds');
    return _command(cmdId, 'SET_TELEMETRY_INTERVAL', {
      'interval_s': intervalSeconds,
    });
  }

  /// Asks the ESP32 to publish a full snapshot on the `status` topic.
  static Map<String, Object?> getStatus({required String cmdId}) =>
      _command(cmdId, 'GET_STATUS', const {});

  /// Asks the ESP32 to publish its latest sensor telemetry immediately.
  static Map<String, Object?> getTelemetry({required String cmdId}) =>
      _command(cmdId, 'GET_TELEMETRY', const {});

  /// Turns every load off, clears each load's delay, conditions and
  /// schedules, and disables all sensors (loads stay enabled). There is no
  /// release command: sensors are enabled one by one afterwards.
  static Map<String, Object?> emergencyStop({required String cmdId}) =>
      _command(cmdId, 'EMERGENCY_STOP', const {});

  // ---------------------------------------------------------------- helpers

  static Map<String, Object?> _command(
    String cmdId,
    String type,
    Map<String, Object?> fields,
  ) {
    _commandId(cmdId);
    return {'v': version, 'cmd_id': cmdId, 'type': type, ...fields};
  }

  static void _commandId(String cmdId) {
    if (!_cmdIdPattern.hasMatch(cmdId)) {
      throw ArgumentError.value(cmdId, 'cmdId');
    }
  }

  static String _loadId(String id) =>
      PortIds.isLoad(id) ? id : throw ArgumentError.value(id, 'loadId');

  static String _sensorId(String id) =>
      PortIds.isSensor(id) ? id : throw ArgumentError.value(id, 'sensorId');

  static String _conditionId(String id) => PortIds.isCondition(id)
      ? id
      : throw ArgumentError.value(id, 'conditionId');

  static String _schedulerId(String id) => PortIds.isScheduler(id)
      ? id
      : throw ArgumentError.value(id, 'schedulerId');

  static void _range(int value, int min, int max, String name) {
    if (value < min || value > max) {
      throw ArgumentError.value(value, name, 'Expected $min..$max');
    }
  }

  static String _time(String value, String name) => _timePattern.hasMatch(value)
      ? value
      : throw ArgumentError.value(value, name);

  /// 1..31 UTF-8 bytes without leading or trailing whitespace.
  static String _name(String name) {
    if (name.isEmpty ||
        utf8.encode(name).length > 31 ||
        name.trim() != name ||
        name.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
      throw ArgumentError.value(name, 'name');
    }
    return name;
  }
}

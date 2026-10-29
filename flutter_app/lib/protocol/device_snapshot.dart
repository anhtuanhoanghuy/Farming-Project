import 'port_ids.dart';

bool _bool(Object? value, [bool fallback = false]) =>
    value is bool ? value : fallback;

int _int(Object? value, [int fallback = 0]) =>
    value is num ? value.toInt() : fallback;

double _double(Object? value, [double fallback = 0]) =>
    value is num ? value.toDouble() : fallback;

String _string(Object? value, [String fallback = '']) =>
    value is String ? value : fallback;

List<Map<dynamic, dynamic>> _maps(Object? value) => [
  if (value is List)
    for (final item in value)
      if (item is Map) item,
];

/// What a `load_delay` of the snapshot is doing.
enum DelayPhase {
  idle,
  waitFirst,
  waitSecond;

  static DelayPhase parse(Object? value) => switch (value) {
    'WAIT_FIRST' => waitFirst,
    'WAIT_SECOND' => waitSecond,
    _ => idle,
  };
}

/// The one-shot delay timer of a load. The ESP32 owns it; the app mirrors it
/// from [remainingSeconds], measured when the snapshot reached the phone.
class LoadDelay {
  const LoadDelay({
    this.active = false,
    this.startTime,
    this.offThenOn = false,
    this.delayMin = 0,
    this.duration = 0,
    this.phase = DelayPhase.idle,
    this.remainingSeconds = 0,
  });

  factory LoadDelay.fromJson(Object? json) {
    if (json is! Map) return const LoadDelay();
    return LoadDelay(
      active: _bool(json['active']),
      startTime: json['start_time'] is String
          ? json['start_time'] as String
          : null,
      offThenOn: _bool(json['mode']),
      delayMin: _int(json['delay_min']),
      duration: _int(json['duration']),
      phase: DelayPhase.parse(json['phase']),
      remainingSeconds: _int(json['remaining_s']),
    );
  }

  final bool active;

  /// UTC `HH:MM`; only present once the ESP32 knows the time.
  final String? startTime;

  /// false = ON then OFF, true = OFF then ON.
  final bool offThenOn;
  final int delayMin;
  final int duration;
  final DelayPhase phase;
  final int remainingSeconds;

  bool get isRunning => active && phase != DelayPhase.idle;

  /// State the load takes when the running phase ends (true = on); null when
  /// no delay is running.
  bool? get targetOn {
    if (!isRunning) return null;
    return phase == DelayPhase.waitFirst ? !offThenOn : offThenOn;
  }

  /// Time left at [now] for a snapshot received at [receivedAt]; never below
  /// zero.
  Duration remainingAt(DateTime receivedAt, DateTime now) {
    if (!isRunning) return Duration.zero;
    final left =
        Duration(seconds: remainingSeconds) - now.difference(receivedAt);
    return left.isNegative ? Duration.zero : left;
  }
}

/// A sensor condition of a load (`load_condition[]`).
class LoadCondition {
  const LoadCondition({
    required this.conditionId,
    required this.enabled,
    required this.action,
    required this.sensorId,
    required this.valueName,
    required this.greater,
    required this.threshold,
  });

  factory LoadCondition.fromJson(Map<dynamic, dynamic> json) => LoadCondition(
    conditionId: _string(json['condition_id']),
    enabled: _bool(json['condition_enabled']),
    action: _bool(json['action']),
    sensorId: _string(json['sensor_id']),
    valueName: _string(json['value_name']),
    greater: _bool(json['operator']),
    threshold: _double(json['threshold']),
  );

  final String conditionId;
  final bool enabled;

  /// true = turn the load on when the condition holds.
  final bool action;

  /// Port id (`RS1`); empty while no sensor has been chosen.
  final String sensorId;
  final String valueName;

  /// true = `>`, false = `<`.
  final bool greater;
  final double threshold;
}

/// A weekly schedule of a load (`load_scheduler[]`), in UTC.
class LoadSchedule {
  const LoadSchedule({
    required this.schedulerId,
    required this.enabled,
    required this.daysMask,
    required this.onTimeUtc,
    required this.offTimeUtc,
  });

  factory LoadSchedule.fromJson(Map<dynamic, dynamic> json) => LoadSchedule(
    schedulerId: _string(json['scheduler_id']),
    enabled: _bool(json['scheduler_enabled']),
    daysMask: _int(json['days_mask']),
    onTimeUtc: _string(json['on_time_utc'], '00:00'),
    offTimeUtc: _string(json['off_time_utc'], '00:00'),
  );

  final String schedulerId;
  final bool enabled;

  /// Monday = 1 ... Sunday = 64.
  final int daysMask;
  final String onTimeUtc;
  final String offTimeUtc;
}

/// One load as the ESP32 reports it in the snapshot.
class LoadSnapshot {
  const LoadSnapshot({
    required this.loadId,
    required this.name,
    required this.enabled,
    required this.state,
    this.delay = const LoadDelay(),
    this.conditions = const [],
    this.schedules = const [],
  });

  static LoadSnapshot? tryParse(Object? json) {
    if (json is! Map || !PortIds.isLoad(_string(json['load_id']))) return null;
    return LoadSnapshot(
      loadId: json['load_id'] as String,
      name: _string(json['name']),
      enabled: _bool(json['enabled']),
      state: _bool(json['state']),
      delay: LoadDelay.fromJson(json['load_delay']),
      conditions: [
        for (final item in _maps(json['load_condition']))
          LoadCondition.fromJson(item),
      ],
      schedules: [
        for (final item in _maps(json['load_scheduler']))
          LoadSchedule.fromJson(item),
      ],
    );
  }

  /// `DO1`..`DO4`.
  final String loadId;
  final String name;

  /// "Cho phép điều khiển tải".
  final bool enabled;

  /// Real relay output.
  final bool state;
  final LoadDelay delay;
  final List<LoadCondition> conditions;
  final List<LoadSchedule> schedules;

  LoadCondition? condition(String id) =>
      conditions.where((c) => c.conditionId == id).firstOrNull;

  LoadSchedule? schedule(String id) =>
      schedules.where((s) => s.schedulerId == id).firstOrNull;
}

/// A configured sensor of the snapshot `input[]` (enabled or not).
class SensorInput {
  const SensorInput({
    required this.interfaceType,
    required this.portId,
    required this.name,
    required this.enabled,
    required this.valid,
    this.slaveId,
    this.valueNames = const [],
  });

  static SensorInput? tryParse(Object? json) {
    if (json is! Map || !PortIds.isSensor(_string(json['port_id']))) {
      return null;
    }
    return SensorInput(
      interfaceType: _string(json['interface_type']),
      portId: json['port_id'] as String,
      name: _string(json['name']),
      enabled: _bool(json['enabled']),
      valid: _bool(json['valid']),
      slaveId: json['slave_id'] is num
          ? (json['slave_id'] as num).toInt()
          : null,
      valueNames: json['value_names'] is List
          ? [
              for (final n in json['value_names'] as List)
                if (n is String && n.isNotEmpty) n,
            ]
          : const [],
    );
  }

  /// Metrics this sensor publishes, announced by the firmware.
  final List<String> valueNames;
  final String interfaceType;

  /// `RS1`..`RS4`, `AN1`, `DI1`..`DI4`.
  final String portId;
  final String name;
  final bool enabled;
  final bool valid;
  final int? slaveId;
}

/// What one interface family of the device supports.
class InterfaceCapability {
  const InterfaceCapability({
    this.supported = false,
    this.count = 0,
    this.ports = const [],
  });

  factory InterfaceCapability.fromJson(Object? json) {
    if (json is! Map) return const InterfaceCapability();
    return InterfaceCapability(
      supported: _bool(json['supported']),
      count: _int(json['count']),
      ports: [
        if (json['port_lists'] is List)
          for (final port in json['port_lists'] as List)
            if (port is String) port,
      ],
    );
  }

  final bool supported;
  final int count;
  final List<String> ports;
}

class DeviceCapabilities {
  const DeviceCapabilities({
    this.rs485 = const InterfaceCapability(),
    this.analog = const InterfaceCapability(),
    this.digitalInputs = const InterfaceCapability(),
    this.loads = const InterfaceCapability(),
  });

  factory DeviceCapabilities.fromJson(Object? json) {
    if (json is! Map) return const DeviceCapabilities();
    return DeviceCapabilities(
      rs485: InterfaceCapability.fromJson(json['rs485']),
      analog: InterfaceCapability.fromJson(json['analog_4_20ma']),
      digitalInputs: InterfaceCapability.fromJson(json['digital_inputs']),
      loads: InterfaceCapability.fromJson(json['loads']),
    );
  }

  final InterfaceCapability rs485;
  final InterfaceCapability analog;
  final InterfaceCapability digitalInputs;
  final InterfaceCapability loads;

  /// Sensor ports the firmware offers (RS485 + analog 4-20 mA + DI); null
  /// when the snapshot did not report any.
  int? get maxSensorCount {
    final total = rs485.count + analog.count + digitalInputs.count;
    return total > 0 ? total : null;
  }

  /// Loads (relay outputs) the firmware offers; null when not reported.
  int? get maxLoadCount => loads.count > 0 ? loads.count : null;
  InterfaceCapability forInterface(String interfaceType) =>
      switch (interfaceType) {
        PortIds.rs485Type => rs485,
        PortIds.analogType => analog,
        PortIds.diType => digitalInputs,
        _ => const InterfaceCapability(),
      };
}

/// The retained `status` snapshot: what the ESP32 really holds.
class DeviceSnapshot {
  const DeviceSnapshot({
    required this.receivedAt,
    this.bootId,
    this.deviceName,
    this.netInterface,
    this.ssid,
    this.ipAddress,
    this.uptimeMs,
    this.telemetryIntervalSeconds,
    this.ts,
    this.capabilities = const DeviceCapabilities(),
    this.inputs = const [],
    this.loads = const [],
    this.emergencyActive = false,
    this.interlockTripped = false,
    this.errorMask = 0,
    this.errorMessages = const [],
    this.heapFree,
    this.heapMinFree,
    this.mqttReconnects,
    this.mqttRxRejected,
    this.mqttTxFail,
    this.telemetryDropped,
  });

  /// Parses a `"type":"SNAPSHOT"` body; null when it is not one. [at] is when
  /// the phone received it, the anchor of every countdown.
  static DeviceSnapshot? tryParse(Map<dynamic, dynamic> json, DateTime at) {
    if (json['type'] != 'SNAPSHOT' || json['loads'] is! List) return null;
    final emergency = json['emergency'];
    final interlock = json['interlock'];
    final errors = json['errors'];
    final heap = json['heap'];
    final mqtt = json['mqtt'];
    int? number(Object? map, String key) =>
        map is Map && map[key] is num ? (map[key] as num).toInt() : null;
    return DeviceSnapshot(
      receivedAt: at,
      errorMessages: [
        if (errors is Map && errors['messages'] is List)
          for (final message in errors['messages'] as List)
            if (message is String) message,
      ],
      heapFree: number(heap, 'free'),
      heapMinFree: number(heap, 'min_free'),
      mqttReconnects: number(mqtt, 'reconnects'),
      mqttRxRejected: number(mqtt, 'rx_rejected'),
      mqttTxFail: number(mqtt, 'tx_fail'),
      telemetryDropped: number(mqtt, 'telemetry_dropped'),
      bootId: json['boot_id'] is String ? json['boot_id'] as String : null,
      deviceName: json['device_name'] is String
          ? json['device_name'] as String
          : null,
      netInterface: json['net_interface'] is String
          ? json['net_interface'] as String
          : null,
      ssid: json['ssid'] is String ? json['ssid'] as String : null,
      ipAddress: json['ip_address'] is String
          ? json['ip_address'] as String
          : null,
      uptimeMs: json['uptime_ms'] is num
          ? (json['uptime_ms'] as num).toInt()
          : null,
      telemetryIntervalSeconds: json['telemetry_interval_s'] is num
          ? (json['telemetry_interval_s'] as num).toInt()
          : null,
      ts: json['ts'] is num ? (json['ts'] as num).toInt() : null,
      capabilities: DeviceCapabilities.fromJson(json['capabilities']),
      inputs: [
        for (final item
            in json['input'] is List ? json['input'] as List : const [])
          ?SensorInput.tryParse(item),
      ],
      loads: [
        for (final item in json['loads'] as List) ?LoadSnapshot.tryParse(item),
      ],
      emergencyActive: emergency is Map && _bool(emergency['active']),
      interlockTripped: interlock is Map && _bool(interlock['tripped']),
      errorMask: errors is Map ? _int(errors['code_mask']) : 0,
    );
  }

  final DateTime receivedAt;
  final String? bootId;
  final String? deviceName;

  /// `WIFI` or `ETH`.
  final String? netInterface;
  final String? ssid;
  final String? ipAddress;
  final int? uptimeMs;
  final int? telemetryIntervalSeconds;

  /// ESP32 time of the snapshot, UTC milliseconds; null before it has the time.
  final int? ts;
  final DeviceCapabilities capabilities;

  /// Configured sensors (enabled or not).
  final List<SensorInput> inputs;
  final List<LoadSnapshot> loads;
  final bool emergencyActive;
  final bool interlockTripped;
  final int errorMask;

  /// Names of the active errors (`errors.messages`), e.g. `SYS_ERR_NET_LOST`.
  final List<String> errorMessages;

  /// Free heap and its low-water mark, in bytes.
  final int? heapFree;
  final int? heapMinFree;
  final int? mqttReconnects;
  final int? mqttRxRejected;
  final int? mqttTxFail;
  final int? telemetryDropped;

  LoadSnapshot? load(String loadId) =>
      loads.where((l) => l.loadId == loadId).firstOrNull;

  SensorInput? input(String portId) =>
      inputs.where((s) => s.portId == portId).firstOrNull;

  /// Ports of [interfaceType] the device offers; the standard ones until the
  /// snapshot lists them.
  List<String> portsFor(String interfaceType) {
    final ports = capabilities.forInterface(interfaceType).ports;
    return ports.isEmpty ? PortIds.defaultPorts(interfaceType) : ports;
  }

  /// Ports of [interfaceType] that have no sensor yet.
  List<String> freePortsFor(String interfaceType) => [
    for (final port in portsFor(interfaceType))
      if (input(port) == null) port,
  ];
}

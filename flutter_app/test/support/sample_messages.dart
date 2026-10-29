/// Realistic messages of the device, as `mqtt_protocol.md` describes them.
const deviceId = 'aabbccddeeff';

Map<String, Object?> _condition(String id, bool action, double threshold) => {
  'condition_id': id,
  'condition_enabled': id == 'CON1',
  'action': action,
  'sensor_id': 'RS1',
  'value_name': 'Độ ẩm không khí',
  'operator': id == 'CON1',
  'threshold': threshold,
};

Map<String, Object?> _scheduler(
  String id, {
  required bool enabled,
  required String on,
  required String off,
}) => {
  'scheduler_id': id,
  'scheduler_enabled': enabled,
  'days_mask': 31,
  'on_time_utc': on,
  'off_time_utc': off,
};

/// DO1 has 2 conditions, 3 schedulers and a delay running its first phase.
Map<String, Object?> sampleSnapshot({
  bool emergency = false,
  bool loadEnabled = true,
  bool delayActive = true,
}) => {
  'v': 1,
  'type': 'SNAPSHOT',
  'boot_id': '361d7646',
  'device_name': 'Device_01',
  'net_interface': 'WIFI',
  'ssid': 'Farm Wi-Fi',
  'ip_address': '192.168.1.20',
  'uptime_ms': 3600000,
  'telemetry_interval_s': 5,
  'ts': 1791854906000,
  'capabilities': {
    'rs485': {
      'supported': true,
      'count': 4,
      'port_lists': ['RS1', 'RS2', 'RS3', 'RS4'],
    },
    'analog_4_20ma': {
      'supported': true,
      'runtime_available': false,
      'count': 1,
      'port_lists': ['AN1'],
    },
    'digital_inputs': {
      'supported': true,
      'runtime_available': false,
      'count': 4,
      'port_lists': ['DI1', 'DI2', 'DI3', 'DI4'],
    },
    'loads': {
      'supported': true,
      'count': 4,
      'port_lists': ['DO1', 'DO2', 'DO3', 'DO4'],
    },
  },
  'input': [
    {
      'interface_type': 'rs485',
      'port_id': 'RS1',
      'name': 'Nhiệt độ & Độ ẩm',
      'enabled': true,
      'slave_id': 1,
      'valid': true,
      'value_names': ['Nhiệt độ không khí', 'Độ ẩm không khí'],
    },
    {
      'interface_type': 'rs485',
      'port_id': 'RS3',
      'name': 'Cảm biến pH',
      'enabled': false,
      'slave_id': 3,
      'valid': false,
      'value_names': ['Độ pH', 'Nhiệt độ nước'],
    },
    {
      'interface_type': 'di',
      'port_id': 'DI2',
      'name': 'Phao nước',
      'enabled': true,
      'valid': true,
      'value_names': ['Trạng thái'],
    },
  ],
  'loads': [
    {
      'load_id': 'DO1',
      'name': 'Quạt nước 1',
      'enabled': loadEnabled,
      'state': false,
      'load_delay': {
        'active': delayActive,
        'start_time': '14:00',
        'mode': false,
        'delay_min': 5,
        'duration': 30,
        'phase': delayActive ? 'WAIT_FIRST' : 'IDLE',
        'remaining_s': delayActive ? 245 : 0,
      },
      'load_condition': [
        _condition('CON1', true, 4.5),
        _condition('CON2', false, 4.6),
      ],
      'load_scheduler': [
        _scheduler('SHE1', enabled: true, on: '06:00', off: '18:00'),
        _scheduler('SHE2', enabled: false, on: '07:00', off: '09:00'),
        _scheduler('SHE3', enabled: false, on: '02:00', off: '04:00'),
      ],
    },
    for (final n in [2, 3, 4])
      {
        'load_id': 'DO$n',
        'name': 'Quạt nước $n',
        'enabled': true,
        'state': true,
        'load_delay': {
          'active': false,
          'mode': false,
          'delay_min': 0,
          'duration': 0,
          'phase': 'IDLE',
          'remaining_s': 0,
        },
        'load_condition': <Object?>[],
        'load_scheduler': <Object?>[],
      },
  ],
  'interlock': {'tripped': false},
  'emergency': {'active': emergency},
  'errors': {'code_mask': 0, 'messages': <Object?>[]},
  'heap': {'free': 215000, 'min_free': 198000},
  'mqtt': {'reconnects': 1, 'rx_rejected': 0, 'tx_fail': 0},
};

Map<String, Object?> sampleTelemetry({bool buffered = false}) => {
  'v': 1,
  'seq': 142,
  'boot_id': '361d7646',
  'uptime_ms': 3600000,
  'buffered': buffered,
  'net_interface': 'ETH',
  'ts': 1791854906000,
  'input': [
    {
      'interface_type': 'rs485',
      'port_id': 'RS1',
      'name': 'Nhiệt độ & Độ ẩm',
      'valid': true,
      'values': [
        {'name': 'Nhiệt độ không khí', 'unit': '°C', 'value': 25.1},
        {'name': 'Độ ẩm không khí', 'unit': '%RH', 'value': 60},
      ],
    },
    {
      'interface_type': 'rs485',
      'port_id': 'RS3',
      'name': 'Cảm biến pH',
      'valid': false,
      'values': <Object?>[],
    },
    {
      'interface_type': 'di',
      'port_id': 'DI2',
      'name': 'Phao nước',
      'valid': true,
      'values': [
        {'name': 'Trạng thái', 'unit': '', 'value': true},
      ],
    },
  ],
  'errors': {'code_mask': 0},
};

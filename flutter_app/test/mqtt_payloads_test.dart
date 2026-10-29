import 'package:flutter_app/protocol/mqtt_payloads.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const id = 'cmd-01';

  test('generates firmware-compatible command IDs', () {
    final cmdId = MqttPayloads.newCommandId();
    expect(cmdId, matches(RegExp(r'^[0-9a-f-]{36}$')));
    expect(() => MqttPayloads.getStatus(cmdId: 'bad id!'), throwsArgumentError);
    expect(() => MqttPayloads.getStatus(cmdId: 'x' * 37), throwsArgumentError);
  });

  test('load state, delay, name and capability', () {
    expect(MqttPayloads.setLoadState(cmdId: id, loadId: 'DO1', on: true), {
      'v': 1,
      'cmd_id': id,
      'type': 'SET_LOAD_STATE',
      'load_id': 'DO1',
      'action': true,
    });
    expect(
      MqttPayloads.setLoadDelay(
        cmdId: id,
        loadId: 'DO2',
        offThenOn: true,
        delayMin: 5,
        duration: 0,
      ),
      {
        'v': 1,
        'cmd_id': id,
        'type': 'SET_LOAD_DELAY',
        'load_id': 'DO2',
        'mode': true,
        'delay_min': 5,
        'duration': 0,
      },
    );
    expect(MqttPayloads.stopLoadDelay(cmdId: id, loadId: 'DO3'), {
      'v': 1,
      'cmd_id': id,
      'type': 'STOP_LOAD_DELAY',
      'load_id': 'DO3',
    });
    expect(
      MqttPayloads.setLoadName(cmdId: id, loadId: 'DO4', name: 'Quạt nước 1'),
      {
        'v': 1,
        'cmd_id': id,
        'type': 'SET_LOAD_NAME',
        'load_id': 'DO4',
        'name': 'Quạt nước 1',
      },
    );
    expect(
      MqttPayloads.toggleLoadCapability(
        cmdId: id,
        loadId: 'DO1',
        enabled: false,
      ),
      {
        'v': 1,
        'cmd_id': id,
        'type': 'TOGGLE_LOAD_CAPABILITY',
        'load_id': 'DO1',
        'action': false,
      },
    );
  });

  test('conditions use bool action/operator and CONn ids', () {
    expect(
      MqttPayloads.setLoadCondition(
        cmdId: id,
        loadId: 'DO1',
        conditionId: 'CON2',
        conditionEnabled: true,
        action: false,
        sensorId: 'RS1',
        valueName: 'Độ ẩm không khí',
        greater: true,
        threshold: 4.5,
      ),
      {
        'v': 1,
        'cmd_id': id,
        'type': 'SET_LOAD_CONDITION',
        'condition_id': 'CON2',
        'condition_enabled': true,
        'load_id': 'DO1',
        'action': false,
        'sensor_id': 'RS1',
        'value_name': 'Độ ẩm không khí',
        'operator': true,
        'threshold': 4.5,
      },
    );
    expect(
      MqttPayloads.addLoadCondition(
        cmdId: id,
        loadId: 'DO1',
        conditionId: 'CON1',
      ),
      {
        'v': 1,
        'cmd_id': id,
        'type': 'ADD_LOAD_CONDITION',
        'load_id': 'DO1',
        'condition_id': 'CON1',
      },
    );
    expect(
      MqttPayloads.toggleLoadCondition(
        cmdId: id,
        loadId: 'DO1',
        conditionId: 'CON1',
        enabled: true,
      ),
      {
        'v': 1,
        'cmd_id': id,
        'type': 'TOGGLE_LOAD_CONDITION',
        'load_id': 'DO1',
        'condition_id': 'CON1',
        'action': true,
      },
    );
    expect(
      MqttPayloads.deleteLoadCondition(
        cmdId: id,
        loadId: 'DO1',
        conditionId: 'CON1',
      ),
      {
        'v': 1,
        'cmd_id': id,
        'type': 'DELETE_LOAD_CONDITION',
        'condition_id': 'CON1',
        'load_id': 'DO1',
      },
    );
    expect(
      () => MqttPayloads.addLoadCondition(
        cmdId: id,
        loadId: 'DO1',
        conditionId: 'CON3',
      ),
      throwsArgumentError,
    );
    expect(
      () => MqttPayloads.setLoadCondition(
        cmdId: id,
        loadId: 'DO1',
        conditionId: 'CON1',
        conditionEnabled: true,
        action: true,
        sensorId: 'sensor_001',
        valueName: 'Nhiệt độ không khí',
        greater: true,
        threshold: 1,
      ),
      throwsArgumentError,
    );
  });

  test('schedulers, including the ADD_LOAD_SCHEDULER type', () {
    expect(
      MqttPayloads.setLoadSchedule(
        cmdId: id,
        loadId: 'DO1',
        schedulerId: 'SHE3',
        schedulerEnabled: true,
        daysMask: 127,
        onTimeUtc: '06:00',
        offTimeUtc: '18:00',
      ),
      {
        'v': 1,
        'cmd_id': id,
        'type': 'SET_LOAD_SCHEDULE',
        'scheduler_id': 'SHE3',
        'load_id': 'DO1',
        'scheduler_enabled': true,
        'days_mask': 127,
        'on_time_utc': '06:00',
        'off_time_utc': '18:00',
      },
    );
    expect(
      MqttPayloads.addLoadScheduler(
        cmdId: id,
        loadId: 'DO1',
        schedulerId: 'SHE1',
      ),
      {
        'v': 1,
        'cmd_id': id,
        'type': 'ADD_LOAD_SCHEDULER',
        'load_id': 'DO1',
        'scheduler_id': 'SHE1',
      },
    );
    expect(
      MqttPayloads.toggleLoadScheduler(
        cmdId: id,
        loadId: 'DO1',
        schedulerId: 'SHE1',
        enabled: false,
      )['type'],
      'TOGGLE_LOAD_SCHEDULER',
    );
    expect(
      MqttPayloads.deleteLoadScheduler(
        cmdId: id,
        loadId: 'DO1',
        schedulerId: 'SHE2',
      ),
      {
        'v': 1,
        'cmd_id': id,
        'type': 'DELETE_LOAD_SCHEDULER',
        'scheduler_id': 'SHE2',
        'load_id': 'DO1',
      },
    );
    expect(
      () => MqttPayloads.setLoadSchedule(
        cmdId: id,
        loadId: 'DO1',
        schedulerId: 'SHE1',
        schedulerEnabled: true,
        daysMask: 128,
        onTimeUtc: '06:00',
        offTimeUtc: '18:00',
      ),
      throwsArgumentError,
    );
    expect(
      () => MqttPayloads.setLoadSchedule(
        cmdId: id,
        loadId: 'DO1',
        schedulerId: 'SHE1',
        schedulerEnabled: true,
        daysMask: 1,
        onTimeUtc: '6:00',
        offTimeUtc: '18:00',
      ),
      throwsArgumentError,
    );
  });

  group('SENSOR_CONFIG', () {
    test('rs485 config contains no calibration data', () {
      expect(
        MqttPayloads.sensorConfig(
          cmdId: id,
          add: true,
          enabled: true,
          sensorId: 'RS1',
          name: 'Cảm biến Oxy',
          slaveId: 1,
        ),
        {
          'v': 1,
          'cmd_id': id,
          'type': 'SENSOR_CONFIG',
          'action': true,
          'enabled': true,
          'interface_type': 'rs485',
          'sensor_id': 'RS1',
          'slave_id': 1,
          'name': 'Cảm biến Oxy',
        },
      );
      expect(
        () => MqttPayloads.sensorConfig(
          cmdId: id,
          add: true,
          enabled: true,
          sensorId: 'RS1',
          name: 'x',
        ),
        throwsArgumentError,
      );
      expect(
        () => MqttPayloads.sensorConfig(
          cmdId: id,
          add: true,
          enabled: true,
          sensorId: 'RS1',
          name: 'x',
          slaveId: 248,
        ),
        throwsArgumentError,
      );
    });

    test('analog and DI sensor configs omit slave_id', () {
      final analog = MqttPayloads.sensorConfig(
        cmdId: id,
        add: false,
        enabled: false,
        sensorId: 'AN1',
        name: 'Dòng',
      );
      expect(analog['interface_type'], 'analog_4_20ma');
      expect(analog['action'], false);
      expect(analog.containsKey('slave_id'), isFalse);

      final di = MqttPayloads.sensorConfig(
        cmdId: id,
        add: true,
        enabled: true,
        sensorId: 'DI3',
        name: 'Phao',
      );
      expect(di['interface_type'], 'di');
      expect(di.containsKey('slave_id'), isFalse);

      expect(
        () => MqttPayloads.sensorConfig(
          cmdId: id,
          add: true,
          enabled: true,
          sensorId: 'AN1',
          name: 'x',
          slaveId: 1,
        ),
        throwsArgumentError,
      );
    });

    test('delete and toggle', () {
      expect(MqttPayloads.deleteSensor(cmdId: id, sensorId: 'RS1'), {
        'v': 1,
        'cmd_id': id,
        'type': 'DELETE_SENSOR',
        'sensor_id': 'RS1',
      });
      expect(
        MqttPayloads.toggleSensorCapability(
          cmdId: id,
          sensorId: 'DI4',
          enabled: true,
        ),
        {
          'v': 1,
          'cmd_id': id,
          'type': 'TOGGLE_SENSOR_CAPABILITY',
          'sensor_id': 'DI4',
          'action': true,
        },
      );
    });
  });

  test('device commands name themselves in type, never in action', () {
    expect(MqttPayloads.setDeviceName(cmdId: id, name: 'Ao nuôi 1'), {
      'v': 1,
      'cmd_id': id,
      'type': 'SET_DEVICE_NAME',
      'name': 'Ao nuôi 1',
    });
    expect(MqttPayloads.getStatus(cmdId: id), {
      'v': 1,
      'cmd_id': id,
      'type': 'GET_STATUS',
    });
    expect(MqttPayloads.getTelemetry(cmdId: id), {
      'v': 1,
      'cmd_id': id,
      'type': 'GET_TELEMETRY',
    });
    expect(MqttPayloads.emergencyStop(cmdId: id), {
      'v': 1,
      'cmd_id': id,
      'type': 'EMERGENCY_STOP',
    });
    expect(
      MqttPayloads.commandName(MqttPayloads.emergencyStop(cmdId: id)),
      'EMERGENCY_STOP',
    );
  });

  test('names are 1..31 UTF-8 bytes without surrounding spaces', () {
    for (final bad in ['', ' x', 'x ', 'ạ' * 11]) {
      expect(
        () => MqttPayloads.setDeviceName(cmdId: id, name: bad),
        throwsArgumentError,
        reason: '"$bad"',
      );
    }
    expect(
      MqttPayloads.setDeviceName(cmdId: id, name: 'ạ' * 10)['name'],
      'ạ' * 10,
    );
  });

  test('delay range is 0..1440 minutes', () {
    expect(
      () => MqttPayloads.setLoadDelay(
        cmdId: id,
        loadId: 'DO1',
        offThenOn: false,
        delayMin: 1441,
        duration: 0,
      ),
      throwsArgumentError,
    );
  });
}

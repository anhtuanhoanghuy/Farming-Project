import 'package:flutter_app/protocol/device_snapshot.dart';
import 'package:flutter_app/protocol/device_telemetry.dart';
import 'package:flutter_app/protocol/mqtt_ack.dart';
import 'package:flutter_app/protocol/mqtt_log.dart';
import 'package:flutter_app/protocol/mqtt_payloads.dart';
import 'package:flutter_app/protocol/mqtt_topics.dart';
import 'package:flutter_app/protocol/port_ids.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/sample_messages.dart';

void main() {
  test('recognizes reserved DI load-feedback names', () {
    expect(PortIds.loadFeedbackLoadId('DO1_feedback'), 'DO1');
    expect(PortIds.loadFeedbackLoadId('DO4_state'), 'DO4');
    expect(PortIds.loadFeedbackLoadId('DO2'), isNull);
    expect(PortIds.loadFeedbackLoadId('DO10_feedback'), isNull);
    expect(PortIds.loadFeedbackLoadId('sensor_DO1_feedback'), isNull);
  });

  test('recognizes reserved load button sensor names', () {
    expect(PortIds.loadButtonLoadId('ON1_button'), 'DO1');
    expect(PortIds.loadButtonLoadId('OFF4_button'), 'DO4');
    expect(PortIds.loadButtonLoadId('ON0_button'), isNull);
    expect(PortIds.loadButtonLoadId('OFF5_button'), isNull);
    expect(PortIds.loadButtonLoadId('sensor_ON1_button'), isNull);
    expect(PortIds.isReservedLoadSensorName('ON2_button'), isTrue);
    expect(PortIds.isReservedLoadSensorName('OFF2_button'), isTrue);
    expect(PortIds.isReservedLoadSensorName('temperature'), isFalse);
  });

  group('ACK', () {
    test('parses a success ACK', () {
      final ack = MqttAck.fromJson({
        'v': 1,
        'cmd_id': 'c1',
        'type': 'ACK',
        'cmd': 'SET_LOAD_STATE',
        'result': 'ok',
        'code': 'OK',
        'boot_id': '361d7646',
        'dup': false,
        'ts': 1791854906000,
      });
      expect(ack.isSuccess, isTrue);
      expect(ack.code, 'OK');
      expect(ack.reason, isNull);
      expect(ack.cmd, 'SET_LOAD_STATE');
      expect(ack.bootId, '361d7646');
      expect(ack.dup, isFalse);
    });

    test('parses an error ACK with code and reason', () {
      final ack = MqttAck.fromJson({
        'v': 1,
        'cmd_id': 'c2',
        'type': 'ACK',
        'result': 'error',
        'code': 'INVALID_VALUE',
        'reason': 'load is disabled',
        'dup': true,
      });
      expect(ack.isSuccess, isFalse);
      expect(ack.dup, isTrue);
      expect(
        ack.errorMessage,
        'ESP32 từ chối: INVALID_VALUE (load is disabled)',
      );
      final error = MqttCommandException.rejected(ack);
      expect('$error', ack.errorMessage);
      expect(error.code, 'INVALID_VALUE');
      expect(error.reason, 'load is disabled');
    });

    test('rejects a malformed ACK', () {
      expect(() => MqttAck.fromJson({'cmd_id': 'c'}), throwsFormatException);
      expect(
        () => MqttAck.fromJson({
          'cmd_id': 'c',
          'type': 'EVENT',
          'result': 'ok',
          'code': 'OK',
        }),
        throwsFormatException,
      );
    });
  });

  group('snapshot', () {
    final snapshot = DeviceSnapshot.tryParse(
      sampleSnapshot(),
      DateTime(2026, 1, 1, 10),
    )!;

    test('device level fields and capabilities', () {
      expect(snapshot.deviceName, 'Device_01');
      expect(snapshot.netInterface, 'WIFI');
      expect(snapshot.bootId, '361d7646');
      expect(snapshot.telemetryIntervalSeconds, 5);
      expect(snapshot.emergencyActive, isFalse);
      expect(snapshot.interlockTripped, isFalse);
      expect(snapshot.capabilities.rs485.ports, ['RS1', 'RS2', 'RS3', 'RS4']);
      expect(snapshot.capabilities.analog.count, 1);
      expect(snapshot.capabilities.digitalInputs.ports, hasLength(4));
      expect(snapshot.capabilities.maxSensorCount, 9);
      expect(snapshot.capabilities.maxLoadCount, 4);
      expect(const DeviceCapabilities().maxSensorCount, isNull);
      expect(const DeviceCapabilities().maxLoadCount, isNull);
      expect(snapshot.portsFor('rs485'), hasLength(4));
      expect(snapshot.freePortsFor('rs485'), ['RS2', 'RS4']);
      expect(snapshot.freePortsFor('di'), ['DI1', 'DI3', 'DI4']);
      expect(snapshot.freePortsFor('analog_4_20ma'), ['AN1']);
    });

    group('telemetry interval command', () {
      test('builds a command with the requested interval', () {
        expect(
          MqttPayloads.setTelemetryInterval(
            cmdId: 'interval-1',
            intervalSeconds: 600,
          ),
          containsPair('type', 'SET_TELEMETRY_INTERVAL'),
        );
        expect(
          MqttPayloads.setTelemetryInterval(
            cmdId: 'interval-2',
            intervalSeconds: 5,
          )['interval_s'],
          5,
        );
      });

      test('rejects values outside the device range', () {
        for (final seconds in [0, 4, 601, -1]) {
          expect(
            () => MqttPayloads.setTelemetryInterval(
              cmdId: 'interval-invalid',
              intervalSeconds: seconds,
            ),
            throwsArgumentError,
          );
        }
      });
    });

    test('only configured sensors are listed', () {
      expect(snapshot.inputs.map((i) => i.portId), ['RS1', 'RS3', 'DI2']);
      final ph = snapshot.input('RS3')!;
      expect(ph.enabled, isFalse);
      expect(ph.valid, isFalse);
      expect(ph.slaveId, 3);
      final di = snapshot.input('DI2')!;
      expect(di.interfaceType, 'di');
      expect(di.slaveId, isNull);
    });

    test('load with 2 conditions, 3 schedulers and an active delay', () {
      final load = snapshot.load('DO1')!;
      expect(load.name, 'Quạt nước 1');
      expect(load.enabled, isTrue);
      expect(load.state, isFalse);
      expect(load.conditions.map((c) => c.conditionId), ['CON1', 'CON2']);
      final con1 = load.condition('CON1')!;
      expect(con1.enabled, isTrue);
      expect(con1.action, isTrue);
      expect(con1.greater, isTrue);
      expect(con1.sensorId, 'RS1');
      expect(con1.valueName, 'Độ ẩm không khí');
      expect(con1.threshold, 4.5);
      expect(load.condition('CON2')!.greater, isFalse);
      expect(load.schedules.map((s) => s.schedulerId), [
        'SHE1',
        'SHE2',
        'SHE3',
      ]);
      final she1 = load.schedule('SHE1')!;
      expect(she1.enabled, isTrue);
      expect(she1.daysMask, 31);
      expect(she1.onTimeUtc, '06:00');
      expect(she1.offTimeUtc, '18:00');

      final delay = load.delay;
      expect(delay.active, isTrue);
      expect(delay.isRunning, isTrue);
      expect(delay.phase, DelayPhase.waitFirst);
      expect(delay.offThenOn, isFalse);
      expect(delay.delayMin, 5);
      expect(delay.duration, 30);
      expect(delay.remainingSeconds, 245);
      expect(delay.startTime, '14:00');
    });

    test('loads without conditions or timers parse as empty', () {
      final load = snapshot.load('DO3')!;
      expect(load.conditions, isEmpty);
      expect(load.schedules, isEmpty);
      expect(load.delay.isRunning, isFalse);
      expect(load.delay.phase, DelayPhase.idle);
      expect(snapshot.load('DO9'), isNull);
    });

    test('emergency, disabled load and sensor free state', () {
      final stopped = DeviceSnapshot.tryParse(
        sampleSnapshot(emergency: true, loadEnabled: false, delayActive: false),
        DateTime(2026),
      )!;
      expect(stopped.emergencyActive, isTrue);
      expect(stopped.load('DO1')!.enabled, isFalse);
      expect(stopped.load('DO1')!.delay.isRunning, isFalse);
    });

    test('reads active network name and address', () {
      final snapshot = DeviceSnapshot.tryParse(
        sampleSnapshot(),
        DateTime(2026),
      )!;
      expect(snapshot.netInterface, 'WIFI');
      expect(snapshot.ssid, 'Farm Wi-Fi');
      expect(snapshot.ipAddress, '192.168.1.20');
    });

    test('falls back to the standard ports when capabilities are missing', () {
      final bare = DeviceSnapshot.tryParse({
        'type': 'SNAPSHOT',
        'loads': <Object?>[],
      }, DateTime(2026))!;
      expect(bare.portsFor('rs485'), ['RS1', 'RS2', 'RS3', 'RS4']);
      expect(bare.portsFor('analog_4_20ma'), ['AN1']);
      expect(bare.portsFor('di'), ['DI1', 'DI2', 'DI3', 'DI4']);
    });

    test('rejects messages that are not snapshots', () {
      expect(
        DeviceSnapshot.tryParse({'type': 'LWT', 'loads': []}, DateTime(2026)),
        isNull,
      );
      expect(
        DeviceSnapshot.tryParse({'type': 'SNAPSHOT'}, DateTime(2026)),
        isNull,
      );
    });
  });

  group('delay countdown anchored at the phone receive time', () {
    final received = DateTime(2026, 1, 1, 10);
    const delay = LoadDelay(
      active: true,
      offThenOn: false,
      phase: DelayPhase.waitFirst,
      remainingSeconds: 245,
    );

    test('remaining = remaining_s - (now - receivedAt)', () {
      expect(
        delay.remainingAt(received, received),
        const Duration(seconds: 245),
      );
      expect(
        delay.remainingAt(received, received.add(const Duration(seconds: 45))),
        const Duration(seconds: 200),
      );
    });

    test('clamps at zero and is zero when not running', () {
      expect(
        delay.remainingAt(received, received.add(const Duration(minutes: 10))),
        Duration.zero,
      );
      expect(const LoadDelay().remainingAt(received, received), Duration.zero);
      expect(
        const LoadDelay(
          active: true,
          phase: DelayPhase.idle,
          remainingSeconds: 9,
        ).remainingAt(received, received),
        Duration.zero,
      );
    });

    test('target state of each phase follows mode', () {
      LoadDelay of(bool offThenOn, DelayPhase phase) => LoadDelay(
        active: true,
        offThenOn: offThenOn,
        phase: phase,
        remainingSeconds: 1,
      );
      // mode false = ON_THEN_OFF: first ON, then OFF.
      expect(of(false, DelayPhase.waitFirst).targetOn, isTrue);
      expect(of(false, DelayPhase.waitSecond).targetOn, isFalse);
      // mode true = OFF_THEN_ON: first OFF, then ON.
      expect(of(true, DelayPhase.waitFirst).targetOn, isFalse);
      expect(of(true, DelayPhase.waitSecond).targetOn, isTrue);
      expect(const LoadDelay().targetOn, isNull);
    });
  });

  group('telemetry', () {
    final telemetry = DeviceTelemetry.tryParse(
      sampleTelemetry(),
      DateTime(2026),
    )!;

    test('device level fields', () {
      expect(telemetry.seq, 142);
      expect(telemetry.bootId, '361d7646');
      expect(telemetry.netInterface, 'ETH');
      expect(telemetry.buffered, isFalse);
      expect(telemetry.errorMask, 0);
      expect(telemetry.inputs.map((i) => i.portId), ['RS1', 'RS3', 'DI2']);
    });

    test('snapshot input announces its metric names', () {
      final input = SensorInput.tryParse({
        'port_id': 'RS3',
        'interface_type': 'RS485',
        'name': 'pH',
        'enabled': true,
        'valid': false,
        'value_names': ['Độ pH', 'Nhiệt độ nước'],
      })!;
      expect(input.valueNames, ['Độ pH', 'Nhiệt độ nước']);
    });

    test('numbers keep the name and unit the ESP32 sent', () {
      final values = telemetry.input('RS1')!.values;
      expect(values.map((v) => (v.name, v.unit, v.display)), [
        ('Nhiệt độ không khí', '°C', '25.1'),
        ('Độ ẩm không khí', '%RH', '60'),
      ]);
    });

    test('digital input values are booleans', () {
      final value = telemetry.input('DI2')!.values.single;
      expect(value.value, isTrue);
      expect(value.display, 'Có');
      expect(
        const TelemetryValue(name: 'n', unit: '', value: false).display,
        'Không',
      );
    });

    test('an invalid sensor has no values', () {
      final ph = telemetry.input('RS3')!;
      expect(ph.valid, isFalse);
      expect(ph.values, isEmpty);
    });

    test('buffered flag and missing input list', () {
      expect(
        DeviceTelemetry.tryParse(
          sampleTelemetry(buffered: true),
          DateTime(2026),
        )!.buffered,
        isTrue,
      );
      expect(DeviceTelemetry.tryParse({'seq': 1}, DateTime(2026)), isNull);
    });

    test('accepts telemetry with no enabled sensors', () {
      final emptyTelemetry = DeviceTelemetry.tryParse({
        'seq': 143,
        'net_interface': 'WIFI',
        'input': <Object>[],
      }, DateTime(2026))!;

      expect(emptyTelemetry.inputs, isEmpty);
      expect(emptyTelemetry.netInterface, 'WIFI');
    });
  });

  group('log lines', () {
    test('TX', () {
      final payload = MqttPayloads.setLoadState(
        cmdId: 'abc',
        loadId: 'DO1',
        on: true,
      );
      final line = MqttLog.tx(payload);
      expect(
        line,
        startsWith('[MQTT] TX cmd=SET_LOAD_STATE cmd_id=abc payload={'),
      );
      expect(line, contains('"load_id":"DO1"'));
      expect(
        MqttLog.tx(MqttPayloads.getStatus(cmdId: 'g1')),
        startsWith('[MQTT] TX cmd=GET_STATUS cmd_id=g1'),
      );
    });

    test('RX ack, snapshot, event, LWT and telemetry', () {
      expect(
        MqttLog.rx(
          deviceId,
          MqttDeviceTopicKind.ack,
          '{"cmd_id":"c","type":"ACK","result":"error","code":"BUSY","reason":"x","dup":false}',
        ),
        '[MQTT] RX ack cmd_id=c result=error code=BUSY reason=x dup=false',
      );
      expect(
        MqttLog.rx(
          deviceId,
          MqttDeviceTopicKind.status,
          '{"type":"SNAPSHOT","boot_id":"b","loads":[{},{}],"emergency":{"active":true}}',
        ),
        contains('RX snapshot'),
      );
      expect(
        MqttLog.rx(
          deviceId,
          MqttDeviceTopicKind.status,
          '{"type":"EVENT","event":"LOAD_CHANGED","load_id":"DO1"}',
        ),
        contains('RX event'),
      );
      expect(
        MqttLog.rx(
          deviceId,
          MqttDeviceTopicKind.status,
          '{"type":"LWT","state":"offline"}',
        ),
        contains('LWT'),
      );
      expect(
        MqttLog.rx(
          deviceId,
          MqttDeviceTopicKind.telemetry,
          '{"seq":7,"input":[{}]}',
        ),
        contains('RX telemetry device=$deviceId seq=7 inputs=1'),
      );
      expect(
        MqttLog.rx(deviceId, MqttDeviceTopicKind.ack, 'nope'),
        contains('invalid JSON'),
      );
    });
  });
}

import 'dart:convert';

import 'package:flutter_app/protocol/mqtt_ack.dart';
import 'package:flutter_app/protocol/mqtt_payloads.dart';
import 'package:flutter_app/protocol/mqtt_topics.dart';
import 'package:flutter_app/services/mqtt_session_manager.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/sample_messages.dart';

MqttDeviceMessage _message(
  MqttDeviceTopicKind kind,
  Map<String, Object?> body, {
  String device = deviceId,
}) => MqttDeviceMessage(
  deviceId: device,
  topic: 'v1/u/devices/$device/${kind.name}',
  kind: kind,
  payload: jsonEncode(body),
  receivedAt: DateTime.now(),
);

Map<String, Object?> _ack(String cmdId, {String? code, String? reason}) => {
  'v': 1,
  'cmd_id': cmdId,
  'type': 'ACK',
  'result': code == null ? 'ok' : 'error',
  'code': code ?? 'OK',
  'reason': ?reason,
  'boot_id': '361d7646',
  'dup': false,
};

void main() {
  test('commands go out as UTF-8 so names with diacritics reach the ESP32', () {
    final payload = MqttPayloads.setLoadName(
      cmdId: 'c1',
      loadId: 'DO1',
      name: 'Quạt nước số 1',
    );
    final bytes = MqttSessionManager.jsonPayload(jsonEncode(payload)).payload!;
    expect(utf8.decode(bytes), jsonEncode(payload));
    expect(
      (jsonDecode(utf8.decode(bytes)) as Map)['name'],
      'Quạt nước số 1',
    );
  });

  late MqttSessionManager manager;
  late List<Map<String, Object?>> sent;

  setUp(() {
    sent = [];
    manager = MqttSessionManager.test(
      devices: {deviceId},
      publisher: (id, payload) async => sent.add(payload),
    );
  });

  tearDown(() => manager.dispose());

  test('an ok ACK with the same cmd_id completes the command', () async {
    final payload = MqttPayloads.setLoadState(
      cmdId: 'c1',
      loadId: 'DO1',
      on: true,
    );
    final result = manager.publishCommandAndWaitForAck(deviceId, payload);
    await pumpEventQueue();
    expect(sent.single, payload);

    manager.dispatch(_message(MqttDeviceTopicKind.ack, _ack('other')));
    manager.dispatch(_message(MqttDeviceTopicKind.ack, _ack('c1')));
    final ack = await result;
    expect(ack.isSuccess, isTrue);
    expect(ack.code, 'OK');
  });

  test('an error ACK throws a Vietnamese message with code and reason', () async {
    final result = manager.publishCommandAndWaitForAck(
      deviceId,
      MqttPayloads.setLoadState(cmdId: 'c2', loadId: 'DO1', on: true),
    );
    await pumpEventQueue();
    manager.dispatch(
      _message(
        MqttDeviceTopicKind.ack,
        _ack('c2', code: 'INVALID_VALUE', reason: 'load is disabled'),
      ),
    );
    await expectLater(
      result,
      throwsA(
        isA<MqttCommandException>()
            .having(
              (e) => e.message,
              'message',
              'ESP32 từ chối: INVALID_VALUE (load is disabled)',
            )
            .having((e) => e.ack?.isSuccess, 'ack.isSuccess', false),
      ),
    );
  });

  test('no ACK in time fails with a clear message', () async {
    await expectLater(
      manager.publishCommandAndWaitForAck(
        deviceId,
        MqttPayloads.emergencyStop(cmdId: 'c3'),
        timeout: const Duration(milliseconds: 20),
      ),
      throwsA(
        isA<MqttCommandException>().having(
          (e) => e.message,
          'message',
          contains('ESP32 không phản hồi lệnh EMERGENCY_STOP'),
        ),
      ),
    );
  });

  test('an ACK arriving after the timeout is ignored', () async {
    await expectLater(
      manager.publishCommandAndWaitForAck(
        deviceId,
        MqttPayloads.getStatus(cmdId: 'c4'),
        timeout: const Duration(milliseconds: 10),
      ),
      throwsA(isA<MqttCommandException>()),
    );
    manager.dispatch(_message(MqttDeviceTopicKind.ack, _ack('c4')));
  });

  test('messages are forwarded to listeners', () async {
    final received = <MqttDeviceMessage>[];
    final subscription = manager.messages.listen(received.add);
    manager.dispatch(_message(MqttDeviceTopicKind.telemetry, sampleTelemetry()));
    await pumpEventQueue();
    await subscription.cancel();
    expect(received.single.kind, MqttDeviceTopicKind.telemetry);
  });

  test('the latest snapshot is kept until the LWT', () {
    expect(manager.latestSnapshot(deviceId), isNull);
    manager.dispatch(_message(MqttDeviceTopicKind.status, sampleSnapshot()));
    expect(manager.latestSnapshot(deviceId), isNotNull);

    manager.dispatch(
      _message(MqttDeviceTopicKind.status, {
        'v': 1,
        'type': 'EVENT',
        'event': 'LOAD_CHANGED',
        'load_id': 'DO1',
        'state': true,
        'source': 'MANUAL',
      }),
    );
    expect(manager.latestSnapshot(deviceId), isNotNull);

    manager.dispatch(
      _message(MqttDeviceTopicKind.status, {
        'v': 1,
        'type': 'LWT',
        'state': 'offline',
        'boot_id': '361d7646',
      }),
    );
    expect(manager.latestSnapshot(deviceId), isNull);
  });
}

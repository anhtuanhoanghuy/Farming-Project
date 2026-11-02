import 'dart:convert';

import 'package:flutter_app/protocol/mqtt_ack.dart';
import 'package:flutter_app/protocol/mqtt_topics.dart';
import 'package:flutter_app/services/mqtt_session_manager.dart';
import 'package:flutter_app/services/traffic_log.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _ownDevice = 'aabbccddeeff';
const _foreignDevice = '112233445566';

void main() {
  late MqttSessionManager manager;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TrafficLog.instance.clear();
    manager = MqttSessionManager.test(
      userId: 'admin',
      devices: {_ownDevice, _foreignDevice},
      deviceOwners: {_foreignDevice: 'owner'},
      publisher: (_, _) async {},
    );
  });

  tearDown(() {
    manager.dispose();
    TrafficLog.instance.clear();
  });

  test(
    'subscriptions and commands use each device owner, not the admin',
    () async {
      final topics = manager.topicsForDevice(_foreignDevice);
      expect(topics.subscriptions, [
        'v1/owner/devices/$_foreignDevice/telemetry',
        'v1/owner/devices/$_foreignDevice/ack',
        'v1/owner/devices/$_foreignDevice/status',
      ]);
      expect(
        manager.topicsForDevice(_ownDevice).commands,
        'v1/admin/devices/$_ownDevice/commands',
      );
      await manager.publishCommand(_foreignDevice, {'type': 'GET_STATUS'});
      expect(
        TrafficLog.instance.entries.single.topic,
        'v1/owner/devices/$_foreignDevice/commands',
      );
    },
  );

  test(
    'foreign telemetry, snapshots and ACKs follow the normal receive path',
    () async {
      final messages = <MqttDeviceMessage>[];
      final subscription = manager.messages.listen(messages.add);
      for (final kind in ['telemetry', 'status']) {
        expect(
          manager.receiveTopic(
            'v1/owner/devices/$_foreignDevice/$kind',
            jsonEncode({'type': kind == 'status' ? 'SNAPSHOT' : 'TELEMETRY'}),
          ),
          isTrue,
        );
      }
      final command = manager.publishCommandAndWaitForAck(_foreignDevice, {
        'cmd_id': 'admin-command',
        'type': 'GET_STATUS',
      });
      manager.receiveTopic(
        'v1/owner/devices/$_foreignDevice/ack',
        jsonEncode({
          'v': 1,
          'type': 'ACK',
          'cmd_id': 'admin-command',
          'result': 'ok',
          'code': 'OK',
          'boot_id': 'boot',
          'dup': false,
        }),
      );
      expect((await command).isSuccess, isTrue);
      await pumpEventQueue();
      expect(messages.map((m) => m.kind), [
        MqttDeviceTopicKind.telemetry,
        MqttDeviceTopicKind.status,
        MqttDeviceTopicKind.ack,
      ]);
      expect(messages.every((m) => m.deviceId == _foreignDevice), isTrue);
      expect(manager.latestSnapshot(_foreignDevice), isNotNull);
      await subscription.cancel();
    },
  );

  test('wrong owners, unknown devices and malformed topics are rejected', () {
    for (final topic in [
      'v1/admin/devices/$_foreignDevice/status',
      'v1/stranger/devices/$_ownDevice/status',
      'v1/owner/devices/ffffffffffff/status',
      'v1/owner/devices/$_foreignDevice/status/extra',
      'v1/owner/devices/$_foreignDevice/unknown',
    ]) {
      expect(manager.receiveTopic(topic, '{"type":"SNAPSHOT"}'), isFalse);
    }
    expect(manager.latestSnapshot(_foreignDevice), isNull);
    expect(TrafficLog.instance.entries, isEmpty);
  });

  test(
    'foreign registrations are never persisted as admin-owned devices',
    () async {
      await manager.addDevice(
        _foreignDevice,
        ownerUserId: 'owner',
        name: 'Other',
      );
      await manager.addDevice(_ownDevice, name: 'Mine');
      // Force list persistence with a newly registered owned device.
      await manager.addDevice('abcdef123456', name: 'Another');
      final preferences = await SharedPreferences.getInstance();
      expect(
        preferences.getStringList('mqtt.devices.admin'),
        [_ownDevice, 'abcdef123456']..sort(),
      );
      expect(
        preferences.getString('mqtt.device_name.admin.$_foreignDevice'),
        isNull,
      );
      expect(
        preferences.getString('mqtt.device_name.admin.$_ownDevice'),
        'Mine',
      );
    },
  );

  test(
    'ownership changes replace both incoming and outgoing routing',
    () async {
      manager.receiveTopic(
        'v1/owner/devices/$_foreignDevice/status',
        '{"type":"SNAPSHOT"}',
      );
      await manager.addDevice(_foreignDevice, ownerUserId: 'new-owner');
      expect(manager.latestSnapshot(_foreignDevice), isNull);
      expect(
        manager.receiveTopic(
          'v1/owner/devices/$_foreignDevice/status',
          '{"type":"SNAPSHOT"}',
        ),
        isFalse,
      );
      expect(
        manager.receiveTopic(
          'v1/new-owner/devices/$_foreignDevice/status',
          '{"type":"SNAPSHOT"}',
        ),
        isTrue,
      );
      await manager.publishCommand(_foreignDevice, {'type': 'GET_STATUS'});
      expect(
        TrafficLog.instance.entries.last.topic,
        'v1/new-owner/devices/$_foreignDevice/commands',
      );
    },
  );

  test(
    'removal and sign-out reject further foreign traffic and commands',
    () async {
      await manager.removeDevice(_foreignDevice);
      expect(
        manager.receiveTopic(
          'v1/owner/devices/$_foreignDevice/status',
          '{"type":"SNAPSHOT"}',
        ),
        isFalse,
      );
      await expectLater(
        manager.publishCommand(_foreignDevice, {'type': 'GET_STATUS'}),
        throwsA(isA<MqttCommandException>()),
      );
      await manager.stop();
      expect(manager.deviceIds, isEmpty);
      expect(manager.ownerUserId(_ownDevice), isNull);
      expect(
        manager.receiveTopic(
          'v1/admin/devices/$_ownDevice/status',
          '{"type":"SNAPSHOT"}',
        ),
        isFalse,
      );
    },
  );

  test(
    'stopping during registration cannot restore a foreign device',
    () async {
      final registration = manager.addDevice(
        'abcdef123456',
        ownerUserId: 'owner',
      );
      await manager.stop();
      await registration;
      expect(manager.deviceIds, isEmpty);
      expect(manager.ownerUserId('abcdef123456'), isNull);
    },
  );
}

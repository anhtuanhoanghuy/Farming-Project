import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_app/protocol/mqtt_topics.dart';
import 'package:flutter_app/services/load_sync.dart';
import 'package:flutter_app/services/mqtt_session_manager.dart';
import 'package:flutter_app/state/device_presence.dart';
import 'package:flutter_app/state/device_state.dart';
import 'package:flutter_app/state/load_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/sample_messages.dart';

class _Connection extends ChangeNotifier {
  bool connected = false;
  void set(bool value) {
    connected = value;
    notifyListeners();
  }
}

MqttDeviceMessage _message(
  MqttDeviceTopicKind kind,
  Map<String, Object?> body, {
  DateTime? at,
  String device = deviceId,
}) => MqttDeviceMessage(
  deviceId: device,
  topic: 'v1/u/devices/$device/${kind.name}',
  kind: kind,
  payload: jsonEncode(body),
  receivedAt: at ?? DateTime.now(),
);

MqttDeviceMessage _status(Map<String, Object?> body, {DateTime? at}) =>
    _message(MqttDeviceTopicKind.status, body, at: at);

void main() {
  group('DevicePresence follows status, telemetry, and LWT', () {
    test(
      'telemetry confirms online, silence waits, and LWT marks offline immediately',
      () async {
        final presence = DevicePresence(
          presenceSilenceTimeout: const Duration(milliseconds: 10),
        );
        expect(presence.isOnline(deviceId), isNull);
        presence.handleMessage(_status(sampleSnapshot()));
        expect(presence.isOnline(deviceId), isTrue);
        expect(presence.isOnline('112233445566'), isNull);
        presence.handleMessage(
          _message(MqttDeviceTopicKind.telemetry, sampleTelemetry()),
        );
        expect(presence.isOnline(deviceId), isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(presence.isOnline(deviceId), isNull);
        presence.handleMessage(
          _message(MqttDeviceTopicKind.telemetry, sampleTelemetry()),
        );
        expect(presence.isOnline(deviceId), isTrue);
        presence.handleMessage(
          _status({'v': 1, 'type': 'LWT', 'state': 'offline', 'boot_id': 'b'}),
        );
        expect(presence.isOnline(deviceId), isFalse);
      },
    );

    test('GET_STATUS is polled immediately and every 15 seconds', () async {
      final connection = ValueNotifier(false);
      final published = <Map<String, Object?>>[];
      final presence = DevicePresence(
        messages: const Stream.empty(),
        connection: connection,
        isConnected: () => connection.value,
        publishCommand: (device, payload) async => published.add(payload),
        deviceIds: () => {deviceId},
        statusPollInterval: const Duration(milliseconds: 20),
      )..start();
      expect(published, isEmpty);

      connection.value = true;
      await Future<void>.delayed(const Duration(milliseconds: 1));
      expect(published.single['type'], 'GET_STATUS');
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(published.length, greaterThanOrEqualTo(2));
      expect(
        published.every((payload) => payload['type'] == 'GET_STATUS'),
        isTrue,
      );

      connection.value = false;
      final countWhenDisconnected = published.length;
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(published.length, countWhenDisconnected);
      presence.dispose();
      connection.dispose();
    });

    test('events do not change presence', () {
      final presence = DevicePresence();
      presence.handleMessage(_status({'type': 'EVENT', 'event': 'LOW_HEAP'}));
      expect(presence.isOnline(deviceId), isNull);
    });

    test('losing the app MQTT connection makes presence unknown', () {
      final connection = ValueNotifier(0);
      var connected = true;
      final presence = DevicePresence(
        messages: const Stream.empty(),
        connection: connection,
        isConnected: () => connected,
        deviceIds: () => const {},
        statusPollInterval: const Duration(days: 1),
      )..start();
      presence.handleMessage(_status(sampleSnapshot()));
      presence.handleMessage(
        _message(MqttDeviceTopicKind.telemetry, sampleTelemetry()),
      );
      expect(presence.isOnline(deviceId), isTrue);
      connected = false;
      connection.value++;
      expect(presence.isOnline(deviceId), isNull);
      presence.dispose();
      connection.dispose();
    });
  });

  group('LoadSync mirrors the ESP32', () {
    late StreamController<MqttDeviceMessage> stream;
    late _Connection connection;
    late List<Map<String, Object?>> published;
    late DeviceState state;
    late DevicePresence presence;
    late LoadSync sync;
    MqttDeviceMessage? cached;

    LoadSync build() => LoadSync(
      messages: stream.stream,
      publish: (id, payload) async => published.add(payload),
      isConnected: () => connection.connected,
      connection: connection,
      state: state,
      presence: presence,
      latestSnapshot: (_) => cached,
      statusRetryDelay: Duration.zero,
    );

    setUp(() {
      stream = StreamController<MqttDeviceMessage>.broadcast(sync: true);
      connection = _Connection();
      published = [];
      state = DeviceState();
      presence = DevicePresence(
        messages: const Stream.empty(),
        connection: connection,
        isConnected: () => connection.connected,
      );
      cached = null;
      sync = build();
      for (final load in LoadController.loads) {
        load.cancelDelay();
      }
    });

    tearDown(() async {
      sync.detach();
      for (final load in LoadController.loads) {
        load
          ..cancelDelay()
          ..setEnabled(true);
      }
      await stream.close();
    });

    test(
      'attach requests the latest status and telemetry immediately',
      () async {
        connection.connected = true;
        final load = LoadController.loads.first..setOn(true);
        await sync.attach(deviceId);
        expect(published.map((payload) => payload['type']), [
          'GET_STATUS',
          'GET_TELEMETRY',
        ]);
        expect(
          published.every((payload) => !payload.containsKey('action')),
          isTrue,
        );
        expect(load.stateKnown, isFalse);
      },
    );

    test('attach shows the snapshot the app already received', () async {
      cached = _status(sampleSnapshot());
      await sync.attach(deviceId);
      expect(state.snapshot, isNotNull);
      final load = LoadController.loads.first;
      expect(load.stateKnown, isTrue);
      expect(load.name, 'Quạt nước 1');
      expect(load.delayActive, isTrue);
    });

    test('snapshot sets state, name, permission and the countdown', () async {
      await sync.attach(deviceId);
      stream.add(_status(sampleSnapshot()));
      final first = LoadController.loads[0];
      expect(first.isOn, isFalse);
      expect(first.enabled, isTrue);
      expect(first.delayActive, isTrue);
      expect(first.delayTargetOn, isTrue);
      expect(first.delayRemaining.inSeconds, inInclusiveRange(243, 245));
      expect(LoadController.loads[1].isOn, isTrue);
      expect(LoadController.loads[1].delayActive, isFalse);
      expect(state.snapshot!.load('DO1')!.conditions, hasLength(2));
    });

    test('countdown is anchored at the receive time of the snapshot', () async {
      await sync.attach(deviceId);
      final received = DateTime.now().subtract(const Duration(seconds: 45));
      stream.add(_status(sampleSnapshot(), at: received));
      expect(
        LoadController.loads.first.delayRemaining.inSeconds,
        inInclusiveRange(199, 201),
      );
    });

    test('a new snapshot re-anchors or stops the countdown', () async {
      await sync.attach(deviceId);
      stream.add(_status(sampleSnapshot()));
      final load = LoadController.loads.first;
      expect(load.delayActive, isTrue);
      stream.add(_status(sampleSnapshot(delayActive: false)));
      expect(load.delayActive, isFalse);
      expect(load.delayCountdown, '00:00');
    });

    test('LOAD_CHANGED and EMERGENCY_STOP events', () async {
      await sync.attach(deviceId);
      stream.add(_status(sampleSnapshot()));
      stream.add(
        _status({
          'v': 1,
          'type': 'EVENT',
          'event': 'LOAD_CHANGED',
          'load_id': 'DO1',
          'state': true,
          'source': 'SCHEDULE',
        }),
      );
      expect(LoadController.loads[0].isOn, isTrue);

      stream.add(_status({'v': 1, 'type': 'EVENT', 'event': 'EMERGENCY_STOP'}));
      for (final load in LoadController.loads) {
        expect(load.isOn, isFalse);
        expect(load.delayActive, isFalse);
        // Loads stay enabled: only sensors are disabled.
        expect(load.enabled, isTrue);
      }
    });

    test('telemetry keeps the values and the network', () async {
      await sync.attach(deviceId);
      stream.add(_message(MqttDeviceTopicKind.telemetry, sampleTelemetry()));
      expect(state.reading('RS1')!.values, hasLength(2));
      expect(state.internetMethod, 'ETH');
      expect(state.reading('RS2'), isNull);
    });

    test('feedback DI telemetry synchronizes the associated load', () async {
      await sync.attach(deviceId);
      stream.add(
        _message(MqttDeviceTopicKind.telemetry, {
          'input': [
            {
              'interface_type': 'di',
              'port_id': 'DI1',
              'name': 'DO1_feedback',
              'valid': true,
              'values': [
                {'name': 'Trạng thái', 'unit': '', 'value': true},
              ],
            },
          ],
        }),
      );
      expect(LoadController.loads[0].isOn, isTrue);
      expect(LoadController.loads[0].stateKnown, isTrue);
    });

    test('buffered telemetry is not shown as live', () async {
      await sync.attach(deviceId);
      stream.add(
        _message(
          MqttDeviceTopicKind.telemetry,
          sampleTelemetry(buffered: true),
        ),
      );
      expect(state.telemetry, isNull);
    });

    test('the snapshot gives the network until telemetry arrives', () async {
      await sync.attach(deviceId);
      stream.add(_status(sampleSnapshot()));
      expect(state.internetMethod, 'WIFI');
    });

    test('messages of another device are ignored', () async {
      await sync.attach(deviceId);
      stream.add(
        _message(
          MqttDeviceTopicKind.status,
          sampleSnapshot(),
          device: '112233445566',
        ),
      );
      expect(state.snapshot, isNull);
    });

    test('device going offline makes everything unknown', () async {
      await sync.attach(deviceId);
      stream.add(_status(sampleSnapshot()));
      stream.add(_message(MqttDeviceTopicKind.telemetry, sampleTelemetry()));
      presence.handleMessage(_status(sampleSnapshot()));
      expect(state.snapshot, isNotNull);

      presence.handleMessage(
        _status({'v': 1, 'type': 'LWT', 'state': 'offline'}),
      );
      expect(state.snapshot, isNull);
      expect(state.telemetry, isNull);
      expect(LoadController.loads.first.stateKnown, isFalse);
      expect(LoadController.loads.first.delayActive, isFalse);
    });

    test('reconnecting MQTT requests a fresh snapshot', () async {
      await sync.attach(deviceId);
      expect(published, isEmpty);
      connection.set(true);
      await pumpEventQueue();
      expect(published.map((payload) => payload['type']), [
        'GET_STATUS',
        'GET_TELEMETRY',
      ]);
    });

    test('a local countdown reaching zero requests a fresh snapshot', () async {
      connection.connected = true;
      await sync.attach(deviceId);
      published.clear();
      final soon = DateTime.now().subtract(const Duration(seconds: 244));
      stream.add(_status(sampleSnapshot(), at: soon));
      await Future<void>.delayed(const Duration(milliseconds: 2100));
      expect(published.where((p) => p['type'] == 'GET_STATUS'), isNotEmpty);
      expect(LoadController.loads.first.delayRemaining, Duration.zero);
    });
  });
}

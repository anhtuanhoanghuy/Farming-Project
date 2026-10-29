import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_app/protocol/device_errors.dart';
import 'package:flutter_app/protocol/device_snapshot.dart';
import 'package:flutter_app/protocol/mqtt_payloads.dart';
import 'package:flutter_app/protocol/mqtt_topics.dart';
import 'package:flutter_app/screens/console_screen.dart';
import 'package:flutter_app/screens/diagnostics_screen.dart';
import 'package:flutter_app/services/device_repository.dart';
import 'package:flutter_app/services/mqtt_session_manager.dart';
import 'package:flutter_app/services/traffic_log.dart';
import 'package:flutter_app/state/developer_access_controller.dart';
import 'package:flutter_app/state/device_health.dart';
import 'package:flutter_app/state/device_state.dart';
import 'package:flutter_app/theme/app_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/sample_messages.dart';

Widget _wrap(Widget child) => MaterialApp(theme: AppTheme.light, home: child);

DeviceRepository _repository() => DeviceRepository(
  fetchRows: (_) async => [
    {
      'id': '123e4567-e89b-12d3-a456-426614174000',
      'user_id': 'u1',
      'mac_address': deviceId,
      'name': 'Ao nuôi A1',
      'max_sensor_count': 4,
      'max_load_count': 4,
    },
  ],
  readCache: (_) async => null,
  writeCache: (_, _) async {},
  syncMqtt: (_, _) async {},
  currentUserId: () => 'u1',
);

void main() {
  group('TrafficLog', () {
    late TrafficLog log;

    setUp(() => log = TrafficLog(capacity: 10, telemetryCapacity: 3));

    test('classifies commands, ACKs, status and events', () {
      log.addTx(
        deviceId,
        'commands',
        MqttPayloads.setLoadState(cmdId: 'c1', loadId: 'DO1', on: true),
      );
      log.addTx(
        deviceId,
        'commands',
        MqttPayloads.deleteSensor(cmdId: 'c2', sensorId: 'RS1'),
      );
      log.addRx(
        deviceId,
        'ack',
        MqttDeviceTopicKind.ack,
        '{"type":"ACK","cmd":"SET_LOAD_STATE","result":"error",'
            '"code":"BUSY","reason":"locked"}',
      );
      log.addRx(
        deviceId,
        'status',
        MqttDeviceTopicKind.status,
        '{"type":"EVENT","event":"LOAD_CHANGED","load_id":"DO1","state":true}',
      );
      log.addRx(
        deviceId,
        'status',
        MqttDeviceTopicKind.status,
        '{"type":"LWT","state":"offline"}',
      );

      expect(log.entries.map((e) => e.type), [
        'Command',
        'Config',
        'ACK',
        'Event',
        'Status',
      ]);
      expect(log.entries[0].direction, 'TX');
      expect(log.entries[0].summary, contains('SET_LOAD_STATE'));
      expect(log.entries[2].summary, contains('LỖI BUSY'));
      expect(log.entries[2].summary, contains('locked'));
      expect(log.entries[3].summary, contains('LOAD_CHANGED'));
    });

    test('keeps a payload that is not JSON as raw text', () {
      log.addRx(deviceId, 'status', MqttDeviceTopicKind.status, 'oops');
      expect(log.entries.single.payload, isNull);
      expect(log.entries.single.prettyPayload, 'oops');
    });

    test('telemetry cannot push out the other entries', () {
      log.addTx(deviceId, 'commands', MqttPayloads.getStatus(cmdId: 'c'));
      for (var i = 0; i < 8; i++) {
        log.addRx(
          deviceId,
          'telemetry',
          MqttDeviceTopicKind.telemetry,
          '{"seq":$i,"input":[],"net_interface":"WIFI"}',
        );
      }
      final telemetry = log.entries.where((e) => e.type == 'Telemetry');
      expect(telemetry, hasLength(3));
      expect(telemetry.last.summary, contains('seq=7'));
      expect(log.entries.where((e) => e.type == 'Command'), hasLength(1));
    });

    test('is limited to its capacity and cleared per device', () {
      for (var i = 0; i < 15; i++) {
        log.addTx(
          i.isEven ? deviceId : 'other',
          'commands',
          MqttPayloads.getStatus(cmdId: 'c$i'),
        );
      }
      expect(log.entries, hasLength(10));
      log.clear(deviceId);
      expect(log.entries.every((e) => e.deviceId == 'other'), isTrue);
      expect(log.entriesOf(deviceId), isEmpty);
    });
  });

  group('DeviceError', () {
    test('names every bit of the mask in order', () {
      final errors = DeviceError.fromMask((1 << 5) | (1 << 8) | (1 << 11));
      expect(errors.map((e) => e.code), [
        'SYS_ERR_ETH_INIT',
        'SYS_ERR_LOAD_OUTPUT_DO1',
        'SYS_ERR_LOAD_OUTPUT_DO4',
      ]);
      expect(DeviceError.fromMask(0), isEmpty);
    });

    test('an unknown bit is still reported', () {
      expect(DeviceError.fromMask(1 << 12).single.code, 'SYS_ERR_BIT_12');
    });
  });

  test('the snapshot carries heap, MQTT statistics and error names', () {
    final json = sampleSnapshot();
    json['errors'] = {
      'code_mask': 2,
      'messages': ['SYS_ERR_NET_LOST'],
    };
    json['mqtt'] = {
      'reconnects': 3,
      'rx_rejected': 1,
      'tx_fail': 2,
      'telemetry_dropped': 4,
    };
    final snapshot = DeviceSnapshot.tryParse(json, DateTime(2026))!;
    expect(snapshot.errorMask, 2);
    expect(snapshot.errorMessages, ['SYS_ERR_NET_LOST']);
    expect(snapshot.heapFree, 215000);
    expect(snapshot.heapMinFree, 198000);
    expect(snapshot.mqttReconnects, 3);
    expect(snapshot.mqttRxRejected, 1);
    expect(snapshot.mqttTxFail, 2);
    expect(snapshot.telemetryDropped, 4);
  });

  test('uptime reads as days, hours, minutes or seconds', () {
    expect(formatUptime(42 * 1000), '42 giây');
    expect(formatUptime((5 * 60 + 7) * 1000), '5 phút 7 giây');
    expect(formatUptime((3 * 3600 + 12 * 60) * 1000), '3 giờ 12 phút');
    expect(formatUptime((2 * 86400 + 5 * 3600) * 1000), '2 ngày 5 giờ');
  });

  group('DeviceHealth', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Map<String, Object?> snapshot({
      int mask = 0,
      bool emergency = false,
      bool interlock = false,
      int? ts,
    }) => {
      'type': 'SNAPSHOT',
      'ts': ?ts,
      'errors': {'code_mask': mask},
      'emergency': {'active': emergency},
      'interlock': {'tripped': interlock},
    };

    test('logs raised and cleared errors once, with their cause', () async {
      final health = DeviceHealth();
      await health.observe(
        deviceId,
        snapshot(mask: 3),
        DateTime(2026, 10, 14, 9),
      );
      expect(health.hasErrors(deviceId), isTrue);
      var log = health.history(deviceId);
      expect(log.map((e) => e.code).toSet(), {
        'SYS_ERR_MODBUS_TIMEOUT',
        'SYS_ERR_NET_LOST',
      });
      expect(log.every((e) => e.kind == HealthKind.errorRaised), isTrue);
      expect(log.first.message, contains('Nguyên nhân'));

      // The same state again adds nothing.
      await health.observe(
        deviceId,
        snapshot(mask: 3),
        DateTime(2026, 10, 14, 9, 1),
      );
      expect(health.history(deviceId), hasLength(2));

      // One error goes away.
      await health.observe(
        deviceId,
        snapshot(mask: 1),
        DateTime(2026, 10, 14, 9, 2),
      );
      log = health.history(deviceId);
      expect(log, hasLength(3));
      expect(log.first.kind, HealthKind.errorCleared);
      expect(log.first.code, 'SYS_ERR_NET_LOST');
      expect(health.maskOf(deviceId), 1);

      await health.observe(deviceId, snapshot(), DateTime(2026, 10, 14, 9, 3));
      expect(health.hasErrors(deviceId), isFalse);
    });

    test('logs an emergency stop and its end', () async {
      final health = DeviceHealth();
      await health.observe(deviceId, {
        'type': 'EVENT',
        'event': 'EMERGENCY_STOP',
        'loads_off': 2,
      }, DateTime(2026, 10, 14, 9));
      // The snapshot that follows says the same: no second line.
      await health.observe(
        deviceId,
        snapshot(emergency: true),
        DateTime(2026, 10, 14, 9),
      );
      expect(health.history(deviceId), hasLength(1));
      expect(health.history(deviceId).single.kind, HealthKind.emergency);
      // An emergency is not an error: no "!" on the device list.
      expect(health.hasErrors(deviceId), isFalse);

      await health.observe(deviceId, snapshot(), DateTime(2026, 10, 14, 9, 30));
      expect(health.history(deviceId).first.kind, HealthKind.emergencyCleared);
    });

    test('every emergency stop is logged, even when already stopped', () async {
      final health = DeviceHealth();
      for (var i = 0; i < 2; i++) {
        await health.observe(deviceId, {
          'type': 'EVENT',
          'event': 'EMERGENCY_STOP',
        }, DateTime(2026, 10, 14, 9, i));
      }
      expect(
        health.history(deviceId).where((e) => e.kind == HealthKind.emergency),
        hasLength(2),
      );
    });

    test('follows ERRORS_CHANGED events and uses the device time', () async {
      final health = DeviceHealth();
      final ts = DateTime.utc(2026, 10, 14, 2).millisecondsSinceEpoch;
      await health.observe(deviceId, {
        'type': 'EVENT',
        'event': 'ERRORS_CHANGED',
        'code_mask': 4,
        'ts': ts,
      }, DateTime(2020));
      final entry = health.history(deviceId).single;
      expect(entry.code, 'SYS_ERR_MQTT_BROKER');
      expect(entry.time.millisecondsSinceEpoch, ts);
    });

    test('keeps only the last 100 entries', () async {
      final health = DeviceHealth();
      for (var i = 0; i < 130; i++) {
        await health.observe(
          deviceId,
          snapshot(mask: i.isEven ? 1 : 0),
          DateTime(2026, 10, 14, 9, 0, i),
        );
      }
      final log = health.history(deviceId);
      expect(log, hasLength(DeviceHealth.maxEntries));
      // Newest first; the oldest ones were dropped.
      expect(log.first.time, DateTime(2026, 10, 14, 9, 0, 129));
      expect(log.last.time, DateTime(2026, 10, 14, 9, 0, 30));
    });

    test('survives a restart without logging the same state twice', () async {
      final first = DeviceHealth();
      await first.observe(
        deviceId,
        snapshot(mask: 1),
        DateTime(2026, 10, 14, 9),
      );

      final second = DeviceHealth();
      await second.load(deviceId);
      expect(second.history(deviceId), hasLength(1));
      expect(second.hasErrors(deviceId), isTrue);
      await second.observe(
        deviceId,
        snapshot(mask: 1),
        DateTime(2026, 10, 14, 10),
      );
      expect(second.history(deviceId), hasLength(1));
    });

    test('deleting a device removes its stored health state only', () async {
      const otherDeviceId = '112233445566';
      final health = DeviceHealth();
      final time = DateTime(2026, 10, 14, 9);
      await health.observe(deviceId, snapshot(mask: 1), time);
      await health.observe(otherDeviceId, snapshot(mask: 2), time);

      await health.deleteDevice(deviceId);

      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getString('device_health.$deviceId'), isNull);
      expect(health.history(deviceId), isEmpty);
      expect(health.hasErrors(deviceId), isFalse);
      expect(health.history(otherDeviceId), hasLength(1));
      expect(preferences.getString('device_health.$otherDeviceId'), isNotNull);
    });

    test('reads the status topic of a device', () async {
      final controller = StreamController<MqttDeviceMessage>.broadcast();
      final health = DeviceHealth(messages: controller.stream)..start();
      controller.add(
        MqttDeviceMessage(
          deviceId: deviceId,
          topic: 'v1/u/devices/$deviceId/status',
          kind: MqttDeviceTopicKind.status,
          payload: jsonEncode(snapshot(mask: 2)),
          receivedAt: DateTime(2026, 10, 14, 9),
        ),
      );
      controller.add(
        MqttDeviceMessage(
          deviceId: deviceId,
          topic: 'v1/u/devices/$deviceId/telemetry',
          kind: MqttDeviceTopicKind.telemetry,
          payload: jsonEncode(snapshot(mask: 0)),
          receivedAt: DateTime(2026, 10, 14, 9),
        ),
      );
      await pumpEventQueue();
      expect(health.maskOf(deviceId), 2);
      health.dispose();
      await controller.close();
    });
  });

  group('screens', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      DeveloperAccessController.instance.setAccess(true);
      DeviceState.instance.reset(deviceId);
      TrafficLog.instance.clear();
    });

    testWidgets('Diagnostics header shows tab icon only on the device list', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(DiagnosticsScreen(repository: _repository())),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.show_chart), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back_ios_new_rounded), findsNothing);

      await tester.tap(find.text('Ao nuôi A1').first);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.show_chart), findsNothing);
      expect(find.byIcon(Icons.arrow_back_ios_new_rounded), findsOneWidget);

      await tester.tap(find.byIcon(Icons.arrow_back_ios_new_rounded));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.show_chart), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back_ios_new_rounded), findsNothing);
    });

    testWidgets('Diagnostics lists the devices and shows their errors', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(DiagnosticsScreen(inShell: false, repository: _repository())),
      );
      await tester.pumpAndSettle();
      expect(find.text('Ao nuôi A1'), findsOneWidget);
      expect(find.text('device_id: $deviceId'), findsOneWidget);

      await tester.tap(find.text('Ao nuôi A1'));
      await tester.pump();
      final json = sampleSnapshot(delayActive: false);
      json['errors'] = {
        'code_mask': 3,
        'messages': ['SYS_ERR_MODBUS_TIMEOUT', 'SYS_ERR_NET_LOST'],
      };
      DeviceState.instance
        ..reset(deviceId)
        ..applySnapshot(DeviceSnapshot.tryParse(json, DateTime.now())!);
      await tester.pumpAndSettle();

      expect(find.textContaining('error_mask = 3'), findsOneWidget);
      expect(find.textContaining('Nguyên nhân:'), findsNWidgets(2));
      expect(find.text('Nhật ký'), findsOneWidget);
      expect(
        find.text('Chưa ghi nhận lỗi hoặc dừng khẩn cấp nào.'),
        findsOneWidget,
      );

      // What the device reports is logged with its cause.
      await tester.runAsync(
        () => DeviceHealth.instance.observe(deviceId, json, DateTime.now()),
      );
      await tester.pumpAndSettle();
      expect(find.text('2/100 mục gần nhất'), findsOneWidget);
      expect(find.textContaining('SYS_ERR_MODBUS_TIMEOUT'), findsNWidgets(2));
      expect(find.textContaining('SYS_ERR_NET_LOST'), findsNWidgets(2));
      expect(find.text('Heap còn trống'), findsOneWidget);
      expect(find.text('Xem nhật ký kỹ thuật'), findsOneWidget);
    });

    testWidgets('Diagnostics reports a healthy device', (tester) async {
      await tester.pumpWidget(
        _wrap(DiagnosticsScreen(inShell: false, repository: _repository())),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ao nuôi A1'));
      await tester.pump();
      DeviceState.instance
        ..reset(deviceId)
        ..applySnapshot(
          DeviceSnapshot.tryParse(
            sampleSnapshot(delayActive: false),
            DateTime.now(),
          )!,
        );
      await tester.pumpAndSettle();
      expect(find.text('Thiết bị hoạt động bình thường.'), findsOneWidget);
      expect(find.text('Farm Wi-Fi'), findsOneWidget);
      expect(find.text('192.168.1.20'), findsOneWidget);
      expect(find.text('361d7646'), findsOneWidget);
    });

    testWidgets('Diagnostics shows wired network instead of an SSID', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(DiagnosticsScreen(inShell: false, repository: _repository())),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ao nuôi A1'));
      await tester.pump();
      final json = sampleSnapshot(delayActive: false)
        ..['net_interface'] = 'ETH';
      DeviceState.instance
        ..reset(deviceId)
        ..applySnapshot(DeviceSnapshot.tryParse(json, DateTime.now())!);
      await tester.pumpAndSettle();
      expect(find.text('Ethernet'), findsOneWidget);
      expect(find.text('Mạng có dây'), findsOneWidget);
      expect(find.text('Farm Wi-Fi'), findsNothing);
    });

    testWidgets('deleting the selected device returns to the device list', (
      tester,
    ) async {
      var exists = true;
      final repository = DeviceRepository(
        fetchRows: (_) async => [
          if (exists)
            {
              'id': '123e4567-e89b-12d3-a456-426614174000',
              'user_id': 'u1',
              'mac_address': deviceId,
              'name': 'Ao nuôi A1',
            },
        ],
        readCache: (_) async => null,
        writeCache: (_, _) async {},
        syncMqtt: (_, _) async {},
        currentUserId: () => 'u1',
      );
      await tester.pumpWidget(
        _wrap(DiagnosticsScreen(inShell: false, repository: repository)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ao nuôi A1'));
      await tester.pumpAndSettle();
      expect(find.text('Chọn thiết bị'), findsNothing);

      exists = false;
      await repository.refresh();
      await tester.pumpAndSettle();
      expect(find.text('Chọn thiết bị'), findsOneWidget);
      expect(find.text('Chưa có thiết bị nào được đăng ký.'), findsOneWidget);
    });

    testWidgets('swiping back from diagnostics returns to the device list', (
      tester,
    ) async {
      final repository = _repository();
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: NavigatorPopHandler<Object?>(
            onPopWithResult: (_) {
              final navigator = navigatorKey.currentState;
              if (navigator?.canPop() ?? false) navigator!.pop();
            },
            child: Navigator(
              key: navigatorKey,
              onGenerateRoute: (_) => MaterialPageRoute<void>(
                builder: (_) => DiagnosticsScreen(repository: repository),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ao nuôi A1'));
      await tester.pumpAndSettle();
      expect(find.text('Chọn thiết bị'), findsNothing);
      expect(find.text('Kết nối mạng'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Chọn thiết bị'), findsOneWidget);
      expect(find.text('device_id: $deviceId'), findsOneWidget);
      expect(find.text('Kết nối mạng'), findsNothing);
    });

    testWidgets('Console shows the traffic of its device live', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const ConsoleScreen(
            inShell: false,
            args: ConsoleArgs(name: 'Ao nuôi A1', deviceId: deviceId),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Chưa có bản tin nào'), findsOneWidget);

      TrafficLog.instance
        ..addTx(
          deviceId,
          'v1/u/devices/$deviceId/commands',
          MqttPayloads.setLoadState(cmdId: 'c1', loadId: 'DO1', on: true),
        )
        ..addRx(
          deviceId,
          'v1/u/devices/$deviceId/ack',
          MqttDeviceTopicKind.ack,
          '{"type":"ACK","cmd":"SET_LOAD_STATE","result":"ok","code":"OK"}',
        )
        ..addRx(
          'someone-else',
          'v1/u/devices/someone-else/ack',
          MqttDeviceTopicKind.ack,
          '{"type":"ACK","cmd":"GET_STATUS","result":"ok","code":"OK"}',
        );
      await tester.pump();
      expect(find.textContaining('SET_LOAD_STATE · cmd_id=c1'), findsOneWidget);
      expect(find.textContaining('SET_LOAD_STATE · ok'), findsOneWidget);
      expect(find.textContaining('GET_STATUS'), findsNothing);

      // Filter on ACK only, then open the detail of the entry.
      await tester.tap(find.text('ACK').first);
      await tester.pump();
      expect(find.textContaining('cmd_id=c1'), findsNothing);
      await tester.tap(find.textContaining('SET_LOAD_STATE · ok'));
      await tester.pump();
      expect(find.text('Chi tiết · ACK'), findsOneWidget);
      expect(find.textContaining('"result": "ok"'), findsOneWidget);
    });

    testWidgets('Console pauses and clears', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const ConsoleScreen(
            inShell: false,
            args: ConsoleArgs(name: 'Ao nuôi A1', deviceId: deviceId),
          ),
        ),
      );
      TrafficLog.instance.addTx(
        deviceId,
        'commands',
        MqttPayloads.getStatus(cmdId: 'first'),
      );
      await tester.pump();
      await tester.tap(find.text('Tạm dừng'));
      await tester.pump();
      TrafficLog.instance.addTx(
        deviceId,
        'commands',
        MqttPayloads.getStatus(cmdId: 'second'),
      );
      await tester.pump();
      expect(find.textContaining('cmd_id=first'), findsOneWidget);
      expect(find.textContaining('cmd_id=second'), findsNothing);

      await tester.tap(find.text('Tiếp tục'));
      await tester.pump();
      expect(find.textContaining('cmd_id=second'), findsOneWidget);

      await tester.tap(find.text('Xóa'));
      await tester.pump();
      expect(find.text('Chưa có bản tin nào'), findsOneWidget);
    });
  });
}

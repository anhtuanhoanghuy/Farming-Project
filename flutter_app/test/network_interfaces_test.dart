import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_app/models/scanned_device.dart';
import 'package:flutter_app/protocol/device_snapshot.dart';
import 'package:flutter_app/protocol/device_telemetry.dart';
import 'package:flutter_app/protocol/network_interfaces.dart';
import 'package:flutter_app/protocol/provisioning_messages.dart';
import 'package:flutter_app/screens/wifi_config_screen.dart';
import 'package:flutter_app/services/ble_prov_service.dart';
import 'package:flutter_app/state/device_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('network flags accept only binary integers and valid combinations', () {
    final network = NetworkInterfaces.fromJson({
      'ethernet': 0,
      'wifi': 1,
      '4g': 1,
    });
    expect(network.supports('4G'), isTrue);
    expect(network.supports('ETH'), isFalse);
    for (final json in [
      null,
      {'ethernet': 1, 'wifi': 1, '4g': 1},
      {'ethernet': 0, 'wifi': 0, '4g': 0},
      {'ethernet': true, 'wifi': 1, '4g': 0},
      {'ethernet': 0, 'wifi': 1},
    ]) {
      expect(() => NetworkInterfaces.fromJson(json), throwsFormatException);
    }
  });

  test('4G-only payload is explicit and cannot also select Ethernet', () {
    final request = ProvisioningMessages.configRequest(
      ssid: '',
      password: '',
      userId: 'owner',
      onlyUseEthernet: false,
      onlyUse4g: true,
    );
    expect(jsonDecode(utf8.decode(request)), {
      'ssid': '',
      'password': '',
      'user_id': 'owner',
      'only_use_ethernet': false,
      'only_use_4g': true,
    });
    expect(
      () => ProvisioningMessages.configRequest(
        ssid: '',
        password: '',
        userId: 'owner',
        onlyUseEthernet: true,
        onlyUse4g: true,
      ),
      throwsArgumentError,
    );
  });

  test(
    'live state displays 4G but not an interface absent from capabilities',
    () {
      final state = DeviceState();
      final now = DateTime.now();
      final snapshot = DeviceSnapshot.tryParse({
        'type': 'SNAPSHOT',
        'loads': [],
        'net_interface': '4G',
        'network_interfaces': {'ethernet': 0, 'wifi': 1, '4g': 1},
      }, now)!;
      state.applySnapshot(snapshot);
      expect(state.internetMethod, '4G');
      final telemetry = DeviceTelemetry.tryParse({
        'input': [],
        'net_interface': 'ETH',
        'network_interfaces': {'ethernet': 0, 'wifi': 1, '4g': 1},
      }, now)!;
      state.applyTelemetry(telemetry);
      expect(state.internetMethod, isNull);
      state.dispose();
    },
  );

  for (final cellular in [false, true]) {
    testWidgets(
      'BLE decides ${cellular ? '4G' : 'Ethernet'} checkbox before scanning',
      (tester) async {
        final endpoints = <String>[];
        final status = Completer<Uint8List>();
        final client = BleProvisioningService.test(
          send: (endpoint, _) async {
            endpoints.add(endpoint);
            if (endpoint == 'prov-status') return status.future;
            if (endpoint == 'wifi-scan') {
              return Uint8List.fromList(utf8.encode('{"total":0,"aps":[]}'));
            }
            throw StateError('Unexpected endpoint $endpoint');
          },
          close: () async {},
        );
        await tester.pumpWidget(
          MaterialApp(
            home: WifiConfigScreen(
              args: WifiConfigArgs(
                device: const ScannedDevice(
                  id: 'test',
                  name: 'Test',
                  rssi: -40,
                ),
                client: client,
              ),
            ),
          ),
        );
        expect(endpoints, ['prov-status']);
        expect(find.byType(Checkbox), findsNothing);
        status.complete(
          Uint8List.fromList(
            utf8.encode(
              jsonEncode({
                'state': 'idle',
                'device_id': 'aabbccddeeff',
                'network_interfaces': {
                  'ethernet': cellular ? 0 : 1,
                  'wifi': 1,
                  '4g': cellular ? 1 : 0,
                },
              }),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(endpoints, ['prov-status', 'wifi-scan']);
        expect(
          find.text(cellular ? 'Chỉ sử dụng 4G' : 'Chỉ sử dụng Ethernet'),
          findsOneWidget,
        );
        expect(
          find.text(cellular ? 'Chỉ sử dụng Ethernet' : 'Chỉ sử dụng 4G'),
          findsNothing,
        );
        await tester.tap(find.byType(Checkbox));
        await tester.pumpAndSettle();
        expect(find.text('Mạng khả dụng'), findsNothing);
        expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
        await tester.tap(find.byType(Checkbox));
        await tester.pumpAndSettle();
        expect(find.text('Mạng khả dụng'), findsOneWidget);
        expect(endpoints, ['prov-status', 'wifi-scan', 'wifi-scan']);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'missing BLE capabilities show an error without guessing Ethernet',
    (tester) async {
      final endpoints = <String>[];
      final client = BleProvisioningService.test(
        send: (endpoint, _) async {
          endpoints.add(endpoint);
          return Uint8List.fromList(
            utf8.encode('{"state":"idle","device_id":"aabbccddeeff"}'),
          );
        },
        close: () async {},
      );
      await tester.pumpWidget(
        MaterialApp(
          home: WifiConfigScreen(
            args: WifiConfigArgs(
              device: const ScannedDevice(id: 'test', name: 'Test', rssi: -40),
              client: client,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(endpoints, ['prov-status']);
      expect(find.byType(Checkbox), findsNothing);
      expect(find.text('Thử đọc lại khả năng mạng'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

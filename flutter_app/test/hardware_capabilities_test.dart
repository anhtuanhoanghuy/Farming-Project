import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_app/models/device_selection.dart';
import 'package:flutter_app/protocol/device_snapshot.dart';
import 'package:flutter_app/protocol/port_ids.dart';
import 'package:flutter_app/screens/load_control_screen.dart';
import 'package:flutter_app/screens/sensor_capacity_screen.dart';
import 'package:flutter_app/screens/sensor_config_screen.dart';
import 'package:flutter_app/services/ble_prov_service.dart';
import 'package:flutter_app/state/device_state.dart';
import 'package:flutter_app/state/load_controller.dart';
import 'package:flutter_app/widgets/app_buttons.dart';
import 'package:flutter_app/widgets/app_choice_buttons.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/sample_messages.dart';

const _device = DeviceSelection(deviceId: deviceId, name: 'Test');

Map<String, Object?> _capability(List<String> ports) => {
  'supported': ports.isNotEmpty,
  'count': ports.length,
  'port_lists': ports,
};

DeviceSnapshot _snapshot({
  List<String> rs485 = const ['RS1', 'RS2'],
  List<String> analog = const [],
  List<String> di = const ['DI1', 'DI2'],
  List<String> loads = const ['DO1', 'DO2'],
}) => DeviceSnapshot.tryParse({
  'type': 'SNAPSHOT',
  'capabilities': {
    'rs485': _capability(rs485),
    'analog_4_20ma': _capability(analog),
    'digital_inputs': _capability(di),
    'loads': _capability(loads),
  },
  'input': <Object?>[],
  'loads': <Object?>[],
}, DateTime.now())!;

Widget _config({String type = PortIds.rs485Type, String port = 'RS1'}) =>
    MaterialApp(
      home: SensorConfigScreen(
        selection: SensorConfigSelection(
          device: _device,
          interfaceType: type,
          portId: port,
          name: 'new_sensor',
        ),
      ),
    );

void main() {
  tearDown(() {
    DeviceState.instance.reset(null);
    for (final load in LoadController.loads) {
      load.cancelDelay();
    }
  });

  test('explicit zero does not recreate AN1 and leaves DI IDs intact', () {
    final snapshot = _snapshot();
    expect(snapshot.portsFor(PortIds.analogType), isEmpty);
    expect(snapshot.freePortsFor(PortIds.analogType), isEmpty);
    expect(snapshot.portsFor(PortIds.rs485Type), ['RS1', 'RS2']);
    expect(snapshot.portsFor(PortIds.diType), ['DI1', 'DI2']);
    expect(snapshot.supportsPort('RS3'), isFalse);
    expect(snapshot.supportsPort('AN1'), isFalse);
    expect(snapshot.supportsLoad('DO2'), isTrue);
    expect(snapshot.supportsLoad('DO3'), isFalse);
    expect(snapshot.capabilities.maxSensorCount, 4);
    expect(snapshot.capabilities.maxLoadCount, 2);
  });

  test('zero capacity is distinct from not reported', () {
    final empty = _snapshot(rs485: [], di: [], loads: []);
    expect(empty.capabilities.maxSensorCount, 0);
    expect(empty.capabilities.maxLoadCount, 0);
    final unknown = DeviceSnapshot.tryParse({
      'type': 'SNAPSHOT',
      'loads': <Object?>[],
    }, DateTime.now())!;
    expect(unknown.capabilities.maxSensorCount, isNull);
    expect(unknown.capabilities.maxLoadCount, isNull);
    for (final type in PortIds.interfaceTypes) {
      expect(unknown.portsFor(type), isEmpty);
    }
  });

  testWidgets('Current stays visible but disabled without analog support', (
    tester,
  ) async {
    DeviceState.instance.applySnapshot(_snapshot());
    await tester.pumpWidget(_config());
    expect(find.text('Current'), findsOneWidget);
    final choices = tester.widget<AppChoiceButtons<String>>(
      find.byType(AppChoiceButtons<String>),
    );
    expect(choices.isOptionEnabled!(PortIds.analogType), isFalse);
    expect(choices.isOptionEnabled!(PortIds.rs485Type), isTrue);
    final current = find
        .ancestor(of: find.text('Current'), matching: find.byType(InkWell))
        .first;
    expect(tester.widget<InkWell>(current).onTap, isNull);
    await tester.tap(find.text('Current'));
    await tester.pump();
    expect(
      tester
          .widget<AppChoiceButtons<String>>(
            find.byType(AppChoiceButtons<String>),
          )
          .selected,
      PortIds.rs485Type,
    );
    await tester.tap(find.text('DI'));
    await tester.pumpAndSettle();
    final dropdown = tester.widget<DropdownButtonFormField<String>>(
      find.byType(DropdownButtonFormField<String>),
    );
    expect(dropdown.initialValue, 'DI1');

    DeviceState.instance.applySnapshot(_snapshot(analog: ['AN1']));
    await tester.pump();
    await tester.tap(find.text('Current'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byType(DropdownButtonFormField<String>),
          )
          .initialValue,
      'AN1',
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('unknown or removed port cannot be saved or enabled', (
    tester,
  ) async {
    DeviceState.instance.applySnapshot(_snapshot(analog: ['AN1']));
    await tester.pumpWidget(_config(type: PortIds.analogType, port: 'AN1'));
    DeviceState.instance.applySnapshot(_snapshot());
    await tester.pump();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged,
      isNull,
    );
    expect(
      tester.widget<PrimaryButton>(find.byType(PrimaryButton)).enabled,
      isFalse,
    );
    expect(
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byType(DropdownButtonFormField<String>),
          )
          .initialValue,
      isNull,
    );
    DeviceState.instance.reset('another-device');
    await tester.pump();
    expect(
      tester.widget<PrimaryButton>(find.byType(PrimaryButton)).enabled,
      isFalse,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('no sensors keeps Add disabled with a genuine zero total', (
    tester,
  ) async {
    DeviceState.instance.applySnapshot(_snapshot(rs485: [], di: [], loads: []));
    await tester.pumpWidget(
      const MaterialApp(home: SensorCapacityScreen(device: _device)),
    );
    expect(find.text('0 / 0 đã cấu hình'), findsOneWidget);
    expect(
      tester.widget<GhostButton>(find.byType(GhostButton)).onPressed,
      isNull,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('unsupported DO cannot open controls or an enable menu', (
    tester,
  ) async {
    DeviceState.instance.applySnapshot(_snapshot());
    await tester.pumpWidget(
      MaterialApp(
        home: LoadControlScreen(device: _device, load: LoadController.loads[3]),
      ),
    );
    expect(find.byType(PopupMenuButton<void>), findsNothing);
    expect(find.text('Yêu cầu điều khiển mới'), findsNothing);
    expect(
      find.textContaining('Tải không được thiết bị hỗ trợ'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  for (final counts in [(0, 0), (0, 2), (4, 0)]) {
    test(
      'BLE provisioning accepts ${counts.$1} sensors and ${counts.$2} loads',
      () async {
        final service = BleProvisioningService.test(
          send: (endpoint, _) async => Uint8List.fromList(
            utf8.encode(
              jsonEncode(
                endpoint == 'prov-config'
                    ? {'status': 'IN_PROGRESS', 'device_id': deviceId}
                    : {
                        'state': 'done',
                        'status': 'SUCCESS',
                        'saved': true,
                        'attempts': 1,
                        'device_id': deviceId,
                        'max_sensor_count': counts.$1,
                        'max_load_count': counts.$2,
                      },
              ),
            ),
          ),
          close: () async {},
        );
        final result = await service.sendConfig(
          ssid: 'wifi',
          password: 'password',
          userId: 'owner',
          onlyUseEthernet: false,
        );
        expect(result.maxSensorCount, counts.$1);
        expect(result.maxLoadCount, counts.$2);
        await service.close();
      },
    );
  }
}

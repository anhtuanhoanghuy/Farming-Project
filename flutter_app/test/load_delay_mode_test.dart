import 'package:flutter/material.dart';
import 'package:flutter_app/models/device_selection.dart';
import 'package:flutter_app/protocol/device_snapshot.dart';
import 'package:flutter_app/screens/load_control_screen.dart';
import 'package:flutter_app/state/device_state.dart';
import 'package:flutter_app/state/load_controller.dart';
import 'package:flutter_app/theme/app_theme.dart';
import 'package:flutter_app/widgets/app_text_field.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/sample_messages.dart';

void _receiveSnapshot({
  required bool on,
  bool running = false,
  bool offThenOn = false,
  bool hasMinutes = true,
}) {
  final json = sampleSnapshot(delayActive: running);
  final loads = json['loads']! as List;
  final load = loads.first as Map<String, Object?>;
  load['state'] = on;
  final delay = load['load_delay']! as Map<String, Object?>;
  delay['mode'] = offThenOn;
  if (!hasMinutes) {
    delay['delay_min'] = 0;
    delay['duration'] = 0;
  }
  final snapshot = DeviceSnapshot.tryParse(json, DateTime.now())!;
  DeviceState.instance.applySnapshot(snapshot);
  LoadController.instance.applySnapshot(
    snapshot.loads.first,
    snapshot.receivedAt,
  );
}

Future<void> _openScreen(WidgetTester tester) => tester.pumpWidget(
  MaterialApp(
    theme: AppTheme.light,
    home: LoadControlScreen(
      device: const DeviceSelection(deviceId: deviceId, name: 'Test pond'),
      load: LoadController.instance,
    ),
  ),
);

void _expectMode(WidgetTester tester, {required bool turnOnFirst}) {
  final fields = tester.widgetList<AppTextField>(find.byType(AppTextField));
  expect(fields.first.label, turnOnFirst ? 'Thời gian bật' : 'Thời gian tắt');
  expect(
    fields.elementAt(1).label,
    turnOnFirst ? 'Thời gian tắt kể từ khi bật' : 'Thời gian bật kể từ khi tắt',
  );
  expect(
    find.text(turnOnFirst ? 'Đổi sang tắt' : 'Đổi sang bật'),
    findsOneWidget,
  );
}

void main() {
  setUp(() {
    DeviceState.instance.reset(null);
    LoadController.instance.cancelDelay();
    addTearDown(() {
      LoadController.instance.cancelDelay();
      DeviceState.instance.reset(null);
    });
  });

  for (final on in [true, false]) {
    for (final hasMinutes in [true, false]) {
      testWidgets(
        'Idle delay defaults to opposite of load state: on=$on, saved=$hasMinutes',
        (tester) async {
          _receiveSnapshot(on: on, offThenOn: !on, hasMinutes: hasMinutes);
          await _openScreen(tester);
          await tester.pumpAndSettle();
          _expectMode(tester, turnOnFirst: !on);
          final fields = tester.widgetList<AppTextField>(
            find.byType(AppTextField),
          );
          expect(fields.first.controller!.text, hasMinutes ? '5' : '');
          expect(fields.elementAt(1).controller!.text, hasMinutes ? '30' : '');
        },
      );
    }

    testWidgets('Delay mode can still be changed manually: on=$on', (
      tester,
    ) async {
      _receiveSnapshot(on: on);
      await _openScreen(tester);
      await tester.pumpAndSettle();
      final toggle = find.text(on ? 'Đổi sang bật' : 'Đổi sang tắt');
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      _expectMode(tester, turnOnFirst: on);

      _receiveSnapshot(on: on);
      await tester.pump();
      _expectMode(tester, turnOnFirst: on);
      final fields = tester.widgetList<AppTextField>(find.byType(AppTextField));
      expect(fields.first.controller!.text, '5');
      expect(fields.elementAt(1).controller!.text, '30');
      expect(
        find.text('Bắt đầu hẹn giờ ${on ? 'BẬT' : 'TẮT'} · 5 phút'),
        findsOneWidget,
      );
      await tester.tap(find.text(on ? 'Đổi sang tắt' : 'Đổi sang bật'));
      await tester.pumpAndSettle();
      _expectMode(tester, turnOnFirst: !on);
    });
  }

  testWidgets('Delay mode follows load state events and snapshots', (
    tester,
  ) async {
    _receiveSnapshot(on: false);
    await _openScreen(tester);
    await tester.pumpAndSettle();
    _expectMode(tester, turnOnFirst: true);

    LoadController.instance.setOnFromDevice(true);
    await tester.pump();
    _expectMode(tester, turnOnFirst: false);

    _receiveSnapshot(on: false);
    await tester.pump();
    _expectMode(tester, turnOnFirst: true);
  });

  for (final offThenOn in [true, false]) {
    testWidgets('Running delay retains its mode across phases: $offThenOn', (
      tester,
    ) async {
      _receiveSnapshot(on: !offThenOn, running: true, offThenOn: offThenOn);
      await _openScreen(tester);
      await tester.pump();
      _expectMode(tester, turnOnFirst: !offThenOn);

      LoadController.instance.setOnFromDevice(offThenOn);
      await tester.pump();
      _expectMode(tester, turnOnFirst: !offThenOn);
      final toggle = find
          .ancestor(
            of: find.text(offThenOn ? 'Đổi sang bật' : 'Đổi sang tắt'),
            matching: find.byType(InkWell),
          )
          .first;
      expect(tester.widget<InkWell>(toggle).onTap, isNull);

      LoadController.instance.cancelDelay();
      await tester.pump();
      _expectMode(tester, turnOnFirst: !offThenOn);
      expect(tester.widget<InkWell>(toggle).onTap, isNotNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

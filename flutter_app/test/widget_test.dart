import 'package:flutter/cupertino.dart' show CupertinoDatePicker;
import 'package:flutter/material.dart';
import 'package:flutter_app/models/device_selection.dart';
import 'package:flutter_app/models/provision_failure_args.dart';
import 'package:flutter_app/navigation/app_routes.dart';
import 'package:flutter_app/protocol/device_snapshot.dart';
import 'package:flutter_app/protocol/device_telemetry.dart';
import 'package:flutter_app/screens/dashboard_screen.dart';
import 'package:flutter_app/screens/load_control_screen.dart';
import 'package:flutter_app/screens/login_screen.dart';
import 'package:flutter_app/screens/provision_failure_screen.dart';
import 'package:flutter_app/screens/sensor_capacity_screen.dart';
import 'package:flutter_app/screens/sensor_config_screen.dart';
import 'package:flutter_app/screens/settings_screen.dart';
import 'package:flutter_app/state/developer_access_controller.dart';
import 'package:flutter_app/state/device_state.dart';
import 'package:flutter_app/state/load_controller.dart';
import 'package:flutter_app/theme/app_theme.dart';
import 'package:flutter_app/widgets/app_buttons.dart';
import 'package:flutter_app/widgets/app_anchored_dropdown.dart';
import 'package:flutter_app/widgets/hero_banner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/sample_messages.dart';

const _device = DeviceSelection(deviceId: deviceId, name: 'Test pond');

Widget _wrap(Widget child) => MaterialApp(theme: AppTheme.light, home: child);

/// What LoadSync does when a snapshot arrives.
void _receiveSnapshot({
  bool emergency = false,
  bool loadEnabled = true,
  bool delayActive = false,
}) {
  final snapshot = DeviceSnapshot.tryParse(
    sampleSnapshot(
      emergency: emergency,
      loadEnabled: loadEnabled,
      delayActive: delayActive,
    ),
    DateTime.now(),
  )!;
  DeviceState.instance.applySnapshot(snapshot);
  for (final load in snapshot.loads) {
    LoadController.loads
        .firstWhere((c) => c.portId == load.loadId)
        .applySnapshot(load, snapshot.receivedAt);
  }
}

Widget _loadScreen() =>
    LoadControlScreen(device: _device, load: LoadController.instance);

Widget _sensorConfigScreen({String port = 'RS3'}) {
  final input = DeviceState.instance.snapshot?.input(port);
  return SensorConfigScreen(
    selection: SensorConfigSelection(
      device: _device,
      interfaceType: input?.interfaceType ?? 'rs485',
      portId: port,
      name: input?.name ?? 'new_sensor',
      slaveId: input?.slaveId,
      enabled: input?.enabled ?? true,
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    DeveloperAccessController.instance.setAccess(true);
    DeviceState.instance.reset(null);
    for (final load in LoadController.loads) {
      load
        ..cancelDelay()
        ..setEnabled(true)
        ..setOn(true);
    }
    addTearDown(() {
      for (final load in LoadController.loads) {
        load.cancelDelay();
      }
      DeviceState.instance.reset(null);
    });
  });

  testWidgets('Login screen only offers Google sign-in', (tester) async {
    await tester.pumpWidget(_wrap(const LoginScreen()));
    expect(find.text('Đăng nhập bằng Google'), findsOneWidget);
    expect(find.text('Đăng ký'), findsNothing);
    expect(find.text('Quên mật khẩu?'), findsNothing);
    expect(find.text('Mã số đề tài: 11/2026/HĐ-ĐTCS'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) {
          if (widget is! Image) return false;
          final image = widget.image;
          return image is AssetImage &&
              image.assetName == 'assets/images/nacentech_logo.png';
        },
      ),
      findsOneWidget,
    );
  });

  testWidgets('Login hero banner advances automatically every five seconds', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(const Scaffold(body: HeroBanner())));
    const homeBannerTitle = 'Nâng tầm tổ ấm.\nSống thông minh hơn.';
    const pondBannerTitle = 'Nắm rõ ao nuôi.\nVận hành thảnh thơi.';
    expect(find.text(homeBannerTitle), findsOneWidget);
    expect(find.byType(AnimatedContainer), findsNothing);

    await tester.drag(find.byType(PageView), const Offset(-200, 0));
    await tester.pumpAndSettle();
    expect(find.text(homeBannerTitle), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text(pondBannerTitle), findsOneWidget);

    for (var index = 0; index < 3; index++) {
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(find.text(homeBannerTitle), findsOneWidget);
  });

  testWidgets('Anchored dropdown opens below its field and selects an option', (
    tester,
  ) async {
    String? selected;
    await tester.pumpWidget(
      _wrap(
        Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: AppAnchoredDropdownField<String>(
                value: selected,
                hint: 'Choose',
                enabled: true,
                options: const [
                  AppDropdownOption(value: 'humidity', label: 'Humidity'),
                ],
                onChanged: (value) => selected = value,
              ),
            ),
          ),
        ),
      ),
    );

    final field = find.byType(AppAnchoredDropdownField<String>);
    await tester.tap(field);
    await tester.pumpAndSettle();

    final fieldBottom = tester.getBottomLeft(field).dy;
    final optionTop = tester.getTopLeft(find.text('Humidity')).dy;
    expect(optionTop, greaterThanOrEqualTo(fieldBottom));
    await tester.tap(find.text('Humidity'));
    await tester.pumpAndSettle();
    expect(selected, 'humidity');
  });

  testWidgets('Provisioning failure shows a result page with retry actions', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        ProvisionFailureScreen(
          args: const ProvisionFailureArgs(
            deviceName: 'Test device',
            message: 'Wi-Fi failed, previous settings kept',
          ),
        ),
      ),
    );

    expect(find.text('Thiết lập cấu hình thất bại'), findsOneWidget);
    expect(find.text('Wi-Fi failed, previous settings kept'), findsOneWidget);
    expect(find.text('Quay lại cấu hình Wi-Fi'), findsOneWidget);
    expect(find.text('Về danh sách thiết bị'), findsOneWidget);
  });

  testWidgets('Primary action dismisses the keyboard before running', (
    tester,
  ) async {
    final focusNode = FocusNode();
    var activated = false;
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(
      _wrap(
        Scaffold(
          body: Column(
            children: [
              TextField(focusNode: focusNode),
              PrimaryButton(label: 'Gửi', onPressed: () => activated = true),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byType(TextField));
    await tester.showKeyboard(find.byType(TextField));
    await tester.pump();
    expect(focusNode.hasFocus, isTrue);

    await tester.tap(find.text('Gửi'));
    await tester.pump();
    expect(focusNode.hasFocus, isFalse);
    expect(activated, isTrue);
  });

  testWidgets('Nested navigator handles system back before the root route', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        home: NavigatorPopHandler<Object?>(
          onPopWithResult: (_) => navigatorKey.currentState?.pop(),
          child: Navigator(
            key: navigatorKey,
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => const Scaffold(
                        body: Center(child: Text('Nested page')),
                      ),
                    ),
                  ),
                  child: const Text('Open nested page'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open nested page'));
    await tester.pumpAndSettle();
    expect(find.text('Nested page'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Open nested page'), findsOneWidget);
    expect(find.text('Nested page'), findsNothing);
  });

  testWidgets('Nested navigator ignores system back at its root route', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        home: NavigatorPopHandler<Object?>(
          onPopWithResult: (_) {
            final navigator = navigatorKey.currentState;
            if (navigator?.canPop() ?? false) navigator!.pop();
          },
          child: Navigator(
            key: navigatorKey,
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (_) =>
                  const Scaffold(body: Center(child: Text('Root tab'))),
            ),
          ),
        ),
      ),
    );

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Root tab'), findsOneWidget);
  });

  testWidgets('Load screen waits for the snapshot of the ESP32', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(_loadScreen()));
    await tester.pumpAndSettle();
    expect(find.textContaining('Chưa nhận được cấu hình tải'), findsOneWidget);
    expect(find.text('Cài đặt trễ'), findsNothing);
  });

  testWidgets(
    'Load screen follows the request / delay / condition / schedule design',
    (tester) async {
      _receiveSnapshot();
      await tester.pumpWidget(_wrap(_loadScreen()));
      await tester.pumpAndSettle();
      expect(find.textContaining('Trạng thái thực tế:'), findsOneWidget);
      expect(find.text('Yêu cầu điều khiển mới'), findsOneWidget);
      expect(find.text('BẬT'), findsOneWidget);
      expect(find.text('TẮT'), findsOneWidget);
      expect(find.text('Cài đặt trễ'), findsOneWidget);
      expect(find.text('Cài đặt điều kiện'), findsOneWidget);
      expect(find.text('Lịch hẹn'), findsOneWidget);
      expect(find.text('Thời gian bật'), findsOneWidget);
      expect(find.text('Thời gian tắt kể từ khi bật'), findsOneWidget);
      // The snapshot's delay settings (5 min, 30 min, ON then OFF) fill the form.
      expect(find.text('Gửi yêu cầu BẬT · 5 phút'), findsOneWidget);
      expect(
        find.textContaining('Firmware chỉ cho phép một trong hai'),
        findsNothing,
      );

      await tester.ensureVisible(find.text('Đổi sang tắt'));
      await tester.tap(find.text('Đổi sang tắt'));
      await tester.pumpAndSettle();
      expect(find.text('Thời gian tắt'), findsOneWidget);
      expect(find.text('Thời gian bật kể từ khi tắt'), findsOneWidget);
      expect(find.text('Gửi yêu cầu TẮT · 5 phút'), findsOneWidget);
      expect(find.text('Đổi sang bật'), findsOneWidget);
      expect(find.text('BẬT'), findsOneWidget);
      expect(find.text('TẮT'), findsOneWidget);
    },
  );

  testWidgets('The delay request button follows what is typed', (tester) async {
    _receiveSnapshot();
    await tester.pumpWidget(_wrap(_loadScreen()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '');
    await tester.enterText(find.byType(TextField).at(1), '');
    await tester.pump();
    expect(find.text('nhập số phút'), findsNWidgets(2));
    var sendButton = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, 'Gửi yêu cầu BẬT'),
    );
    expect(sendButton.onPressed, isNull);

    await tester.enterText(find.byType(TextField).first, '1');
    await tester.enterText(find.byType(TextField).at(1), '30');
    await tester.pump();
    sendButton = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, 'Gửi yêu cầu BẬT · 1 phút'),
    );
    expect(sendButton.onPressed, isNotNull);

    await tester.enterText(find.byType(TextField).first, '1440');
    await tester.pump();
    sendButton = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, 'Gửi yêu cầu BẬT · 1440 phút'),
    );
    expect(sendButton.onPressed, isNotNull);

    await tester.enterText(find.byType(TextField).first, '1441');
    await tester.pump();
    sendButton = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, 'Gửi yêu cầu BẬT · 1441 phút'),
    );
    expect(sendButton.onPressed, isNull);

    await tester.enterText(find.byType(TextField).first, '2');
    await tester.pump();
    sendButton = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, 'Gửi yêu cầu BẬT · 2 phút'),
    );
    expect(sendButton.onPressed, isNotNull);

    await tester.enterText(find.byType(TextField).at(1), '1440');
    await tester.pump();
    sendButton = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, 'Gửi yêu cầu BẬT · 2 phút'),
    );
    expect(sendButton.onPressed, isNotNull);

    await tester.enterText(find.byType(TextField).at(1), '1441');
    await tester.pump();
    sendButton = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, 'Gửi yêu cầu BẬT · 2 phút'),
    );
    expect(sendButton.onPressed, isNull);

    await tester.enterText(find.byType(TextField).at(1), '1439');
    await tester.pump();
    sendButton = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, 'Gửi yêu cầu BẬT · 2 phút'),
    );
    expect(sendButton.onPressed, isNotNull);

    await tester.enterText(find.byType(TextField).first, '60');
    await tester.pump();
    expect(find.text('Gửi yêu cầu BẬT · 60 phút'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '0');
    await tester.pump();
    sendButton = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, 'Gửi yêu cầu BẬT · ngay'),
    );
    expect(sendButton.onPressed, isNull);
  });

  testWidgets(
    '2 conditions and 3 schedules of the snapshot, both usable together',
    (tester) async {
      _receiveSnapshot();
      await tester.pumpWidget(_wrap(_loadScreen()));
      await tester.pumpAndSettle();
      expect(find.text('Điều kiện 1'), findsOneWidget);
      expect(find.text('Điều kiện 2'), findsOneWidget);
      expect(find.text('Lịch hẹn 1'), findsOneWidget);
      expect(find.text('Lịch hẹn 2'), findsOneWidget);
      expect(find.text('Lịch hẹn 3'), findsOneWidget);
      expect(find.text('Bật khi'), findsOneWidget);
      expect(find.text('Tắt khi'), findsOneWidget);
      expect(find.text('Vượt ngưỡng (>)'), findsOneWidget);
      expect(find.text('Dưới ngưỡng (<)'), findsOneWidget);
      expect(find.text('Giá trị ngưỡng'), findsNWidgets(2));
      expect(find.text('Áp dụng điều kiện'), findsNothing);
      expect(find.text('Áp dụng lịch hẹn'), findsNothing);
      expect(find.text('Thêm điều kiện (2/2)'), findsOneWidget);
      expect(find.text('Thêm lịch hẹn (3/3)'), findsOneWidget);
      expect(find.text('4.5'), findsOneWidget);
      expect(find.text('T2'), findsNWidgets(3));

      // One "Xóa" per condition and per schedule, each with a switch.
      expect(find.text('Xóa'), findsNWidgets(5));
      for (final card in [
        'Điều kiện 1',
        'Điều kiện 2',
        'Lịch hẹn 1',
        'Lịch hẹn 2',
        'Lịch hẹn 3',
      ]) {
        final header = find.ancestor(
          of: find.text(card),
          matching: find.byType(Row),
        );
        expect(
          find.descendant(of: header.first, matching: find.byType(Switch)),
          findsOneWidget,
          reason: card,
        );
      }
    },
  );

  testWidgets('Condition metrics can be selected before telemetry arrives', (
    tester,
  ) async {
    _receiveSnapshot();
    await tester.pumpWidget(_wrap(_loadScreen()));
    await tester.pumpAndSettle();

    final reference = find.byKey(
      const ValueKey('value-CON2-RS1-Độ ẩm không khí-2-false'),
    );
    await tester.ensureVisible(reference);
    await tester.tap(reference);
    await tester.pumpAndSettle();
    expect(find.text('Nhiệt độ không khí'), findsOneWidget);

    await tester.tap(find.text('Nhiệt độ không khí'));
    await tester.pumpAndSettle();
    expect(find.text('Nhiệt độ không khí'), findsOneWidget);
  });

  testWidgets('The sensor dropdown lists the configured sensors by port', (
    tester,
  ) async {
    _receiveSnapshot();
    await tester.pumpWidget(_wrap(_loadScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Nhiệt độ & Độ ẩm · RS1'), findsNWidgets(2));
  });

  testWidgets('A running delay shows its countdown and a stop button', (
    tester,
  ) async {
    _receiveSnapshot(delayActive: true);
    await tester.pumpWidget(_wrap(_loadScreen()));
    await tester.pump();
    expect(find.textContaining('Dừng - 04:'), findsOneWidget);
    expect(find.textContaining('Gửi yêu cầu'), findsNothing);
    final modeSwitch = find
        .ancestor(of: find.text('Đổi sang tắt'), matching: find.byType(InkWell))
        .first;
    expect(tester.widget<InkWell>(modeSwitch).onTap, isNull);
    final opacity = find
        .ancestor(of: modeSwitch, matching: find.byType(Opacity))
        .first;
    expect(tester.widget<Opacity>(opacity).opacity, 0.48);
    LoadController.instance.cancelDelay();
    await tester.pump();
    expect(find.textContaining('Dừng - '), findsNothing);
    expect(find.textContaining('Gửi yêu cầu'), findsOneWidget);
    expect(tester.widget<InkWell>(modeSwitch).onTap, isNotNull);
    expect(tester.widget<Opacity>(opacity).opacity, 1);
  });

  testWidgets('A disabled load hides its controls', (tester) async {
    _receiveSnapshot(loadEnabled: false);
    await tester.pumpWidget(_wrap(_loadScreen()));
    await tester.pumpAndSettle();
    expect(find.textContaining('Điều khiển tải đang tắt'), findsOneWidget);
    expect(find.text('Yêu cầu điều khiển mới'), findsNothing);
  });

  testWidgets(
    'A new snapshot replaces the load screen after an emergency stop',
    (tester) async {
      _receiveSnapshot();
      await tester.pumpWidget(_wrap(_loadScreen()));
      await tester.pumpAndSettle();
      expect(find.text('Điều kiện 1'), findsOneWidget);

      // The ESP32 deleted every condition and schedule of the load.
      final json = sampleSnapshot(emergency: true, delayActive: false);
      for (final load in json['loads']! as List) {
        (load as Map<String, Object?>)['load_condition'] = <Object?>[];
        load['load_scheduler'] = <Object?>[];
        load['state'] = false;
      }
      DeviceState.instance.applySnapshot(
        DeviceSnapshot.tryParse(json, DateTime.now())!,
      );
      await tester.pumpAndSettle();
      expect(find.text('Điều kiện 1'), findsNothing);
      expect(find.text('Lịch hẹn 1'), findsNothing);
      expect(find.text('Thêm điều kiện (0/2)'), findsOneWidget);
      expect(find.text('Thêm lịch hẹn (0/3)'), findsOneWidget);
      // The load itself stays controllable.
      expect(find.text('Yêu cầu điều khiển mới'), findsOneWidget);
    },
  );

  testWidgets('Enabling an incomplete condition or schedule turns fields red', (
    tester,
  ) async {
    final json = sampleSnapshot(delayActive: false);
    final load = (json['loads']! as List).first as Map<String, Object?>;
    load['load_condition'] = [
      {
        'condition_id': 'CON1',
        'condition_enabled': false,
        'action': false,
        'sensor_id': '',
        'operator': false,
        'threshold': 0,
      },
    ];
    load['load_scheduler'] = [
      {
        'scheduler_id': 'SHE1',
        'scheduler_enabled': false,
        'days_mask': 0,
        'on_time_utc': '00:00',
        'off_time_utc': '00:00',
      },
    ];
    final snapshot = DeviceSnapshot.tryParse(json, DateTime.now())!;
    DeviceState.instance.applySnapshot(snapshot);
    for (final item in snapshot.loads) {
      LoadController.loads
          .firstWhere((c) => c.portId == item.loadId)
          .applySnapshot(item, snapshot.receivedAt);
    }
    await tester.pumpWidget(_wrap(_loadScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Chọn hành động'), findsOneWidget);
    expect(find.text('Chọn điều kiện'), findsOneWidget);
    expect(find.text('Hãy chọn cảm biến'), findsNothing);
    expect(find.text('Hãy chọn ít nhất một ngày'), findsNothing);
    expect(find.text('Chọn giờ'), findsNWidgets(2));

    Finder switchOf(String title) => find.descendant(
      of: find.ancestor(of: find.text(title), matching: find.byType(Row)).first,
      matching: find.byType(Switch),
    );

    await tester.ensureVisible(switchOf('Điều kiện 1'));
    await tester.tap(switchOf('Điều kiện 1'));
    await tester.pumpAndSettle();
    expect(find.text('Hãy chọn cảm biến'), findsOneWidget);
    expect(find.text('Hãy chọn hành động'), findsOneWidget);
    expect(find.text('Hãy chọn điều kiện'), findsOneWidget);
    expect(find.text('Nhập giá trị là số'), findsOneWidget);
    expect(tester.widget<Switch>(switchOf('Điều kiện 1')).value, isFalse);

    await tester.ensureVisible(switchOf('Lịch hẹn 1'));
    await tester.tap(switchOf('Lịch hẹn 1'));
    await tester.pumpAndSettle();
    expect(find.text('Hãy chọn giờ bật'), findsOneWidget);
    expect(find.text('Hãy chọn giờ tắt'), findsOneWidget);
    expect(find.text('Hãy chọn ít nhất một ngày'), findsOneWidget);
    expect(tester.widget<Switch>(switchOf('Lịch hẹn 1')).value, isFalse);
  });

  testWidgets('A time field opens a wheel picker and shows the chosen time', (
    tester,
  ) async {
    final json = sampleSnapshot(delayActive: false);
    final load = (json['loads']! as List).first as Map<String, Object?>;
    load['load_condition'] = <Object?>[];
    load['load_scheduler'] = [
      {
        'scheduler_id': 'SHE1',
        'scheduler_enabled': false,
        'days_mask': 0,
        'on_time_utc': '00:00',
        'off_time_utc': '00:00',
      },
    ];
    final snapshot = DeviceSnapshot.tryParse(json, DateTime.now())!;
    DeviceState.instance.applySnapshot(snapshot);
    for (final item in snapshot.loads) {
      LoadController.loads
          .firstWhere((c) => c.portId == item.loadId)
          .applySnapshot(item, snapshot.receivedAt);
    }
    await tester.pumpWidget(_wrap(_loadScreen()));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Giờ bật'));
    await tester.tap(find.text('Chọn giờ').first);
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoDatePicker), findsOneWidget);
    await tester.tap(find.text('Xong'));
    await tester.pumpAndSettle();
    expect(find.text('06:00'), findsOneWidget);
    expect(find.text('Chọn giờ'), findsOneWidget);
  });

  testWidgets('A load request shows at once and goes back when no ACK comes', (
    tester,
  ) async {
    _receiveSnapshot();
    final load = LoadController.instance;
    final before = load.isOn;
    final seen = <bool>[];
    void record() => seen.add(load.isOn);
    load.addListener(record);
    addTearDown(() => load.removeListener(record));

    await tester.pumpWidget(_wrap(_loadScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.text(before ? 'TẮT' : 'BẬT'));
    await tester.pumpAndSettle();

    // The new state was shown first, then restored: nothing acknowledged it.
    expect(seen, contains(!before));
    expect(load.isOn, before);
    expect(find.textContaining('Giao tiếp với ESP32 thất bại'), findsOneWidget);
  });

  testWidgets('Quick taps show every state but send only the last one', (
    tester,
  ) async {
    final load = LoadController.loads[1];
    load.setOn(false);
    final sent = <bool>[];
    final shown = <bool>[];
    void record() => shown.add(load.isOn);
    load.addListener(record);
    addTearDown(() => load.removeListener(record));

    Future<void> send(bool state) async => sent.add(state);
    void tap(bool state) =>
        load.requestOnOff(state, send: send, onError: (_) {});

    tap(true);
    await tester.pump(const Duration(milliseconds: 100));
    tap(false);
    await tester.pump(const Duration(milliseconds: 100));
    tap(true);
    expect(load.isOn, isTrue);
    expect(sent, isEmpty);

    // A snapshot arriving meanwhile cannot make the switch jump back.
    final snapshot = DeviceSnapshot.tryParse(
      sampleSnapshot(delayActive: false),
      DateTime.now(),
    )!;
    load.applySnapshot(
      snapshot.loads.firstWhere((l) => l.loadId == load.portId),
      snapshot.receivedAt,
    );
    expect(load.isOn, isTrue);

    await tester.pump(
      LoadController.sendDelay + const Duration(milliseconds: 50),
    );
    expect(sent, [true]);
    expect(load.busy, isFalse);
  });

  testWidgets('The dashboard no longer shows an emergency stop banner', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(DashboardScreen(device: _device, inShell: false)),
    );
    await tester.pump();
    _receiveSnapshot(emergency: true, delayActive: false);
    await tester.pump();
    expect(find.textContaining('Đã dừng khẩn cấp'), findsNothing);
  });

  testWidgets('Dashboard pull-to-refresh wraps the whole page content', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(DashboardScreen(device: _device, inShell: false)),
    );
    await tester.pump();

    expect(find.byType(RefreshIndicator), findsOneWidget);
    expect(
      find.ancestor(
        of: find.text('Test pond'),
        matching: find.byType(SingleChildScrollView),
      ),
      findsOneWidget,
    );
    expect(
      find.ancestor(
        of: find.text('Cảm biến'),
        matching: find.byType(SingleChildScrollView),
      ),
      findsOneWidget,
    );
  });

  testWidgets('A snapshot cannot cancel a delay request that is being sent', (
    tester,
  ) async {
    final load = LoadController.loads[2];
    load.cancelDelay();
    var sent = 0;
    load.requestDelay(
      stop: false,
      shown: const LoadDelay(
        active: true,
        delayMin: 5,
        phase: DelayPhase.waitFirst,
        remainingSeconds: 300,
      ),
      send: () async => sent++,
      onError: (_) {},
    );
    expect(load.delayActive, isTrue);

    // An older snapshot (no delay) arrives before the ESP32 got the command.
    final snapshot = DeviceSnapshot.tryParse(
      sampleSnapshot(delayActive: false),
      DateTime.now(),
    )!;
    load.applySnapshot(
      snapshot.loads.firstWhere((l) => l.loadId == load.portId),
      snapshot.receivedAt,
    );
    expect(load.delayActive, isTrue);

    await tester.pump(
      LoadController.sendDelay + const Duration(milliseconds: 50),
    );
    expect(sent, 1);
    expect(load.busy, isFalse);
    load.cancelDelay();
  });

  testWidgets(
    'Dashboard shows "_" until telemetry arrives, then the ESP32 values',
    (tester) async {
      await tester.pumpWidget(
        _wrap(DashboardScreen(device: _device, inShell: false)),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Đang chờ snapshot'), findsOneWidget);

      _receiveSnapshot();
      await tester.pumpAndSettle();
      expect(find.text('Nhiệt độ & Độ ẩm · RS1'), findsOneWidget);
      expect(find.text('Phao nước · DI2'), findsOneWidget);
      // RS3 is configured but disabled.
      expect(find.textContaining('RS3'), findsNothing);
      expect(find.text('_'), findsNWidgets(2));
      expect(find.text('°C'), findsNothing);

      DeviceState.instance.applyTelemetry(
        DeviceTelemetry.tryParse(sampleTelemetry(), DateTime.now())!,
      );
      await tester.pumpAndSettle();
      expect(find.text('_'), findsNothing);
      expect(find.text('25.1'), findsOneWidget);
      expect(find.text('°C'), findsOneWidget);
      expect(find.text('60'), findsOneWidget);
      expect(find.text('%RH'), findsOneWidget);
      expect(find.text('Có'), findsOneWidget);
      expect(find.text('Trạng thái'), findsOneWidget);
    },
  );

  testWidgets(
    'Dashboard load card shows the countdown and a stop-only emergency alert',
    (tester) async {
      await tester.pumpWidget(
        _wrap(DashboardScreen(device: _device, inShell: false)),
      );
      await tester.pumpAndSettle();
      _receiveSnapshot(delayActive: true, emergency: true);
      await tester.tap(find.text('Tải'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Đã dừng khẩn cấp'), findsNothing);
      expect(find.text('Cổng DO1'), findsOneWidget);
      expect(find.text('còn lại trước tự bật'), findsOneWidget);
      expect(find.text('Bật lại cảm biến'), findsNothing);
      expect(find.text('Dừng khẩn cấp'), findsOneWidget);
      LoadController.instance.cancelDelay();
      await tester.pump();
    },
  );

  testWidgets(
    'Sensor screen offers DI / Current / RS485 and locks a saved sensor',
    (tester) async {
      _receiveSnapshot();
      await tester.pumpWidget(_wrap(_sensorConfigScreen()));
      expect(find.text('RS3'), findsOneWidget);
      expect(find.text('Loại cảm biến'), findsOneWidget);
      expect(find.text('DI'), findsOneWidget);
      expect(find.text('Current'), findsOneWidget);
      expect(find.text('RS485'), findsOneWidget);
      expect(find.text('Địa chỉ Modbus'), findsOneWidget);
      expect(find.text('Lưu'), findsOneWidget);
      await tester.tap(find.text('DI'));
      await tester.pump();
      expect(find.text('RS3'), findsOneWidget);
      expect(
        find.textContaining('Không đổi được loại của cảm biến đã lưu'),
        findsOneWidget,
      );
    },
  );

  testWidgets('A new sensor can only use free ports and switch type', (
    tester,
  ) async {
    _receiveSnapshot();
    await tester.pumpWidget(_wrap(_sensorConfigScreen(port: 'RS2')));
    expect(find.text('RS2'), findsOneWidget);
    expect(find.text('Bù hiệu chuẩn'), findsNothing);
    final rs485AddressField = tester
        .widgetList<TextField>(find.byType(TextField))
        .singleWhere((field) => field.keyboardType == TextInputType.number);
    expect(rs485AddressField.controller?.text, '102');
    await tester.tap(find.text('DI'));
    await tester.pump();
    // DI2 already has a sensor: the first free DI port is DI1.
    expect(find.text('DI1'), findsOneWidget);
    expect(find.text('Địa chỉ Modbus'), findsNothing);

    await tester.tap(find.text('Current'));
    await tester.pump();
    expect(find.text('AN1'), findsOneWidget);
  });

  testWidgets('Sensor management lists the snapshot sensors and capacity', (
    tester,
  ) async {
    _receiveSnapshot();
    await tester.pumpWidget(_wrap(SensorCapacityScreen(device: _device)));
    await tester.pumpAndSettle();
    expect(find.text('Thêm cảm biến'), findsOneWidget);
    expect(find.text('3 / 9 đã cấu hình'), findsOneWidget);
    expect(find.text('Cổng: RS1'), findsOneWidget);
    expect(find.text('Cổng: RS3'), findsOneWidget);
    expect(find.text('Cổng: DI2'), findsOneWidget);
    expect(find.text('Đã bật'), findsNWidgets(2));
    expect(find.text('Đã tắt'), findsOneWidget);
    expect(find.text('Sửa cấu hình'), findsNWidgets(3));
  });

  testWidgets('Adding an RS485 sensor defaults to 100 plus the port number', (
    tester,
  ) async {
    _receiveSnapshot();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: SensorCapacityScreen(device: _device),
        onGenerateRoute: (settings) {
          if (settings.name != AppRoutes.sensorConfig) return null;
          return MaterialPageRoute<void>(
            builder: (_) => SensorConfigScreen(
              selection: settings.arguments! as SensorConfigSelection,
            ),
          );
        },
      ),
    );
    await tester.ensureVisible(find.text('Thêm cảm biến'));
    await tester.tap(find.text('Thêm cảm biến'));
    await tester.pumpAndSettle();
    expect(find.text('RS2'), findsOneWidget);
    final rs485AddressField = tester
        .widgetList<TextField>(find.byType(TextField))
        .singleWhere((field) => field.keyboardType == TextInputType.number);
    expect(rs485AddressField.controller?.text, '102');
  });

  testWidgets('Sensor management lists an analog 4-20 mA sensor', (
    tester,
  ) async {
    final json = sampleSnapshot();
    json['input'] = [
      ...json['input']! as List,
      {
        'interface_type': 'analog_4_20ma',
        'port_id': 'AN1',
        'name': 'Analog_4_20mA',
        'enabled': true,
        'valid': false,
      },
    ];
    DeviceState.instance.applySnapshot(
      DeviceSnapshot.tryParse(json, DateTime.now())!,
    );
    await tester.pumpWidget(_wrap(SensorCapacityScreen(device: _device)));
    await tester.pumpAndSettle();
    expect(find.text('Analog_4_20mA'), findsOneWidget);
    expect(find.text('Cổng: AN1'), findsOneWidget);
    expect(find.text('4 / 9 đã cấu hình'), findsOneWidget);
  });

  testWidgets('Sensor management waits for the snapshot', (tester) async {
    await tester.pumpWidget(_wrap(SensorCapacityScreen(device: _device)));
    await tester.pumpAndSettle();
    expect(find.textContaining('Đang chờ snapshot'), findsOneWidget);
  });

  testWidgets('Settings header uses its tab icon instead of a back arrow', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(const SettingsScreen()));
    expect(find.byIcon(Icons.settings), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back_ios_new_rounded), findsNothing);
  });

  testWidgets('Developer mode requires 30 version taps', (tester) async {
    DeveloperAccessController.instance.setAccess(false);
    await tester.pumpWidget(_wrap(const SettingsScreen()));

    for (var tap = 0; tap < 29; tap++) {
      await tester.tap(find.text('Phiên bản ứng dụng'));
      await tester.pump();
    }
    expect(DeveloperAccessController.instance.hasAccess, isFalse);
    expect(find.text('Chế độ nhà phát triển'), findsNothing);

    await tester.tap(find.text('Phiên bản ứng dụng'));
    await tester.pump();
    expect(DeveloperAccessController.instance.hasAccess, isTrue);
    expect(find.text('Chế độ nhà phát triển'), findsOneWidget);
  });

  testWidgets('Developer access can be revoked and restored', (tester) async {
    _receiveSnapshot();
    await tester.pumpWidget(_wrap(const SettingsScreen()));
    expect(find.text('Chế độ nhà phát triển'), findsOneWidget);
    await tester.ensureVisible(find.text('Thu hồi chế độ nhà phát triển'));
    await tester.tap(find.text('Thu hồi chế độ nhà phát triển'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Thu hồi').last);
    await tester.pumpAndSettle();
    expect(DeveloperAccessController.instance.hasAccess, isFalse);

    await tester.pumpWidget(_wrap(_sensorConfigScreen()));

    DeveloperAccessController.instance.setAccess(true);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_wrap(_sensorConfigScreen()));
  });
}

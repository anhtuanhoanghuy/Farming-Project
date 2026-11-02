import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_app/navigation/main_shell.dart';
import 'package:flutter_app/services/mqtt_session_manager.dart';
import 'package:flutter_app/navigation/app_routes.dart';
import 'package:flutter_app/screens/settings_screen.dart';
import 'package:flutter_app/state/admin_access_controller.dart';
import 'package:flutter_app/state/developer_access_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late bool developer;
  late String? user;
  late bool allowed;
  late int checks;
  late List<bool> modes;
  late AdminAccessController controller;
  Future<bool> Function(String)? checkOverride;
  Future<void> Function(bool)? modeOverride;

  setUp(() {
    developer = true;
    user = 'admin';
    allowed = true;
    checks = 0;
    modes = [];
    checkOverride = null;
    modeOverride = null;
    controller = AdminAccessController(
      currentUserId: () => user,
      developerEnabled: () => developer,
      checkAdmin: (id) async {
        checks++;
        return checkOverride == null ? allowed : await checkOverride!(id);
      },
      setMode: (active) async {
        modes.add(active);
        await modeOverride?.call(active);
      },
    );
  });

  tearDown(() => controller.dispose());

  Future<void> tapNine() async {
    for (var i = 0; i < 9; i++) {
      expect(await controller.tap(), isFalse);
    }
  }

  test('only the tenth tap checks membership and activates admin', () async {
    await tapNine();
    expect(checks, 0);
    expect(controller.isActive, isFalse);
    expect(await controller.tap(), isTrue);
    expect(checks, 1);
    expect(modes, [true]);
    expect(controller.isActive, isTrue);
    expect(await controller.tap(), isFalse);
    expect(checks, 1);
  });

  test('dev mode and authentication are required', () async {
    developer = false;
    for (var i = 0; i < 10; i++) {
      await controller.tap();
    }
    developer = true;
    user = null;
    for (var i = 0; i < 10; i++) {
      await controller.tap();
    }
    expect(checks, 0);
    expect(modes, isEmpty);
    expect(controller.isActive, isFalse);
  });

  test(
    'revocation requires dev mode and ten fresh taps to reopen admin',
    () async {
      await tapNine();
      await controller.tap();
      developer = false;
      await controller.deactivate();
      expect(controller.isActive, isFalse);
      for (var i = 0; i < 10; i++) {
        expect(await controller.tap(), isFalse);
      }
      expect(checks, 1);
      developer = true;
      await tapNine();
      expect(checks, 1);
      expect(await controller.tap(), isTrue);
      expect(checks, 2);
    },
  );

  test(
    'sign-out discards partial taps even when the same admin signs in',
    () async {
      await tapNine();
      user = null;
      developer = false;
      controller.reset();
      user = 'admin';
      for (var i = 0; i < 10; i++) {
        expect(await controller.tap(), isFalse);
      }
      expect(checks, 0);
      developer = true;
      await tapNine();
      expect(checks, 0);
      expect(await controller.tap(), isTrue);
    },
  );

  testWidgets(
    'sign-out disables developer mode and keeps it disabled on reload',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final access = DeveloperAccessController.instance;
      final previousAccess = access.hasAccess;
      access.setAccess(true);
      addTearDown(() => access.setAccess(previousAccess));
      await tester.pumpWidget(
        MaterialApp(
          home: const SettingsScreen(),
          routes: {
            AppRoutes.login: (_) => const Scaffold(body: Text('Signed out')),
          },
        ),
      );
      await tester.ensureVisible(find.text('Đăng xuất'));
      await tester.tap(find.text('Đăng xuất'));
      await tester.pumpAndSettle();
      expect(find.text('Signed out'), findsOneWidget);
      expect(access.hasAccess, isFalse);
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getBool('developer_access'), isFalse);
      await access.load();
      expect(access.hasAccess, isFalse);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
      expect(find.text('Chế độ nhà phát triển'), findsNothing);
      for (var i = 0; i < 29; i++) {
        await tester.tap(find.text('Phiên bản ứng dụng'));
        await tester.pump();
      }
      expect(access.hasAccess, isFalse);
      await tester.tap(find.text('Phiên bản ứng dụng'));
      await tester.pump();
      expect(access.hasAccess, isTrue);
    },
  );

  test('ordinary accounts are refused with an explicit error', () async {
    allowed = false;
    await tapNine();
    await expectLater(controller.tap(), throwsStateError);
    expect(controller.isActive, isFalse);
    expect(modes, [false]);
    expect(controller.isBusy, isFalse);
  });

  test('membership errors are surfaced and do not activate', () async {
    checkOverride = (_) async => throw StateError('offline');
    await tapNine();
    await expectLater(controller.tap(), throwsStateError);
    expect(controller.isActive, isFalse);
    expect(controller.isBusy, isFalse);
  });

  test('changing accounts resets the tap count', () async {
    await tapNine();
    user = 'another-admin';
    expect(await controller.tap(), isFalse);
    expect(checks, 0);
    for (var i = 0; i < 8; i++) {
      await controller.tap();
    }
    expect(await controller.tap(), isTrue);
  });

  test(
    'deactivation resets the count and requires verification again',
    () async {
      await tapNine();
      await controller.deactivate();
      await tapNine();
      expect(checks, 0);
      await controller.tap();
      await controller.deactivate();
      expect(controller.isActive, isFalse);
      expect(modes, [false, true, false]);
      await tapNine();
      await controller.tap();
      expect(checks, 2);
    },
  );

  test('revocation while verifying prevents late activation', () async {
    final permission = Completer<bool>();
    checkOverride = (_) => permission.future;
    await tapNine();
    final activation = controller.tap();
    expect(controller.isBusy, isTrue);
    await controller.tap();
    expect(checks, 1);
    developer = false;
    await controller.deactivate();
    permission.complete(true);
    expect(await activation, isFalse);
    expect(controller.isActive, isFalse);
    expect(modes, [false]);
  });

  test('account changes during verification prevent activation', () async {
    final permission = Completer<bool>();
    checkOverride = (_) => permission.future;
    await tapNine();
    final activation = controller.tap();
    user = 'different-user';
    permission.complete(true);
    expect(await activation, isFalse);
    expect(modes, isEmpty);
  });

  test('loading errors roll back admin mode', () async {
    modeOverride = (active) async {
      if (active) throw StateError('devices failed');
    };
    await tapNine();
    await expectLater(controller.tap(), throwsStateError);
    expect(modes, [true, false]);
    expect(controller.isActive, isFalse);
  });

  test('revocation during loading rolls back the pending activation', () async {
    final loading = Completer<void>();
    modeOverride = (active) async {
      if (active) await loading.future;
    };
    await tapNine();
    final activation = controller.tap();
    await pumpEventQueue();
    await controller.deactivate();
    loading.complete();
    expect(await activation, isFalse);
    expect(controller.isActive, isFalse);
    expect(modes, [true, false, false]);
  });

  testWidgets('ten taps anywhere on the MQTT strip activate admin', (
    tester,
  ) async {
    final manager = MqttSessionManager.test(
      devices: {},
      publisher: (_, _) async {},
    );
    addTearDown(manager.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ListenableBuilder(
              listenable: controller,
              builder: (_, _) => MqttConnectionStatus(
                manager: manager,
                adminActive: controller.isActive,
                adminBusy: controller.isBusy,
                onTap: () async {
                  await controller.tap();
                },
                onExitAdmin: controller.deactivate,
              ),
            ),
          ),
        ),
      ),
    );
    final strip = find.byKey(const ValueKey('mqtt-connection-status'));
    for (var i = 0; i < 9; i++) {
      await tester.tapAt(tester.getTopRight(strip) + const Offset(-3, 3));
      await tester.pump();
    }
    expect(controller.isActive, isFalse);
    await tester.tapAt(tester.getTopRight(strip) + const Offset(-3, 3));
    await tester.pumpAndSettle();
    expect(controller.isActive, isTrue);
    expect(find.text('ADMIN · MQTT · Đã kết nối · 0 thiết bị'), findsOneWidget);
    await tester.tap(find.byTooltip('Thoát chế độ quản trị'));
    await tester.pumpAndSettle();
    expect(controller.isActive, isFalse);
    expect(find.text('MQTT · Đã kết nối · 0 thiết bị'), findsOneWidget);
  });
}

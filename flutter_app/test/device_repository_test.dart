import 'dart:async';
import 'dart:convert';

import 'package:flutter_app/models/device_record.dart';
import 'package:flutter_app/services/device_repository.dart';
import 'package:flutter_app/state/developer_access_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, Object?> _row(String mac, {String? name}) => {
  'id': '123e4567-e89b-12d3-a456-4266141740${mac.substring(0, 2)}',
  'user_id': 'u1',
  'mac_address': mac,
  'name': name,
  'max_sensor_count': 9,
  'max_load_count': 4,
  'created_at': '2026-10-12T10:00:00+00:00',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Map<String, String> cache;
  late List<List<DeviceRecord>> synced;

  DeviceRepository build({
    required DeviceRowsFetcher fetch,
    String? userId = 'u1',
  }) => DeviceRepository(
    fetchRows: fetch,
    readCache: (user) async => cache[user],
    writeCache: (user, json) async => cache[user] = json,
    syncMqtt: (user, devices) async => synced.add(devices),
    currentUserId: () => userId,
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final previousAccess = DeveloperAccessController.instance.hasAccess;
    DeveloperAccessController.instance.setAccess(true);
    addTearDown(
      () => DeveloperAccessController.instance.setAccess(previousAccess),
    );
    cache = {};
    synced = [];
  });

  test('loads devices from the database, caches them and syncs MQTT', () async {
    final repo = build(
      fetch: (_) async => [
        _row('aabbccddeeff', name: 'Ao 1'),
        _row('112233445566'),
      ],
    );
    await repo.refresh();
    await pumpEventQueue();

    expect(repo.error, isNull);
    expect(repo.fromCache, isFalse);
    expect(repo.devices.map((d) => d.name), ['Ao 1', '112233445566']);
    expect(jsonDecode(cache['u1']!), hasLength(2));
    expect(synced.single.map((d) => d.macAddress), [
      'aabbccddeeff',
      '112233445566',
    ]);
  });

  test('falls back to the cached list when the database fails', () async {
    var fail = false;
    final repo = build(
      fetch: (_) async {
        if (fail) throw StateError('offline');
        return [_row('aabbccddeeff', name: 'Ao 1')];
      },
    );
    await repo.refresh();
    fail = true;

    final reloaded = build(fetch: (_) async => throw StateError('offline'));
    await reloaded.refresh();
    await pumpEventQueue();

    expect(reloaded.error, contains('offline'));
    expect(reloaded.fromCache, isTrue);
    expect(reloaded.devices.single.name, 'Ao 1');
    expect(synced, hasLength(1), reason: 'no MQTT sync from stale data');
  });

  test('reports the error when there is neither database nor cache', () async {
    final repo = build(fetch: (_) async => throw StateError('offline'));
    await repo.refresh();

    expect(repo.devices, isEmpty);
    expect(repo.error, isNotNull);
    expect(repo.hasLoaded, isTrue);
  });

  test('one malformed row does not hide the other devices', () async {
    final repo = build(
      fetch: (_) async => [
        {'id': null, 'mac_address': 'bad'},
        _row('aabbccddeeff'),
      ],
    );
    await repo.refresh();

    expect(repo.error, isNull);
    expect(repo.devices.single.macAddress, 'aabbccddeeff');
  });

  test('requires a signed-in user', () async {
    final repo = build(fetch: (_) async => [], userId: null);
    await repo.refresh();

    expect(repo.error, contains('đăng nhập'));
  });

  test(
    'concurrent refreshes share one request and clear resets state',
    () async {
      var calls = 0;
      final repo = build(
        fetch: (_) async {
          calls++;
          return [_row('aabbccddeeff')];
        },
      );
      await Future.wait([repo.refresh(), repo.refresh()]);
      expect(calls, 1);

      repo.clear();
      expect(repo.devices, isEmpty);
      expect(repo.hasLoaded, isFalse);
    },
  );

  DeviceRepository adminRepository({
    Future<List<Map<String, Object?>>> Function()? allRows,
    DeviceRowsFetcher? ownRows,
  }) => DeviceRepository(
    fetchRows: ownRows ?? (_) async => [_row('aabbccddeeff')],
    fetchAllRows:
        allRows ??
        () async => [
          _row('aabbccddeeff'),
          {..._row('112233445566'), 'user_id': 'other-owner'},
        ],
    readCache: (user) async => cache[user],
    writeCache: (user, json) async => cache[user] = json,
    syncMqtt: (user, devices) async => synced.add(devices),
    resetMqtt: () async {},
    currentUserId: () => 'u1',
  );

  test(
    'admin loads all owners without polluting the owned-device cache',
    () async {
      final repo = adminRepository();
      await repo.refresh();
      final ownCache = cache['u1'];
      await repo.setAdminMode(true);
      expect(repo.isAdminMode, isTrue);
      expect(repo.devices.map((d) => d.userId), ['u1', 'other-owner']);
      expect(synced.last.map((d) => d.userId), ['u1', 'other-owner']);
      expect(cache['u1'], ownCache);
      await repo.setAdminMode(false);
      expect(repo.isAdminMode, isFalse);
      expect(repo.devices.single.userId, 'u1');
      expect(synced.last, hasLength(1));
    },
  );

  test(
    'admin failures are explicit and never fall back to the owner cache',
    () async {
      final repo = adminRepository(
        allRows: () async => throw StateError('offline'),
      );
      await repo.refresh();
      await expectLater(repo.setAdminMode(true), throwsStateError);
      expect(repo.devices, isEmpty);
      expect(repo.error, contains('offline'));
      expect(synced, hasLength(1));
    },
  );

  test(
    'an admin row without an owner is not routed as the signed-in user',
    () async {
      final repo = adminRepository(
        allRows: () async => [
          {..._row('112233445566'), 'user_id': null},
        ],
      );
      await expectLater(repo.setAdminMode(true), throwsStateError);
      expect(repo.devices, isEmpty);
      expect(synced, isEmpty);
    },
  );

  test(
    'clear prevents an in-flight response from restoring data or MQTT',
    () async {
      final response = Completer<List<Map<String, Object?>>>();
      final repo = adminRepository(ownRows: (_) => response.future);
      final refresh = repo.refresh();
      repo.clear();
      response.complete([_row('aabbccddeeff')]);
      await refresh;
      expect(repo.devices, isEmpty);
      expect(cache, isEmpty);
      expect(synced, isEmpty);
      expect(repo.hasLoaded, isFalse);
    },
  );

  test('disabling during an admin fetch discards foreign devices', () async {
    final response = Completer<List<Map<String, Object?>>>();
    final repo = adminRepository(allRows: () => response.future);
    final activation = repo.setAdminMode(true);
    await pumpEventQueue();
    final deactivation = repo.setAdminMode(false);
    response.complete([
      {..._row('112233445566'), 'user_id': 'other-owner'},
    ]);
    await Future.wait([activation, deactivation]);
    expect(repo.isAdminMode, isFalse);
    expect(repo.devices.single.userId, 'u1');
    expect(synced, hasLength(1));
    expect(synced.single.single.userId, 'u1');
  });

  test('device ownership survives serialization', () {
    final device = DeviceRecord.fromJson({
      ..._row('112233445566'),
      'user_id': 'other-owner',
    });
    expect(DeviceRecord.fromJson(device.toJson()).userId, 'other-owner');
  });
}

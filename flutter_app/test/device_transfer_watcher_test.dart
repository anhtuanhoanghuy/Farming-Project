import 'dart:async';

import 'package:flutter_app/services/crud_api.dart';
import 'package:flutter_app/services/device_repository.dart';
import 'package:flutter_app/services/device_transfer_watcher.dart';
import 'package:flutter_test/flutter_test.dart';

const _mac = 'aabbccddeeff';

Map<String, Object?> _row(String mac) => {
  'id': '123e4567-e89b-12d3-a456-4266141740${mac.substring(0, 2)}',
  'user_id': 'u1',
  'mac_address': mac,
  'name': 'Ao 1',
  'max_sensor_count': 9,
  'max_load_count': 4,
  'created_at': '2026-10-12T10:00:00+00:00',
};

Map<String, dynamic> _notice(Object id, String mac) => {
  'id': id,
  'user_id': 'u1',
  'mac_address': mac,
  'created_at': '2026-10-16T11:00:00+00:00',
};

void main() {
  late List<Map<String, Object?>> database;
  late DeviceRepository repository;
  late StreamController<List<Map<String, dynamic>>> notices;
  late List<Object> deleted;
  late List<String> forgotten;
  late List<String> messages;
  late List<String> transfers;
  late DeviceTransferWatcher watcher;
  var failRefresh = false;

  setUp(() async {
    failRefresh = false;
    database = [_row(_mac)];
    repository = DeviceRepository(
      fetchRows: (_) async {
        if (failRefresh) throw StateError('offline');
        return database;
      },
      readCache: (_) async => null,
      writeCache: (_, _) async {},
      syncMqtt: (_, _) async {},
      currentUserId: () => 'u1',
    );
    await repository.refresh();
    notices = StreamController<List<Map<String, dynamic>>>.broadcast();
    deleted = [];
    forgotten = [];
    messages = [];
    transfers = [];
    watcher = DeviceTransferWatcher(
      notices: (_) => notices.stream,
      deleteNotice: (id) async => deleted.add(id),
      repository: repository,
      forgetDevice: (mac) async => forgotten.add(mac),
      announce: messages.add,
    );
    watcher.transfers.listen(transfers.add);
    watcher.start('u1');
  });

  tearDown(() async {
    watcher.stop();
    await notices.close();
  });

  test(
    'a notice for a device the database no longer lists removes it',
    () async {
      database = [];
      notices.add([_notice(1, _mac)]);
      await pumpEventQueue();

      expect(repository.devices, isEmpty);
      expect(forgotten, [_mac]);
      expect(transfers, [_mac]);
      expect(messages.single, contains('Ao 1'));
      expect(messages.single, contains('không còn thuộc tài khoản này'));
      expect(deleted, [1]);
    },
  );

  test('a stale notice is dropped when the device is owned again', () async {
    notices.add([_notice(2, _mac)]);
    await pumpEventQueue();

    expect(repository.devices, hasLength(1));
    expect(forgotten, isEmpty);
    expect(transfers, isEmpty);
    expect(messages, isEmpty);
    expect(deleted, [2]);
  });

  test('the same notice is handled once', () async {
    database = [];
    notices.add([_notice(3, _mac)]);
    await pumpEventQueue();
    notices.add([_notice(3, _mac)]);
    await pumpEventQueue();

    expect(messages, hasLength(1));
    expect(deleted, [3]);
  });

  test('without a reliable database answer the notice is kept', () async {
    failRefresh = true;
    notices.add([_notice(4, _mac)]);
    await pumpEventQueue();

    expect(messages, isEmpty);
    expect(forgotten, isEmpty);
    expect(deleted, isEmpty);

    failRefresh = false;
    database = [];
    notices.add([_notice(4, _mac)]);
    await pumpEventQueue();
    expect(messages, hasLength(1));
    expect(deleted, [4]);
  });

  group('claim_device arguments', () {
    test('accept a lowercase MAC, a name and non-negative capacities', () {
      expect(
        CrudApi.validateClaim(
          macAddress: _mac,
          name: 'Ao 1',
          maxSensorCount: 9,
          maxLoadCount: 4,
        ),
        isEmpty,
      );
    });

    test('reject a bad MAC, an empty name and negative capacities', () {
      final problems = CrudApi.validateClaim(
        macAddress: 'AA:BB',
        name: '',
        maxSensorCount: -1,
        maxLoadCount: -1,
      );
      expect(problems, hasLength(4));
    });
  });
}

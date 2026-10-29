import 'package:flutter_app/services/crud_api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const uuid = '123e4567-e89b-12d3-a456-426614174000';

  test('device insert matches the devices table columns', () {
    final problems = CrudApi.validate('INSERT', 'devices', {
      'user_id': uuid,
      'mac_address': 'a1b2c3d4e5f6',
      'name': 'PROV_ESP32_AABBCC',
      'max_sensor_count': 9,
      'max_load_count': 4,
    }, const {});
    expect(problems, isEmpty);
  });

  test('max counts are required for new device rows', () {
    final problems = CrudApi.validate('INSERT', 'devices', {
      'user_id': uuid,
      'mac_address': 'a1b2c3d4e5f6',
      'name': 'PROV_ESP32_AABBCC',
    }, const {});
    expect(problems.join('\n'), contains('values.max_sensor_count: thiếu'));
    expect(problems.join('\n'), contains('values.max_load_count: thiếu'));
  });

  test('the devices table no longer has active counts', () {
    expect(
      CrudApi.validate(
        'UPDATE',
        'devices',
        {'active_sensor_count': 0},
        const {'id': uuid},
      ).join('\n'),
      contains('values.active_sensor_count: cột không tồn tại'),
    );
  });

  test('the devices table has no internet_method column', () {
    expect(
      CrudApi.validate(
        'UPDATE',
        'devices',
        {'internet_method': 1},
        const {'id': uuid},
      ).join('\n'),
      contains('values.internet_method: cột không tồn tại'),
    );
  });

  test('old device payload is reported as mismatching the schema', () {
    final problems = CrudApi.validate('INSERT', 'devices', {
      'user_id': 'usr_99218472',
      'device_mac_address': 'a1b2c3d4e5f6',
      'default_name': 'x',
      'max_sensor_count': 4,
      'max_load_count': 4,
      'unknown_column': 'WIFI',
    }, const {});
    expect(problems.join('\n'), contains('values.user_id'));
    expect(problems.join('\n'), contains('values.device_mac_address'));
    expect(problems.join('\n'), contains('values.default_name'));
    expect(problems.join('\n'), contains('values.unknown_column'));
    expect(problems.join('\n'), contains('values.mac_address: thiếu'));
    expect(problems.join('\n'), contains('values.name: thiếu'));
  });

  test('configuration tables no longer exist in the schema', () {
    for (final table in [
      'sensors',
      'loads',
      'load_timers',
      'load_delay_timers',
      'automation_conditions',
    ]) {
      expect(
        CrudApi.validate('INSERT', table, const {}, const {}).join(),
        contains('không có trong schema'),
        reason: table,
      );
    }
  });
}

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../state/developer_access_controller.dart';
import 'auth_service.dart';

final appMessengerKey = GlobalKey<ScaffoldMessengerState>();
final appNavigatorKey = GlobalKey<NavigatorState>();

enum _Type { uuid, text, integer }

class _Col {
  const _Col(this.type, {this.serverGenerated = false});

  final _Type type;
  final bool serverGenerated;
}

/// Mirrors database.md. The database only keeps the `devices` table: sensors,
/// loads and automation live on the ESP32 and are read from its MQTT snapshot.
/// Max counts come from the device's BLE provisioning result.
const _schema = <String, Map<String, _Col>>{
  'devices': {
    'id': _Col(_Type.uuid, serverGenerated: true),
    'user_id': _Col(_Type.uuid),
    'mac_address': _Col(_Type.text),
    'name': _Col(_Type.text),
    'max_sensor_count': _Col(_Type.integer),
    'max_load_count': _Col(_Type.integer),
    'created_at': _Col(_Type.text, serverGenerated: true),
  },
};

final _uuidPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

bool _matches(_Type type, Object value) => switch (type) {
  _Type.uuid => value is String && _uuidPattern.hasMatch(value),
  _Type.text => value is String,
  _Type.integer => value is int,
};

class CrudException implements Exception {
  const CrudException(this.message);

  final String message;

  @override
  String toString() => message;
}

class _CrudEntry {
  const _CrudEntry({
    required this.title,
    required this.when,
    required this.requestJson,
    required this.responseJson,
    required this.problems,
    required this.error,
    required this.affected,
  });

  final String title;
  final String when;
  final String requestJson;
  final String responseJson;
  final List<String> problems;
  final String? error;
  final int affected;
}

class _CrudGroup {
  _CrudGroup(this.trigger);

  final String trigger;
  final entries = <_CrudEntry>[];
}

/// Backend CRUD requests against Supabase, which only holds the `devices`
/// table. Every CRUD is shown on screen (developer mode) with the action that
/// triggered it.
class CrudApi {
  CrudApi._();

  static SupabaseClient get _db => Supabase.instance.client;

  /// `devices.id` by MAC.
  static final _deviceUuids = <String, String>{};

  /// Supabase user id of the signed-in account (`devices.user_id`).
  static String get userId => AuthService.requireUserId();

  @visibleForTesting
  static List<String> validate(
    String operation,
    String table,
    Map<String, Object?> values,
    Map<String, Object?> match,
  ) {
    final columns = _schema[table];
    if (columns == null) return ['Bảng "$table" không có trong schema'];
    final problems = <String>[];

    void check(String scope, Map<String, Object?> data) {
      data.forEach((key, value) {
        final column = columns[key];
        if (column == null) {
          problems.add('$scope.$key: cột không tồn tại trong bảng $table');
        } else if (value == null) {
          problems.add('$scope.$key: không được null');
        } else if (!_matches(column.type, value)) {
          problems.add(
            '$scope.$key: sai kiểu/định dạng, cần ${column.type.name}, '
            'nhận ${value.runtimeType} ($value)',
          );
        }
      });
    }

    check('values', values);
    check('match', match);
    if (operation == 'INSERT' || operation == 'UPSERT') {
      for (final entry in columns.entries) {
        final column = entry.value;
        if (!column.serverGenerated && !values.containsKey(entry.key)) {
          problems.add('values.${entry.key}: thiếu cột bắt buộc');
        }
      }
    }
    return problems;
  }

  // ---------------------------------------------------------------- logging

  static _CrudGroup? _group;

  /// Runs CRUD calls and shows them in one dialog headed by [trigger], the
  /// action that made the code send them. Calls nested in a running group
  /// join it.
  static Future<T> run<T>(String trigger, Future<T> Function() body) async {
    if (_group != null) return body();
    final group = _group = _CrudGroup(trigger);
    try {
      return await body();
    } finally {
      _group = null;
      _showDialog(group);
    }
  }

  /// A line on screen explaining what the code decided about CRUD. Shown only
  /// while developer mode is on; it always goes to the debug console.
  static void note(String message) {
    debugPrint('[CRUD] $message');
    if (!DeveloperAccessController.instance.hasAccess) return;
    appMessengerKey.currentState
      ?..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 5),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  static void _showDialog(_CrudGroup group) {
    if (!DeveloperAccessController.instance.hasAccess) return;
    if (group.entries.isEmpty) {
      note('${group.trigger}\n→ không có request CRUD nào được gửi');
      return;
    }
    // The navigator key is global, so its overlay stays valid across awaits.
    final context = appNavigatorKey.currentState?.overlay?.context;
    if (context == null) return;
    showDialog<void>(
      // ignore: use_build_context_synchronously
      context: context,
      builder: (_) => _CrudDialog(group: group),
    );
  }

  // ------------------------------------------------------------- transport

  static Future<List<Map<String, dynamic>>> _execute(
    String operation,
    String table,
    Map<String, Object?> values,
    Map<String, Object?> match,
  ) async {
    final query = _db.from(table);
    switch (operation) {
      case 'SELECT':
        final rows = query.select().match(Map<String, Object>.from(match));
        return _schema[table]!.containsKey('created_at')
            ? rows.order('created_at', ascending: true)
            : rows;
      case 'INSERT':
        return query.insert(values).select();
      case 'UPDATE':
        return query
            .update(values)
            .match(Map<String, Object>.from(match))
            .select();
      case 'DELETE':
        return query.delete().match(Map<String, Object>.from(match)).select();
    }
    throw CrudException('Thao tác "$operation" không được hỗ trợ');
  }

  static Future<List<Map<String, dynamic>>> _send(
    String operation,
    String table, {
    Map<String, Object?> values = const {},
    Map<String, Object?> match = const {},
    required String when,
  }) async {
    if (_group == null) {
      return run(
        when,
        () => _send(operation, table, values: values, match: match, when: when),
      );
    }
    final request = <String, Object?>{
      'operation': operation,
      'table': table,
      if (match.isNotEmpty) 'match': match,
      if (values.isNotEmpty) 'values': values,
    };
    final problems = validate(operation, table, values, match);
    var rows = <Map<String, dynamic>>[];
    String? error;
    try {
      if (problems.isNotEmpty) {
        throw const CrudException(
          'Payload không khớp schema nên chưa gửi lên Supabase',
        );
      }
      rows = await _execute(operation, table, values, match);
    } on PostgrestException catch (e) {
      error = '${e.message} (code ${e.code})';
    } catch (e) {
      error = e.toString();
    }

    const encoder = JsonEncoder.withIndent('  ', _encodeUnknown);
    final entry = _CrudEntry(
      title: '$operation $table',
      when: when,
      requestJson: encoder.convert(request),
      responseJson: encoder.convert(rows),
      problems: problems,
      error: error,
      affected: rows.length,
    );
    debugPrint(
      '[CRUD] ${entry.title} | $when\n${entry.requestJson}\n'
      '${error != null ? 'LỖI: $error' : 'Phản hồi: ${entry.responseJson}'}',
    );
    _group!.entries.add(entry);
    if (error != null) throw CrudException(error);
    return rows;
  }

  static Future<Object?> _rpc(
    String function,
    Map<String, Object?> params, {
    required String when,
  }) async {
    if (_group == null) {
      return run(when, () => _rpc(function, params, when: when));
    }
    Object? result;
    String? error;
    try {
      result = await _db.rpc(function, params: params);
    } on PostgrestException catch (e) {
      error = '${e.message} (code ${e.code})';
    } catch (e) {
      error = e.toString();
    }

    const encoder = JsonEncoder.withIndent('  ', _encodeUnknown);
    final entry = _CrudEntry(
      title: 'RPC $function',
      when: when,
      requestJson: encoder.convert({'function': function, 'params': params}),
      responseJson: encoder.convert(result),
      problems: const [],
      error: error,
      affected: result == null ? 0 : 1,
    );
    debugPrint(
      '[CRUD] ${entry.title} | $when\n${entry.requestJson}\n'
      '${error != null ? 'LỖI: $error' : 'Phản hồi: ${entry.responseJson}'}',
    );
    _group!.entries.add(entry);
    if (error != null) throw CrudException(error);
    return result;
  }

  static Object? _encodeUnknown(Object? value) => value.toString();

  // --------------------------------------------------------------- devices

  /// Returns the `devices.id` UUID for a MAC address; null if not registered.
  static Future<String?> deviceUuid(String macAddress) async {
    final cached = _deviceUuids[macAddress];
    if (cached != null) return cached;
    final row = await _db
        .from('devices')
        .select('id')
        .eq('mac_address', macAddress)
        .maybeSingle();
    final id = row?['id'] as String?;
    if (id != null) _deviceUuids[macAddress] = id;
    return id;
  }

  /// True while CRUD calls are being recorded for the on-screen log.
  static bool get isRecording => _group != null;

  /// Rows of `devices` owned by [ownerId], oldest first.
  static Future<List<Map<String, dynamic>>> listDevices(String ownerId) =>
      _send(
        'SELECT',
        'devices',
        match: {'user_id': ownerId},
        when: 'tải lại danh sách thiết bị',
      );

  static final _macPattern = RegExp(r'^[0-9a-f]{12}$');

  @visibleForTesting
  static List<String> validateClaim({
    required String macAddress,
    required String name,
    required int maxSensorCount,
    required int maxLoadCount,
  }) => [
    if (!_macPattern.hasMatch(macAddress))
      'mac_address: cần 12 ký tự hex thường, nhận "$macAddress"',
    if (name.isEmpty || name.length > claimNameMaxLength)
      'name: cần 1–$claimNameMaxLength ký tự',
    if (maxSensorCount < 0) 'max_sensor_count: không được âm',
    if (maxLoadCount < 0) 'max_load_count: không được âm',
  ];

  static const claimNameMaxLength = 64;

  /// Registers the device for the signed-in user through the `claim_device`
  /// RPC. A MAC that belongs to another account moves to this one: the server
  /// takes `auth.uid()` as the new owner and notifies the previous owner.
  /// The network in use is not stored: the ESP32 reports it in its MQTT
  /// snapshot and telemetry. Capacities come from BLE provisioning.
  static Future<void> addDevice({
    required String macAddress,
    required String name,
    required int maxSensorCount,
    required int maxLoadCount,
  }) async {
    final mac = macAddress.trim().toLowerCase();
    var cleanName = name.trim();
    if (cleanName.length > claimNameMaxLength) {
      cleanName = cleanName.substring(0, claimNameMaxLength);
    }
    final problems = validateClaim(
      macAddress: mac,
      name: cleanName,
      maxSensorCount: maxSensorCount,
      maxLoadCount: maxLoadCount,
    );
    if (problems.isNotEmpty) throw CrudException(problems.join('; '));
    final result = await _rpc('claim_device', {
      'p_mac_address': mac,
      'p_name': cleanName,
      'p_max_sensor_count': maxSensorCount,
      'p_max_load_count': maxLoadCount,
    }, when: 'đăng ký thiết bị hoặc nhận chuyển quyền sở hữu');
    final row = result is List ? result.firstOrNull : result;
    final id = row is Map ? row['id'] : null;
    if (id is String) _deviceUuids[mac] = id;
  }

  /// Transfer notices addressed to the signed-in account (previous owner).
  static Stream<List<Map<String, dynamic>>> transferNotices(String ownerId) =>
      _db
          .from('device_transfer_notices')
          .stream(primaryKey: ['id'])
          .eq('user_id', ownerId);

  static Future<void> deleteTransferNotice(Object id) async {
    await _db.from('device_transfer_notices').delete().eq('id', id);
  }

  static Future<void> renameDevice(String macAddress, String name) => _send(
    'UPDATE',
    'devices',
    match: {'mac_address': macAddress},
    values: {'name': name},
    when: 'đổi tên thiết bị',
  );

  static Future<void> deleteDevice(String macAddress) async {
    await _send(
      'DELETE',
      'devices',
      match: {'mac_address': macAddress},
      when: 'xóa thiết bị',
    );
    _deviceUuids.remove(macAddress);
  }
}

class _CrudDialog extends StatelessWidget {
  const _CrudDialog({required this.group});

  final _CrudGroup group;

  static const _mono = TextStyle(fontFamily: 'monospace', fontSize: 12);

  String get _copyText => [
    group.trigger,
    for (final e in group.entries)
      '--- ${e.title} (${e.when})\nREQUEST\n${e.requestJson}\n'
          '${e.error != null ? 'ERROR\n${e.error}' : 'RESPONSE\n${e.responseJson}'}',
  ].join('\n\n');

  @override
  Widget build(BuildContext context) {
    final failed = group.entries.any((e) => e.error != null);
    return AlertDialog(
      title: Text(failed ? '[CRUD] ✗ Có lỗi' : '[CRUD] ✓ Đã gửi'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Kích hoạt bởi',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              Text(group.trigger),
              for (final entry in group.entries) ...[
                const Divider(height: 24),
                _EntryView(entry: entry),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Clipboard.setData(ClipboardData(text: _copyText)),
          child: const Text('Sao chép JSON'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Đóng'),
        ),
      ],
    );
  }
}

class _EntryView extends StatelessWidget {
  const _EntryView({required this.entry});

  final _CrudEntry entry;

  @override
  Widget build(BuildContext context) {
    final failed = entry.error != null;
    final String status;
    if (failed) {
      status = '✗ Thất bại';
    } else if (entry.affected == 0) {
      status = '⚠ Thành công nhưng 0 dòng bị ảnh hưởng';
    } else {
      status = '✓ Thành công, ${entry.affected} dòng';
    }
    final color = failed
        ? Colors.red.shade700
        : entry.affected == 0
        ? Colors.orange.shade800
        : Colors.green.shade700;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(entry.title, style: const TextStyle(fontWeight: FontWeight.w700)),
        Text(entry.when, style: const TextStyle(fontSize: 12)),
        const SizedBox(height: 4),
        Text(
          status,
          style: TextStyle(fontWeight: FontWeight.w700, color: color),
        ),
        if (failed)
          SelectableText(
            entry.error!,
            style: TextStyle(color: Colors.red.shade700, fontSize: 12),
          ),
        for (final problem in entry.problems)
          Text(
            '• $problem',
            style: TextStyle(color: Colors.red.shade700, fontSize: 12),
          ),
        const SizedBox(height: 6),
        const Text('Yêu cầu', style: TextStyle(fontWeight: FontWeight.w600)),
        SelectableText(entry.requestJson, style: _CrudDialog._mono),
        if (!failed) ...[
          const SizedBox(height: 6),
          const Text(
            'Phản hồi từ Supabase',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          SelectableText(entry.responseJson, style: _CrudDialog._mono),
        ],
      ],
    );
  }
}

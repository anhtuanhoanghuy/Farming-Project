import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/error_text.dart';
import '../models/device_record.dart';
import 'auth_service.dart';
import 'crud_api.dart';
import 'mqtt_session_manager.dart';

typedef DeviceRowsFetcher =
    Future<List<Map<String, Object?>>> Function(String userId);
typedef DeviceCacheReader = Future<String?> Function(String userId);
typedef DeviceCacheWriter = Future<void> Function(String userId, String json);
typedef DeviceMqttSync =
    Future<void> Function(String userId, List<DeviceRecord> devices);

/// The signed-in user's devices. The Supabase `devices` table is the source of
/// truth; the last successful result is cached so the list still shows when
/// the network or database is unavailable.
class DeviceRepository extends ChangeNotifier {
  DeviceRepository({
    DeviceRowsFetcher? fetchRows,
    DeviceCacheReader? readCache,
    DeviceCacheWriter? writeCache,
    DeviceMqttSync? syncMqtt,
    String? Function()? currentUserId,
  }) : _fetchRows = fetchRows ?? _fetchFromSupabase,
       _readCache = readCache ?? _readPreferences,
       _writeCache = writeCache ?? _writePreferences,
       _syncMqtt = syncMqtt ?? _syncMqttSession,
       _currentUserId = currentUserId ?? (() => AuthService.userId);

  static final instance = DeviceRepository();

  final DeviceRowsFetcher _fetchRows;
  final DeviceCacheReader _readCache;
  final DeviceCacheWriter _writeCache;
  final DeviceMqttSync _syncMqtt;
  final String? Function() _currentUserId;

  List<DeviceRecord> _devices = const [];
  bool _loading = false;
  bool _hasLoaded = false;
  bool _fromCache = false;
  String? _error;
  Object? _errorCause;
  String? _ownerId;
  Future<void>? _inFlight;

  List<DeviceRecord> get devices => _devices;
  bool get isLoading => _loading;

  /// True once a refresh finished (successfully or not).
  bool get hasLoaded => _hasLoaded;

  /// True when [devices] came from the on-device cache, not from the database.
  bool get fromCache => _fromCache;
  String? get error => _error == null
      ? null
      : _errorCause == null
      ? _error
      : userErrorText(_error!, _errorCause!);

  /// Reloads from the database. Concurrent calls share one request.
  Future<void> refresh() => _inFlight ??= _refresh().whenComplete(() {
    _inFlight = null;
  });

  /// Forgets the current user's data, e.g. after sign-out.
  void clear() {
    _devices = const [];
    _loading = false;
    _hasLoaded = false;
    _fromCache = false;
    _error = null;
    _errorCause = null;
    _ownerId = null;
    notifyListeners();
  }

  /// Removes a device locally after its database deletion succeeds.
  Future<void> removeDevice(String macAddress) async {
    final remaining = _devices
        .where((device) => device.macAddress != macAddress)
        .toList(growable: false);
    if (remaining.length == _devices.length) return;
    _devices = remaining;
    final userId = _ownerId;
    if (userId != null) {
      await _writeCache(
        userId,
        jsonEncode([for (final device in remaining) device.toJson()]),
      );
    }
    notifyListeners();
  }

  Future<void> _refresh() async {
    final userId = _currentUserId();
    if (userId == null) {
      _devices = const [];
      _ownerId = null;
      _fromCache = false;
      _error = 'Chưa đăng nhập Supabase.';
      _errorCause = null;
      _hasLoaded = true;
      notifyListeners();
      return;
    }
    if (_ownerId != userId) {
      _devices = const [];
      _ownerId = userId;
    }
    _loading = true;
    notifyListeners();
    try {
      final rows = await _fetchRows(userId);
      final parsed = <DeviceRecord>[];
      for (final row in rows) {
        try {
          parsed.add(DeviceRecord.fromJson(row));
        } on FormatException catch (e) {
          debugPrint('[Devices] Bỏ qua dòng không hợp lệ: ${e.message}');
        }
      }
      _devices = parsed;
      _fromCache = false;
      _error = null;
      await _writeCache(
        userId,
        jsonEncode([for (final d in parsed) d.toJson()]),
      );
    } catch (e) {
      _error = 'Không tải được danh sách thiết bị';
      _errorCause = e;
      if (_devices.isEmpty) {
        _devices = await _loadCache(userId);
        _fromCache = _devices.isNotEmpty;
      } else {
        _fromCache = true;
      }
    } finally {
      _loading = false;
      _hasLoaded = true;
      notifyListeners();
    }
    if (_error == null) unawaited(_syncMqttSafely(userId, _devices));
  }

  Future<void> _syncMqttSafely(
    String userId,
    List<DeviceRecord> devices,
  ) async {
    try {
      await _syncMqtt(userId, devices);
    } catch (e) {
      debugPrint('[Devices] Đồng bộ MQTT thất bại: $e');
    }
  }

  Future<List<DeviceRecord>> _loadCache(String userId) async {
    try {
      final raw = await _readCache(userId);
      if (raw == null) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final item in decoded)
          if (item is Map)
            DeviceRecord.fromJson(Map<String, Object?>.from(item)),
      ];
    } catch (e) {
      debugPrint('[Devices] Cache không đọc được: $e');
      return const [];
    }
  }

  /// Reads the rows directly, or through [CrudApi] (shown in the CRUD log)
  /// when an action such as pull-to-refresh is recording CRUD calls.
  static Future<List<Map<String, Object?>>> _fetchFromSupabase(
    String userId,
  ) async {
    final rows = CrudApi.isRecording
        ? await CrudApi.listDevices(userId)
        : await Supabase.instance.client
              .from('devices')
              .select()
              .eq('user_id', userId)
              .order('created_at');
    return [for (final row in rows) Map<String, Object?>.from(row)];
  }

  static String _cacheKey(String userId) => 'devices.cache.$userId';

  static Future<String?> _readPreferences(String userId) async =>
      (await SharedPreferences.getInstance()).getString(_cacheKey(userId));

  static Future<void> _writePreferences(String userId, String json) async {
    await (await SharedPreferences.getInstance()).setString(
      _cacheKey(userId),
      json,
    );
  }

  /// Subscribes MQTT to exactly the devices in the database.
  static Future<void> _syncMqttSession(
    String userId,
    List<DeviceRecord> devices,
  ) async {
    final manager = MqttSessionManager.instance;
    await manager.startForUser(userId);
    final wanted = {for (final d in devices) d.macAddress};
    for (final device in devices) {
      await manager.addDevice(device.macAddress, name: device.name);
    }
    for (final stale in manager.deviceIds.difference(wanted)) {
      await manager.removeDevice(stale);
    }
  }
}

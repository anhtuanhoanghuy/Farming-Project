import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/error_text.dart';
import '../models/device_record.dart';
import '../state/device_health.dart';
import '../state/device_state.dart';
import '../state/load_controller.dart';
import 'auth_service.dart';
import 'crud_api.dart';
import 'mqtt_session_manager.dart';
import 'load_sync.dart';
import 'traffic_log.dart';

typedef DeviceRowsFetcher =
    Future<List<Map<String, Object?>>> Function(String userId);
typedef DeviceCacheReader = Future<String?> Function(String userId);
typedef DeviceCacheWriter = Future<void> Function(String userId, String json);
typedef DeviceMqttSync =
    Future<void> Function(String userId, List<DeviceRecord> devices);

/// Owned devices, or all RLS-visible devices in admin mode. Only the owned
/// list is cached for use when the network or database is unavailable.
class DeviceRepository extends ChangeNotifier {
  DeviceRepository({
    DeviceRowsFetcher? fetchRows,
    Future<List<Map<String, Object?>>> Function()? fetchAllRows,
    DeviceCacheReader? readCache,
    DeviceCacheWriter? writeCache,
    DeviceMqttSync? syncMqtt,
    String? Function()? currentUserId,
    Future<void> Function()? resetMqtt,
  }) : _fetchRows = fetchRows ?? _fetchFromSupabase,
       _fetchAllRows = fetchAllRows ?? (() => _fetchFromSupabase(null)),
       _readCache = readCache ?? _readPreferences,
       _writeCache = writeCache ?? _writePreferences,
       _syncMqtt = syncMqtt,
       _currentUserId = currentUserId ?? (() => AuthService.userId),
       _resetMqtt = resetMqtt ?? _resetMqttSession;

  static final instance = DeviceRepository();

  final DeviceRowsFetcher _fetchRows;
  final Future<List<Map<String, Object?>>> Function() _fetchAllRows;
  final DeviceCacheReader _readCache;
  final DeviceCacheWriter _writeCache;
  final DeviceMqttSync? _syncMqtt;
  final String? Function() _currentUserId;
  final Future<void> Function() _resetMqtt;

  List<DeviceRecord> _devices = const [];
  bool _loading = false;
  bool _hasLoaded = false;
  bool _fromCache = false;
  String? _error;
  Object? _errorCause;
  String? _ownerId;
  Future<void>? _inFlight;
  Future<void> _modeTransition = Future.value();
  bool _changingMode = false;
  bool _adminMode = false;
  int _generation = 0;

  bool get isAdminMode => _adminMode;

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
  Future<void> refresh() {
    if (_changingMode) return _modeTransition;
    return _startRefresh();
  }

  Future<void> _startRefresh() {
    if (_inFlight != null) return _inFlight!;
    final future = _refresh();
    _inFlight = future;
    return future.whenComplete(() {
      if (identical(_inFlight, future)) _inFlight = null;
    });
  }

  Future<void> setAdminMode(bool enabled) {
    if (_adminMode == enabled && !_changingMode) return Future.value();
    final pendingRefresh = _inFlight;
    clear();
    _adminMode = enabled;
    _changingMode = true;
    final generation = _generation;
    final operation = _modeTransition
        .then((_) async {
          await pendingRefresh;
          if (generation != _generation) return;
          await _resetMqtt();
          if (generation != _generation) return;
          await _startRefresh();
          if (generation == _generation && _error != null) {
            throw StateError(error!);
          }
        })
        .whenComplete(() {
          if (generation == _generation) {
            _changingMode = false;
            notifyListeners();
          }
        });
    _modeTransition = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('[Devices] Không chuyển được chế độ quản trị: $error');
      },
    );
    return operation;
  }

  Future<void> endSession() async {
    clear();
    await _resetMqtt();
  }

  /// Forgets the current user's data, e.g. after sign-out.
  void clear() {
    _generation++;
    _inFlight = null;
    _adminMode = false;
    _changingMode = false;
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
    if (userId != null && !_adminMode) {
      await _writeCache(
        userId,
        jsonEncode([for (final device in remaining) device.toJson()]),
      );
    }
    notifyListeners();
  }

  Future<void> _refresh() async {
    final generation = _generation;
    final adminMode = _adminMode;
    final userId = _currentUserId();
    bool isCurrent() => generation == _generation && _currentUserId() == userId;
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
      final rows = await (adminMode ? _fetchAllRows() : _fetchRows(userId));
      if (!isCurrent()) return;
      final parsed = <DeviceRecord>[];
      for (final row in rows) {
        try {
          final device = DeviceRecord.fromJson(row);
          if (adminMode && (device.userId == null || device.userId!.isEmpty)) {
            throw const FormatException('Thiết bị thiếu user_id chủ sở hữu');
          }
          parsed.add(device);
        } on FormatException catch (e) {
          if (adminMode) rethrow;
          debugPrint('[Devices] Bỏ qua dòng không hợp lệ: ${e.message}');
        }
      }
      _devices = parsed;
      _fromCache = false;
      _error = null;
      if (!adminMode) {
        await _writeCache(
          userId,
          jsonEncode([for (final d in parsed) d.toJson()]),
        );
      }
    } catch (e) {
      if (!isCurrent()) return;
      _error = 'Không tải được danh sách thiết bị';
      _errorCause = e;
      if (_devices.isEmpty && !adminMode) {
        final cached = await _loadCache(userId);
        if (!isCurrent()) return;
        _devices = cached;
        _fromCache = _devices.isNotEmpty;
      } else {
        _fromCache = true;
      }
    } finally {
      if (isCurrent()) {
        _loading = false;
        _hasLoaded = true;
        notifyListeners();
      }
    }
    if (isCurrent() && _error == null) {
      await _syncMqttSafely(userId, _devices, generation);
    }
  }

  Future<void> _syncMqttSafely(
    String userId,
    List<DeviceRecord> devices,
    int generation,
  ) async {
    try {
      final sync = _syncMqtt;
      if (sync != null) {
        await sync(userId, devices);
      } else {
        await _syncMqttSession(userId, devices, generation);
      }
    } catch (e) {
      debugPrint('[Devices] Đồng bộ MQTT thất bại: $e');
      if (generation == _generation) {
        _error = 'Không đồng bộ được thiết bị với MQTT';
        _errorCause = e;
        notifyListeners();
      }
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
    String? userId,
  ) async {
    final rows = await CrudApi.listDevices(userId);
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
  Future<void> _syncMqttSession(
    String userId,
    List<DeviceRecord> devices,
    int generation,
  ) async {
    bool isCurrent() => generation == _generation && _currentUserId() == userId;
    if (!isCurrent()) return;
    final manager = MqttSessionManager.instance;
    await manager.startForUser(userId);
    if (!isCurrent()) return;
    final wanted = {for (final d in devices) d.macAddress};
    for (final device in devices) {
      if (!isCurrent()) return;
      await manager.addDevice(
        device.macAddress,
        name: device.name,
        ownerUserId: device.userId ?? userId,
      );
    }
    for (final stale in manager.deviceIds.difference(wanted)) {
      if (!isCurrent()) return;
      final foreign = manager.ownerUserId(stale) != userId;
      await manager.removeDevice(stale);
      if (foreign) {
        await DeviceHealth.instance.deleteDevice(stale);
        TrafficLog.instance.clear(stale);
      }
    }
  }

  static Future<void> _resetMqttSession() async {
    final manager = MqttSessionManager.instance;
    final foreignDevices = [
      for (final id in manager.deviceIds)
        if (manager.ownerUserId(id) != manager.userId) id,
    ];
    LoadSync.instance.detach();
    DeviceState.instance.reset(null);
    for (final load in LoadController.loads) {
      load.cancelDelay();
      load.markUnknown();
    }
    await manager.stop();
    TrafficLog.instance.clear();
    for (final id in foreignDevices) {
      await DeviceHealth.instance.deleteDevice(id);
    }
  }
}

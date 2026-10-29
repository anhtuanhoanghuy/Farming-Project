import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../protocol/device_errors.dart';
import '../protocol/mqtt_topics.dart';
import '../services/mqtt_session_manager.dart';

enum HealthKind {
  errorRaised,
  errorCleared,
  emergency,
  emergencyCleared,
  interlock,
  interlockCleared;

  /// True for the entries that report something going wrong.
  bool get isProblem =>
      this == errorRaised || this == emergency || this == interlock;
}

/// One line of the error log of a device.
class HealthEntry {
  const HealthEntry({
    required this.time,
    required this.kind,
    required this.message,
    this.code,
  });

  factory HealthEntry.fromJson(Map<String, Object?> json) => HealthEntry(
    time: DateTime.fromMillisecondsSinceEpoch(json['t']! as int),
    kind: HealthKind.values.byName(json['k']! as String),
    code: json['c'] as String?,
    message: json['m']! as String,
  );

  final DateTime time;
  final HealthKind kind;

  /// `SYS_ERR_*` for error entries.
  final String? code;
  final String message;

  Map<String, Object?> toJson() => {
    't': time.millisecondsSinceEpoch,
    'k': kind.name,
    'c': code,
    'm': message,
  };
}

class _DeviceHealthState {
  int mask = 0;
  bool emergency = false;
  bool interlock = false;
  bool loaded = false;
  final log = <HealthEntry>[];
  Future<void> chain = Future.value();
}

/// What each device reports about its own health, read from the `status`
/// topic (snapshots and events): the errors active now, and a log of every
/// error, emergency stop and interlock with the time it was noticed. The log
/// keeps the last [maxEntries] lines per device and survives app restarts.
class DeviceHealth extends ChangeNotifier {
  DeviceHealth({Stream<MqttDeviceMessage>? messages}) : _messages = messages;

  static final instance = DeviceHealth();

  static const maxEntries = 100;
  static const _keyPrefix = 'device_health.';

  final Stream<MqttDeviceMessage>? _messages;
  final _states = <String, _DeviceHealthState>{};
  StreamSubscription<MqttDeviceMessage>? _subscription;
  bool _started = false;

  /// Starts listening; safe to call many times.
  void start() {
    if (_started) return;
    _started = true;
    _subscription = (_messages ?? MqttSessionManager.instance.messages).listen(
      _onMessage,
    );
  }

  _DeviceHealthState _state(String deviceId) =>
      _states.putIfAbsent(deviceId, _DeviceHealthState.new);

  /// The `error_mask` the device last reported (0 when none or unknown).
  int maskOf(String deviceId) => _states[deviceId]?.mask ?? 0;

  bool hasErrors(String deviceId) => maskOf(deviceId) != 0;

  /// The log of [deviceId], newest first.
  List<HealthEntry> history(String deviceId) =>
      List.unmodifiable(_states[deviceId]?.log.reversed ?? const []);

  /// Loads the stored log of [deviceId] so it shows before any message
  /// arrives.
  Future<void> load(String deviceId) => _enqueue(deviceId, () async {});

  /// Empties the log of [deviceId].
  Future<void> clearHistory(String deviceId) => _enqueue(deviceId, () async {
    _state(deviceId).log.clear();
    await _save(deviceId);
  });

  /// Removes all locally stored health state for a deleted device.
  Future<void> deleteDevice(String deviceId) => _enqueue(deviceId, () async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove('$_keyPrefix$deviceId');
    _states.remove(deviceId);
    notifyListeners();
  });

  void _onMessage(MqttDeviceMessage message) {
    if (message.kind != MqttDeviceTopicKind.status) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(message.payload);
    } on FormatException {
      return;
    }
    if (decoded is Map) {
      unawaited(observe(message.deviceId, decoded, message.receivedAt));
    }
  }

  /// Takes one `status` message of [deviceId]: a snapshot gives the whole
  /// picture, an event only what it names.
  Future<void> observe(
    String deviceId,
    Map<dynamic, dynamic> json,
    DateTime receivedAt,
  ) {
    int? mask;
    bool? emergency;
    bool? interlock;
    var stopped = false;
    switch (json['type']) {
      case 'SNAPSHOT':
        final errors = json['errors'];
        final emergencyJson = json['emergency'];
        final interlockJson = json['interlock'];
        mask = errors is Map && errors['code_mask'] is num
            ? (errors['code_mask'] as num).toInt()
            : 0;
        emergency = emergencyJson is Map && emergencyJson['active'] == true;
        interlock = interlockJson is Map && interlockJson['tripped'] == true;
      case 'EVENT':
        switch (json['event']) {
          case 'ERRORS_CHANGED':
            if (json['code_mask'] is num) {
              mask = (json['code_mask'] as num).toInt();
            }
          case 'EMERGENCY_STOP':
            emergency = true;
            stopped = true;
          case 'INTERLOCK_TRIPPED':
            interlock = true;
          case 'INTERLOCK_CLEARED':
            interlock = false;
        }
      default:
        return Future.value();
    }
    if (mask == null && emergency == null && interlock == null) {
      return Future.value();
    }
    final ts = json['ts'];
    // The device clock is valid only once it has synchronised.
    final time = ts is num && ts > 1500000000000
        ? DateTime.fromMillisecondsSinceEpoch(ts.toInt())
        : receivedAt;
    return _enqueue(
      deviceId,
      () => _apply(deviceId, time, mask, emergency, interlock, stopped),
    );
  }

  /// Messages of one device are handled one after the other, because the
  /// stored state is read asynchronously.
  Future<void> _enqueue(String deviceId, Future<void> Function() job) {
    final state = _state(deviceId);
    return state.chain = state.chain.then((_) async {
      await _ensureLoaded(deviceId);
      await job();
    });
  }

  Future<void> _ensureLoaded(String deviceId) async {
    final state = _state(deviceId);
    if (state.loaded) return;
    state.loaded = true;
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString('$_keyPrefix$deviceId');
      if (raw == null) return;
      final json = jsonDecode(raw) as Map<String, dynamic>;
      state
        ..mask = (json['mask'] as num?)?.toInt() ?? 0
        ..emergency = json['emergency'] == true
        ..interlock = json['interlock'] == true;
      state.log.addAll([
        for (final item in json['log'] as List? ?? const [])
          HealthEntry.fromJson(Map<String, Object?>.from(item as Map)),
      ]);
      notifyListeners();
    } catch (error) {
      debugPrint('[Health] Không đọc được nhật ký lỗi của $deviceId: $error');
    }
  }

  Future<void> _apply(
    String deviceId,
    DateTime time,
    int? mask,
    bool? emergency,
    bool? interlock,
    bool stopped,
  ) async {
    final state = _state(deviceId);
    final added = <HealthEntry>[];

    if (mask != null && mask != state.mask) {
      for (final error in DeviceError.fromMask(mask & ~state.mask)) {
        added.add(
          HealthEntry(
            time: time,
            kind: HealthKind.errorRaised,
            code: error.code,
            message: '${error.title}. Nguyên nhân: ${error.cause}',
          ),
        );
      }
      for (final error in DeviceError.fromMask(state.mask & ~mask)) {
        added.add(
          HealthEntry(
            time: time,
            kind: HealthKind.errorCleared,
            code: error.code,
            message: '${error.title} đã hết.',
          ),
        );
      }
      state.mask = mask;
    }
    // Every emergency stop command is a line of its own, even when the device
    // was already stopped (nobody has re-enabled a sensor since).
    if (emergency != null && (emergency != state.emergency || stopped)) {
      added.add(
        HealthEntry(
          time: time,
          kind: emergency ? HealthKind.emergency : HealthKind.emergencyCleared,
          message: emergency
              ? 'Dừng khẩn cấp: mọi tải đã tắt, cảm biến bị vô hiệu hóa.'
              : 'Hết dừng khẩn cấp: cảm biến đã được bật lại.',
        ),
      );
      state.emergency = emergency;
    }
    if (interlock != null && interlock != state.interlock) {
      added.add(
        HealthEntry(
          time: time,
          kind: interlock ? HealthKind.interlock : HealthKind.interlockCleared,
          message: interlock
              ? 'Interlock đã ngắt tải để giữ an toàn.'
              : 'Interlock đã được gỡ.',
        ),
      );
      state.interlock = interlock;
    }

    if (added.isEmpty) return;
    state.log.addAll(added);
    if (state.log.length > maxEntries) {
      state.log.removeRange(0, state.log.length - maxEntries);
    }
    notifyListeners();
    await _save(deviceId);
  }

  Future<void> _save(String deviceId) async {
    final state = _state(deviceId);
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        '$_keyPrefix$deviceId',
        jsonEncode({
          'mask': state.mask,
          'emergency': state.emergency,
          'interlock': state.interlock,
          'log': [for (final entry in state.log) entry.toJson()],
        }),
      );
    } catch (error) {
      debugPrint('[Health] Không lưu được nhật ký lỗi của $deviceId: $error');
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}

import 'dart:async';

import 'package:flutter/material.dart';

import '../state/device_health.dart';
import 'crud_api.dart';
import 'device_repository.dart';
import 'mqtt_session_manager.dart';

typedef TransferNotices =
    Stream<List<Map<String, dynamic>>> Function(String userId);

/// Tells the previous owner that a device now belongs to another account.
///
/// The server writes a `device_transfer_notices` row for the old owner when
/// another account claims the device. The notices are kept while the owner is
/// offline, so they are also handled the next time the app starts.
class DeviceTransferWatcher {
  DeviceTransferWatcher({
    TransferNotices? notices,
    Future<void> Function(Object id)? deleteNotice,
    DeviceRepository? repository,
    Future<void> Function(String macAddress)? forgetDevice,
    void Function(String message)? announce,
  }) : _notices = notices ?? CrudApi.transferNotices,
       _deleteNotice = deleteNotice ?? CrudApi.deleteTransferNotice,
       _repository = repository ?? DeviceRepository.instance,
       _forgetDevice = forgetDevice ?? _forgetLocally,
       _announce = announce ?? _showMessage;

  static final instance = DeviceTransferWatcher();

  final TransferNotices _notices;
  final Future<void> Function(Object id) _deleteNotice;
  final DeviceRepository _repository;
  final Future<void> Function(String macAddress) _forgetDevice;
  final void Function(String message) _announce;

  final _transfers = StreamController<String>.broadcast();
  final _handled = <Object>{};
  StreamSubscription<List<Map<String, dynamic>>>? _subscription;
  String? _userId;
  Future<void> _queue = Future.value();

  /// MAC of every device that was found to belong to another account.
  Stream<String> get transfers => _transfers.stream;

  /// Starts watching the notices of [userId]; safe to call many times.
  void start(String userId) {
    debugPrint('[Transfer] 🔔 Starting transfer watcher for user: $userId');
    if (_userId == userId && _subscription != null) {
      debugPrint('[Transfer] Already watching $userId, skipping');
      return;
    }
    stop();
    _userId = userId;
    _subscription = _notices(userId).listen(
      (rows) {
        debugPrint(
          '[Transfer] 🔔 Transfer notice received: ${rows.length} rows',
        );
        _queue = _queue.then((_) => _process(rows));
      },
      onError: (Object error) =>
          debugPrint('[Transfer] ❌ Stream error: $error'),
    );
  }

  void stop() {
    _subscription?.cancel();
    _subscription = null;
    _userId = null;
    _handled.clear();
  }

  Future<void> _process(List<Map<String, dynamic>> rows) async {
    debugPrint('[Transfer] Processing ${rows.length} transfer notices');
    for (final notice in rows) {
      final id = notice['id'];
      final mac = notice['mac_address'];
      debugPrint('[Transfer] Notice: id=$id, mac=$mac');
      if (id == null || mac is! String || !_handled.add(id)) {
        debugPrint('[Transfer] Skipping notice (already handled or invalid)');
        continue;
      }
      try {
        await _handle(id, mac);
      } catch (error) {
        _handled.remove(id);
        debugPrint('[Transfer] ❌ Could not handle notice $id: $error');
      }
    }
  }

  Future<void> _handle(Object id, String mac) async {
    debugPrint('[Transfer] Handling notice for device: $mac');
    final name = _repository.devices
        .where((device) => device.macAddress == mac)
        .map((device) => device.name)
        .firstOrNull;
    debugPrint('[Transfer] Device name: $name');
    // The database decides: a notice can be old if the device came back.
    await _repository.refresh();
    if (_repository.error != null) {
      debugPrint(
        '[Transfer] Repository error after refresh: ${_repository.error}',
      );
      _handled.remove(id);
      return;
    }
    final stillOwned = _repository.devices.any(
      (device) => device.macAddress == mac,
    );
    debugPrint('[Transfer] Still owned by current user? $stillOwned');
    if (!stillOwned) {
      debugPrint('[Transfer] ⚠️  Device $mac is no longer owned - forgetting');
      await _forgetDevice(mac);
      _transfers.add(mac);
      _announce(
        'Thiết bị "${name ?? mac}" hiện không còn thuộc tài khoản này.',
      );
    }
    try {
      await _deleteNotice(id);
      debugPrint('[Transfer] Deleted transfer notice: $id');
    } catch (error) {
      debugPrint('[Transfer] ❌ Could not delete notice $id: $error');
    }
  }

  static Future<void> _forgetLocally(String macAddress) async {
    await MqttSessionManager.instance.removeDevice(macAddress);
    await DeviceHealth.instance.deleteDevice(macAddress);
  }

  static void _showMessage(String message) {
    appMessengerKey.currentState
      ?..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 6),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }
}

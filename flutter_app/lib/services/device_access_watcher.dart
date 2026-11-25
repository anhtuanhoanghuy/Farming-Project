import 'dart:async';

import 'package:flutter/foundation.dart';

import 'crud_api.dart';
import 'device_repository.dart';

/// Global broadcast stream for device access changes (revoke, ownership transfer).
/// All screens listening to a device should subscribe to revoked events.
class DeviceAccessWatcher extends ChangeNotifier {
  DeviceAccessWatcher({DeviceRepository? repository})
    : _repository = repository ?? DeviceRepository.instance;

  static final instance = DeviceAccessWatcher();

  final DeviceRepository _repository;
  final _revoked = StreamController<String>.broadcast();
  StreamSubscription<List<Map<String, dynamic>>>? _shareSubscription;
  StreamSubscription<List<Map<String, dynamic>>>? _deviceSubscription;
  List<Map<String, dynamic>>? _lastDevices;
  Map<String, String?>? _shareStatuses;

  /// Stream of MAC addresses (device IDs) that were revoked or ownership transferred.
  Stream<String> get revoked => _revoked.stream;

  /// Start watching for access revokes and ownership transfers.
  void start() {
    if (_shareSubscription != null && _deviceSubscription != null) return;
    _startShareListener();
    _startDeviceListener();
  }

  /// Manually check access now (call when entering device screens).
  Future<void> checkAccessNow() => _checkAccess();

  void _startShareListener() {
    try {
      debugPrint(
        '[DeviceAccessWatcher] 🔔 Starting share listener for user: ${CrudApi.userId}',
      );
      _shareSubscription = CrudApi.shareChanges('guest_id', CrudApi.userId).listen(
        (event) {
          debugPrint('[DeviceAccessWatcher] 🔔 Share change event received');

          // Emit only on a transition to 'revoked'; the stream replays old
          // revoked rows on every change, which must not re-trigger the popup.
          final seeded = _shareStatuses != null;
          final previous = _shareStatuses ?? <String, String?>{};
          final next = <String, String?>{};
          for (final share in event) {
            final shareId = share['id'] as String?;
            if (shareId == null) continue;
            final status = share['status'] as String?;
            next[shareId] = status;
            if (seeded &&
                status == 'revoked' &&
                previous[shareId] != 'revoked') {
              final deviceId = share['device_id'] as String?;
              debugPrint('[DeviceAccessWatcher] ⚠️  DEVICE REVOKED: $deviceId');
              for (final device in _repository.devices) {
                if (device.id == deviceId) _revoked.add(device.macAddress);
              }
            }
          }
          _shareStatuses = next;

          // Trigger access check on any share list change
          debugPrint('[DeviceAccessWatcher] ✅ Checking access');
          unawaited(_checkAccess());
        },
        onError: (e) {
          debugPrint('[DeviceAccessWatcher] ❌ Share stream error: $e');
        },
        cancelOnError: false,
      );
    } catch (e) {
      debugPrint('[DeviceAccessWatcher] ❌ Share subscribe error: $e');
    }
  }

  void _startDeviceListener() {
    try {
      debugPrint(
        '[DeviceAccessWatcher] 🔔 Starting device listener for user: ${CrudApi.userId}',
      );
      _deviceSubscription = CrudApi.deviceChanges(CrudApi.userId).listen(
        (event) {
          debugPrint(
            '[DeviceAccessWatcher] 🔔 Device change event received: ${event.length} devices',
          );
          debugPrint('[DeviceAccessWatcher] 📋 Device event details: $event');

          // If this is the first event (seed), store it and skip processing
          if (_lastDevices == null) {
            debugPrint(
              '[DeviceAccessWatcher] 📦 Storing initial seed devices: ${event.length}',
            );
            _lastDevices = event;
            return;
          }

          // Check if anything actually changed (count OR any device modified)
          bool changed = (_lastDevices?.length ?? 0) != event.length;

          // Also check if any device was modified (name, status, etc.)
          if (!changed &&
              _lastDevices != null &&
              _lastDevices!.length == event.length) {
            for (int i = 0; i < event.length; i++) {
              // Compare full device objects to detect any changes
              if (_lastDevices![i] != event[i]) {
                debugPrint(
                  '[DeviceAccessWatcher] ⚠️  Device ${event[i]['id']} was modified',
                );
                changed = true;
                break;
              }
            }
          }

          _lastDevices = event;

          if (changed) {
            debugPrint(
              '[DeviceAccessWatcher] ✅ Device change detected - checking access',
            );
            unawaited(_checkAccess());
          } else {
            debugPrint(
              '[DeviceAccessWatcher] 🔄 Device event identical, skipping access check',
            );
          }
        },
        onError: (e) {
          debugPrint('[DeviceAccessWatcher] ❌ Device stream error: $e');
        },
        cancelOnError: false,
      );
    } catch (e) {
      debugPrint('[DeviceAccessWatcher] ❌ Device subscribe error: $e');
    }
  }

  /// Check if any device access was lost and emit revoked for those.
  Future<void> _checkAccess() async {
    try {
      debugPrint('[DeviceAccessWatcher] ✅ Checking access');
      debugPrint('[DeviceAccessWatcher] Checking device access...');

      // Get the current devices list from cache
      final currentDevices = _repository.devices;
      debugPrint(
        '[DeviceAccessWatcher] Current cached devices: ${currentDevices.length}',
      );
      for (final d in currentDevices) {
        debugPrint('  - ${d.name} (${d.macAddress})');
      }

      // Fetch fresh data from server
      final userId = CrudApi.userId;
      List<Map<String, dynamic>> ownedDevices = [];
      List<Map<String, dynamic>> sharedDevices = [];
      bool hadError = false;

      try {
        ownedDevices = await CrudApi.listDevices(userId);
        debugPrint(
          '[DeviceAccessWatcher] Owned devices from server: ${ownedDevices.length}',
        );
        for (final d in ownedDevices) {
          debugPrint('  - ${d['name']} (id: ${d['id']})');
        }
      } catch (e) {
        debugPrint(
          '[DeviceAccessWatcher] ⚠️  Error fetching owned devices: $e',
        );
        hadError = true;
      }

      try {
        sharedDevices = await CrudApi.listSharedDevices();
        debugPrint(
          '[DeviceAccessWatcher] Shared devices from server: ${sharedDevices.length}',
        );
        for (final d in sharedDevices) {
          final deviceId = d['id'];
          final deviceName = d['name'];
          debugPrint('  - $deviceName (id: $deviceId)');
        }
      } catch (e) {
        debugPrint(
          '[DeviceAccessWatcher] ⚠️  Error fetching shared devices: $e',
        );
        hadError = true;
      }

      // If we had errors fetching, don't emit revoked (could be network issue)
      if (hadError) {
        debugPrint(
          '[DeviceAccessWatcher] Had errors fetching devices, skipping revoke check',
        );
        return;
      }

      // Create a set of still-accessible devices
      final accessible = <String>{};
      for (final d in ownedDevices) {
        final id = d['id'];
        if (id is String && id.isNotEmpty) {
          debugPrint('[DeviceAccessWatcher] Adding owned device: $id');
          accessible.add(id);
        }
      }
      for (final d in sharedDevices) {
        final id = d['id'];
        if (id is String && id.isNotEmpty) {
          debugPrint('[DeviceAccessWatcher] Adding shared device: $id');
          accessible.add(id);
        } else {
          debugPrint(
            '[DeviceAccessWatcher] ⚠️  Shared device has no valid id: $id',
          );
        }
      }
      debugPrint(
        '[DeviceAccessWatcher] Total accessible devices: ${accessible.length}',
      );

      // Check which devices were lost
      for (final device in currentDevices) {
        final deviceId = device.id;
        final macAddress = device.macAddress;
        final deviceName = device.name;

        if (deviceId.isEmpty || macAddress.isEmpty) {
          debugPrint(
            '[DeviceAccessWatcher] ⚠️  Skipping device with invalid id/mac: $deviceName',
          );
          continue;
        }

        if (!accessible.contains(deviceId)) {
          debugPrint('[DeviceAccessWatcher] !  DEVICE REVOKED: $deviceId');
          _revoked.add(macAddress);
        } else {
          debugPrint(
            '[DeviceAccessWatcher] ✅ Device still accessible: $deviceName',
          );
        }
      }

      // Refresh repository to reflect the changes
      await _repository.refresh();
      debugPrint('[DeviceAccessWatcher] Repository refreshed');
    } catch (e, stack) {
      debugPrint('[DeviceAccessWatcher] ❌ Check access error: $e\n$stack');
    }
  }

  void stop() {
    _shareSubscription?.cancel();
    _deviceSubscription?.cancel();
    _shareSubscription = null;
    _deviceSubscription = null;
    _lastDevices = null;
    _shareStatuses = null;
  }

  @override
  void dispose() {
    stop();
    _revoked.close();
    super.dispose();
  }
}

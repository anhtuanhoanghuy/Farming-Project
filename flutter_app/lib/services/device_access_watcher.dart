import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'crud_api.dart';
import 'device_repository.dart';

/// Global broadcast stream for device access changes (revoke, ownership transfer).
/// All screens listening to a device should subscribe to revoked events.
class DeviceAccessWatcher extends ChangeNotifier {
  DeviceAccessWatcher({
    DeviceRepository? repository,
  }) : _repository = repository ?? DeviceRepository.instance;

  static final instance = DeviceAccessWatcher();

  final DeviceRepository _repository;
  final _revoked = StreamController<String>.broadcast();
  StreamSubscription<List<Map<String, dynamic>>>? _shareSubscription;
  StreamSubscription<List<Map<String, dynamic>>>? _deviceSubscription;
  RealtimeChannel? _shareRemovedChannel;
  Timer? _pollTimer;
  List<Map<String, dynamic>>? _lastShares;
  List<Map<String, dynamic>>? _lastDevices;

  /// Stream of MAC addresses (device IDs) that were revoked or ownership transferred.
  Stream<String> get revoked => _revoked.stream;

  /// Start watching for access revokes and ownership transfers.
  void start() {
    if (_shareSubscription != null && _deviceSubscription != null && _shareRemovedChannel != null && _pollTimer != null) return;
    _startShareListener();
    _startDeviceListener();
    _startShareRemovedListener();
    _startPolling();
  }

  /// Manually check access now (call when entering device screens).
  Future<void> checkAccessNow() => _checkAccess();

  void _startShareListener() {
    try {
      debugPrint('[DeviceAccessWatcher] 🔔 Starting share listener for user: ${CrudApi.userId}');
      _shareSubscription = CrudApi.shareChanges('guest_id', CrudApi.userId).listen(
        (event) {
          debugPrint('[DeviceAccessWatcher] 🔔 Share change event received: ${event.length} shares');
          debugPrint('[DeviceAccessWatcher] 📋 Share event details: $event');
          
          // If this is the first event (seed), store it and skip processing
          if (_lastShares == null) {
            debugPrint('[DeviceAccessWatcher] 📦 Storing initial seed shares: ${event.length}');
            _lastShares = event;
            return;
          }
          
          // Check if anything actually changed (count OR status)
          bool changed = (_lastShares?.length ?? 0) != event.length;
          
          // Also check if any share status changed (e.g., 'accepted' → 'revoked')
          if (!changed && _lastShares != null && _lastShares!.length == event.length) {
            for (int i = 0; i < event.length; i++) {
              final lastStatus = _lastShares![i]['status'];
              final newStatus = event[i]['status'];
              if (lastStatus != newStatus) {
                debugPrint('[DeviceAccessWatcher] ⚠️  Status changed for share ${event[i]['id']}: $lastStatus → $newStatus');
                changed = true;
                break;
              }
            }
          }
          
          _lastShares = event;
          
          if (changed) {
            debugPrint('[DeviceAccessWatcher] ✅ Share change detected - checking access');
            unawaited(_checkAccess());
          } else {
            debugPrint('[DeviceAccessWatcher] 🔄 Share event identical, skipping access check');
          }
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
      debugPrint('[DeviceAccessWatcher] 🔔 Starting device listener for user: ${CrudApi.userId}');
      _deviceSubscription = CrudApi.deviceChanges(CrudApi.userId).listen(
        (event) {
          debugPrint('[DeviceAccessWatcher] 🔔 Device change event received: ${event.length} devices');
          debugPrint('[DeviceAccessWatcher] 📋 Device event details: $event');
          
          // If this is the first event (seed), store it and skip processing
          if (_lastDevices == null) {
            debugPrint('[DeviceAccessWatcher] 📦 Storing initial seed devices: ${event.length}');
            _lastDevices = event;
            return;
          }
          
          // Check if anything actually changed (count OR any device modified)
          bool changed = (_lastDevices?.length ?? 0) != event.length;
          
          // Also check if any device was modified (name, status, etc.)
          if (!changed && _lastDevices != null && _lastDevices!.length == event.length) {
            for (int i = 0; i < event.length; i++) {
              // Compare full device objects to detect any changes
              if (_lastDevices![i] != event[i]) {
                debugPrint('[DeviceAccessWatcher] ⚠️  Device ${event[i]['id']} was modified');
                changed = true;
                break;
              }
            }
          }
          
          _lastDevices = event;
          
          if (changed) {
            debugPrint('[DeviceAccessWatcher] ✅ Device change detected - checking access');
            unawaited(_checkAccess());
          } else {
            debugPrint('[DeviceAccessWatcher] 🔄 Device event identical, skipping access check');
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

  void _startShareRemovedListener() {
    try {
      final userId = CrudApi.userId;
      final topic = 'user:$userId:device_shares';
      debugPrint('[DeviceAccessWatcher] 🔔 Subscribing to private channel: $topic');
      
      final channel = Supabase.instance.client.channel(topic);
      
      // Listen to ALL broadcast events first to debug
      channel.onBroadcast(
        event: '*',
        callback: (payload) {
          debugPrint('[DeviceAccessWatcher] 🔔 Any event received: $payload');
        },
      );
      
      // Then listen to specific share_removed event
      channel.onBroadcast(
        event: 'share_removed',
        callback: (payload) {
          debugPrint('[DeviceAccessWatcher] 📡 Received share_removed event!');
          debugPrint('[DeviceAccessWatcher] 📡 Event payload: $payload');
          debugPrint('[DeviceAccessWatcher] 📡 Payload type: ${payload.runtimeType}');
          debugPrint('[DeviceAccessWatcher] 📡 Payload keys: ${payload is Map ? payload.keys : "N/A"}');
          
          try {
            final deviceId = payload['device_id'] as String?;
            debugPrint('[DeviceAccessWatcher] 📡 Extracted device_id: $deviceId');
            
            if (deviceId != null) {
              debugPrint('[DeviceAccessWatcher] ⚠️  DEVICE REVOKED: $deviceId');
              _revoked.add(deviceId);
              unawaited(_checkAccess());
            } else {
              debugPrint('[DeviceAccessWatcher] ⚠️  share_removed event missing device_id');
            }
          } catch (e) {
            debugPrint('[DeviceAccessWatcher] ❌ Error processing share_removed: $e');
          }
        },
      );
      
      channel.subscribe((status, error) {
        if (error != null) {
          debugPrint('[DeviceAccessWatcher] ❌ Channel subscribe error: $error');
        } else {
          debugPrint('[DeviceAccessWatcher] ✅ Channel subscribed with status: $status');
        }
      });
      
      _shareRemovedChannel = channel;
      debugPrint('[DeviceAccessWatcher] ✅ Share removed listener subscribed to: $topic');
    } catch (e) {
      debugPrint('[DeviceAccessWatcher] ❌ Share removed listener error: $e');
    }
  }

  void _startPolling() {
    if (_pollTimer != null) return;
    debugPrint('[DeviceAccessWatcher] ⏱️  Starting polling timer (every 10 seconds)');
    _pollTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      debugPrint('[DeviceAccessWatcher] ⏱️  Polling access check...');
      unawaited(_checkAccess());
    });
  }

  /// Check if any device access was lost and emit revoked for those.
  Future<void> _checkAccess() async {
    try {
      debugPrint('[DeviceAccessWatcher] Checking device access...');
      
      // Get the current devices list from cache
      final currentDevices = _repository.devices;
      debugPrint('[DeviceAccessWatcher] Current cached devices: ${currentDevices.length}');
      for (final d in currentDevices) {
        debugPrint('  - ${d.name} (${d.macAddress})');
      }
      
      // Fetch fresh data from server
      final userId = CrudApi.userId;
      final ownedDevices = await CrudApi.listDevices(userId) ?? [];
      debugPrint('[DeviceAccessWatcher] Owned devices from server: ${ownedDevices.length}');
      for (final d in ownedDevices) {
        debugPrint('  - ${d['name']} (id: ${d['id']})');
      }
      
      final sharedDevices = await CrudApi.listSharedDevices() ?? [];
      debugPrint('[DeviceAccessWatcher] Shared devices from server: ${sharedDevices.length}');
      for (final d in sharedDevices) {
        debugPrint('  - ${d['name']} (id: ${d['id']})');
      }

      // Create a set of still-accessible devices
      final accessible = <String>{};
      for (final d in ownedDevices) {
        final id = d['id'];
        if (id is String) {
          debugPrint('[DeviceAccessWatcher] Adding owned device: $id');
          accessible.add(id);
        }
      }
      for (final d in sharedDevices) {
        final id = d['id'];
        if (id is String) {
          debugPrint('[DeviceAccessWatcher] Adding shared device: $id');
          accessible.add(id);
        } else {
          debugPrint('[DeviceAccessWatcher] ⚠️  Shared device has no id: $d');
        }
      }
      debugPrint('[DeviceAccessWatcher] Total accessible devices: ${accessible.length}');

      // Check which devices were lost
      for (final device in currentDevices) {
        if (!accessible.contains(device.id)) {
          debugPrint('[DeviceAccessWatcher] ⚠️  DEVICE REVOKED: ${device.name} (${device.macAddress})');
          _revoked.add(device.macAddress);
        } else {
          debugPrint('[DeviceAccessWatcher] ✅ Device still accessible: ${device.name}');
        }
      }
      
      // Refresh repository to reflect the changes
      await _repository.refresh();
      debugPrint('[DeviceAccessWatcher] Repository refreshed');
    } catch (e) {
      debugPrint('[DeviceAccessWatcher] ❌ Check access error: $e');
    }
  }

  void stop() {
    _pollTimer?.cancel();
    _shareSubscription?.cancel();
    _deviceSubscription?.cancel();
    _shareRemovedChannel?.unsubscribe();
    _pollTimer = null;
    _shareSubscription = null;
    _deviceSubscription = null;
    _shareRemovedChannel = null;
    _lastShares = null;
    _lastDevices = null;
  }

  @override
  void dispose() {
    stop();
    _revoked.close();
    super.dispose();
  }
}

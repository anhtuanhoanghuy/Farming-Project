import 'dart:async';

import 'package:flutter/material.dart';

import '../services/device_access_watcher.dart';

/// Helper to detect when a device share is revoked or ownership is lost for a user.
/// Listens to global DeviceAccessWatcher for efficiency.
class ShareRevokeListener {
  ShareRevokeListener(this.context, this.deviceId);

  final BuildContext context;
  final String deviceId;
  StreamSubscription<String>? _subscription;

  /// Start listening for share revoke and ownership loss events.
  void start() {
    debugPrint('[ShareRevokeListener] Starting for device: $deviceId');
    DeviceAccessWatcher.instance.start();
    try {
      _subscription = DeviceAccessWatcher.instance.revoked.listen(
        (revokedDeviceId) {
          debugPrint('[ShareRevokeListener] Received revoke event for: $revokedDeviceId (listening for: $deviceId)');
          if (revokedDeviceId == deviceId) {
            debugPrint('[ShareRevokeListener] ⚠️  MATCH! Device revoked: $deviceId');
            _onRevoked();
          } else {
            debugPrint('[ShareRevokeListener] No match - ignoring event');
          }
        },
        onError: (e) {
          debugPrint('[ShareRevokeListener] ❌ Stream error: $e');
        },
        cancelOnError: false,
      );
    } catch (e) {
      debugPrint('[ShareRevokeListener] ❌ Subscribe error: $e');
    }
  }

  void _onRevoked() {
    debugPrint('[ShareRevokeListener] 📱 Executing _onRevoked for $deviceId');
    if (!context.mounted) {
      debugPrint('[ShareRevokeListener] Context not mounted, skipping');
      return;
    }
    
    debugPrint('[ShareRevokeListener] Showing snackbar');
    // Show snackbar
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Quyền truy cập thiết bị đã bị thu hồi')),
    );
    
    debugPrint('[ShareRevokeListener] Popping to first route');
    // Pop back to device list (first route in the navigator)
    // This will pop all device-specific screens and return to the main device list
    Navigator.of(context).popUntil((route) {
      debugPrint('[ShareRevokeListener] Checking route: ${route.settings.name}');
      return route.isFirst;
    });
  }

  /// Stop listening for share revoke and ownership loss events.
  void dispose() {
    _subscription?.cancel();
  }
}



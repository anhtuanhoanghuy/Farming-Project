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
    
    debugPrint('[ShareRevokeListener] Showing dialog');
    // Show dialog with message and confirmation button
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Thiết bị không thể truy cập'),
        content: const Text('Thiết bị đã bị thu hồi hoặc chuyển quyền sở hữu.'),
        actions: [
          TextButton(
            onPressed: () {
              debugPrint('[ShareRevokeListener] Dialog dismissed - popping to first route');
              Navigator.of(ctx).pop(); // Close dialog
              // Pop back to device list (first route in the navigator)
              Navigator.of(context).popUntil((route) {
                debugPrint('[ShareRevokeListener] Checking route: ${route.settings.name}');
                return route.isFirst;
              });
            },
            child: const Text('Đóng'),
          ),
        ],
      ),
    );
  }

  /// Stop listening for share revoke and ownership loss events.
  void dispose() {
    _subscription?.cancel();
  }
}



import 'dart:async';

import 'package:flutter/material.dart';

import '../services/device_access_watcher.dart';

/// Helper to detect when a device share is revoked or ownership is lost for a user.
/// Listens to global DeviceAccessWatcher for efficiency.
class ShareRevokeListener {
  ShareRevokeListener(
    this.context,
    this.deviceId, {
    this.popCount = 1,
  });

  final BuildContext context;
  final String deviceId;
  
  /// Number of screens to pop when device is revoked (default: 1 to pop to parent)
  /// For Console from Diagnostics: use 2 (pop Console → pop _DeviceDiagnosticsScreen → reach DiagnosticsScreen)
  final int popCount;
  
  StreamSubscription<String>? _subscription;

  /// Start listening for share revoke and ownership loss events.
  void start() {
    debugPrint('[ShareRevokeListener] Starting for device: $deviceId (will pop $popCount times)');
    DeviceAccessWatcher.instance.start();
    try {
      _subscription = DeviceAccessWatcher.instance.revoked.listen(
        (revokedDeviceId) {
          debugPrint('[ShareRevokeListener] Received revoke event for: $revokedDeviceId (listening for: $deviceId)');
          if (revokedDeviceId == deviceId) {
            debugPrint('[ShareRevokeListener] ⚠️  MATCH! Device revoked: $deviceId');
            _showRevokeDialog();
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

  void _showRevokeDialog() {
    debugPrint('[ShareRevokeListener] 📱 Showing revoke dialog for $deviceId');
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
              debugPrint('[ShareRevokeListener] Dialog dismissed - closing and popping');
              Navigator.of(ctx).pop(); // Close dialog
              _performPopAction();
            },
            child: const Text('Đóng'),
          ),
        ],
      ),
    );
  }

  void _performPopAction() {
    debugPrint('[ShareRevokeListener] Performing pop action ($popCount times)');
    if (!context.mounted) return;
    
    // Pop multiple times if needed
    for (int i = 0; i < popCount && Navigator.of(context).canPop(); i++) {
      debugPrint('[ShareRevokeListener] Popping... ${i + 1}/$popCount');
      Navigator.of(context).pop();
    }
  }

  /// Stop listening for share revoke and ownership loss events.
  void dispose() {
    _subscription?.cancel();
  }
}



import 'package:flutter/material.dart';

import '../services/crud_api.dart';
import 'device_access_watcher.dart';

/// Global service to show popup when device access is revoked or ownership transferred.
/// Listens to device access changes and notifies UI when access is lost.
class DeviceAccessRevokeNotifier {
  DeviceAccessRevokeNotifier._();

  static final _instance = DeviceAccessRevokeNotifier._();

  static DeviceAccessRevokeNotifier get instance => _instance;

  final Set<String> _notifiedDevices = {}; // Track devices already notified
  final Set<String> _seenDevices = {}; // Track devices that were once accessible
  bool _started = false;

  /// Start listening for device access revocation/transfer.
  /// Call once at app startup.
  void start() {
    if (_started) return;
    _started = true;

    // Listen to revoked events (device access lost)
    DeviceAccessWatcher.instance.revoked.listen((deviceId) {
      debugPrint('[DeviceAccessRevokeNotifier] Device access lost: $deviceId');
      _handleAccessLost(deviceId);
    });

    debugPrint('[DeviceAccessRevokeNotifier] Started');
  }

  void _handleAccessLost(String deviceId) {
    if (_notifiedDevices.contains(deviceId)) {
      debugPrint('[DeviceAccessRevokeNotifier] Already notified for $deviceId');
      return;
    }

    // Only show popup if device was previously seen/accessible
    if (!_seenDevices.contains(deviceId)) {
      debugPrint('[DeviceAccessRevokeNotifier] Device $deviceId was never accessible, skipping popup');
      _seenDevices.add(deviceId); // Mark as seen to avoid showing in future
      return;
    }

    _notifiedDevices.add(deviceId);

    // Show popup via global key
    _showRevokePopup(deviceId);
  }

  /// Mark a device as "seen" (was accessible at some point)
  void markDeviceAsAccessible(String deviceId) {
    _seenDevices.add(deviceId);
  }

  void _showRevokePopup(String deviceId) {
    // Get current context via navigator key
    final context = appNavigatorKey.currentState?.overlay?.context;
    if (context == null || !context.mounted) {
      debugPrint('[DeviceAccessRevokeNotifier] Context not available');
      return;
    }

    debugPrint('[DeviceAccessRevokeNotifier] Showing popup for $deviceId');
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Quyền truy cập bị thu hồi'),
        content: const Text('Thiết bị hiện đã bị thu hồi quyền hoặc chuyển quyền sở hữu.'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop(); // Close dialog
              _notifiedDevices.remove(deviceId); // Clear so it can show again if user navigates back
              _navigateToDeviceList();
            },
            child: const Text('Đóng'),
          ),
        ],
      ),
    );
  }

  void _navigateToDeviceList() {
    final navState = appNavigatorKey.currentState;
    if (navState == null) return;

    debugPrint('[DeviceAccessRevokeNotifier] Navigating to device list');
    
    // Pop all routes until we're at root, then navigate to device list
    // This handles navigation from any device-related screen back to device list
    while (navState.canPop()) {
      navState.pop();
    }
  }

  void stop() {
    _started = false;
    _notifiedDevices.clear();
  }

  void clearNotified(String deviceId) {
    _notifiedDevices.remove(deviceId);
  }
}

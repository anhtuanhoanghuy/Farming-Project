import 'package:flutter/material.dart';

import '../navigation/app_routes.dart';
import 'device_access_watcher.dart';

/// Global service to show popup when device access is revoked or ownership transferred.
/// Listens to device access changes and notifies UI when access is lost.
class DeviceAccessRevokeNotifier {
  DeviceAccessRevokeNotifier._();

  static final _instance = DeviceAccessRevokeNotifier._();

  static DeviceAccessRevokeNotifier get instance => _instance;

  final Set<String> _notifiedDevices = {}; // Track devices already notified
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
    _notifiedDevices.add(deviceId);

    // Show popup via global key
    _showRevokePopup(deviceId);
  }

  void _showRevokePopup(String deviceId) {
    // Get current context via navigator key
    final context = AppRoutes.navigatorKey.currentContext;
    if (context == null || !context.mounted) {
      debugPrint('[DeviceAccessRevokeNotifier] Context not available');
      return;
    }

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
              _navigateToTabRoot();
            },
            child: const Text('Đóng'),
          ),
        ],
      ),
    );
  }

  void _navigateToTabRoot() {
    final context = AppRoutes.navigatorKey.currentContext;
    if (context == null) return;

    // Determine which tab we're in and navigate to its root
    // Pop until we reach a screen that is a tab root
    if (Navigator.of(context, rootNavigator: false).canPop()) {
      // Keep popping until we reach tab root
      while (Navigator.of(context, rootNavigator: false).canPop()) {
        Navigator.of(context, rootNavigator: false).pop();
      }
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

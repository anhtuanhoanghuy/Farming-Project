import 'dart:async';

import 'package:flutter/foundation.dart';

import 'crud_api.dart';

/// Global watcher: auto-confirms share revoke requests for authenticated guest
/// regardless of current screen. Singleton, started once at app startup.
/// DeviceListScreen guest stream listener handles showing the popup notification.
class GuestRevokeWatcher {
  GuestRevokeWatcher._();

  static final _instance = GuestRevokeWatcher._();

  static GuestRevokeWatcher get instance => _instance;

  StreamSubscription<List<Map<String, dynamic>>>? _subscription;
  final Set<String> _revokedShares = {};
  bool _started = false;

  /// Start watching for revoke_waiting shares globally
  void start() {
    if (_started) return;
    _started = true;

    try {
      _subscription = CrudApi.shareChanges('guest_id', CrudApi.userId).listen(
        (shares) {
          for (final share in shares) {
            final status = share['status'] as String?;
            final shareId = share['id'] as String?;
            if (status == 'revoke_waiting' && shareId != null && !_revokedShares.contains(shareId)) {
              _revokedShares.add(shareId);
              debugPrint('[GuestRevokeWatcher] Auto-confirming revoke for share: $shareId');
              _autoConfirmRevoke(shareId);
            }
          }
        },
        onError: (e) {
          debugPrint('[GuestRevokeWatcher] Stream error: $e');
        },
      );
      debugPrint('[GuestRevokeWatcher] Started globally');
    } catch (e) {
      debugPrint('[GuestRevokeWatcher] Error starting: $e');
    }
  }

  Future<void> _autoConfirmRevoke(String shareId) async {
    try {
      await CrudApi.confirmRevoke(shareId);
      debugPrint('[GuestRevokeWatcher] ✅ Confirmed revoke for share: $shareId');
    } catch (e) {
      debugPrint('[GuestRevokeWatcher] ❌ Error confirming revoke: $e');
    }
  }

  void stop() {
    _subscription?.cancel();
    _subscription = null;
    _started = false;
    _revokedShares.clear();
  }
}




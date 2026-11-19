import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'crud_api.dart';

/// Global service to listen for share revoke events across the entire app.
/// This ensures host gets notified even if they're on a different screen.
class ShareRevokeService {
  static final ShareRevokeService _instance = ShareRevokeService._();

  factory ShareRevokeService() => _instance;

  ShareRevokeService._();

  RealtimeChannel? _channel;
  bool _isListening = false;

  /// Start listening for share revoke events globally.
  /// Call this once at app startup.
  void start() {
    if (_isListening) {
      debugPrint('[ShareRevokeService] Already listening');
      return;
    }

    _isListening = true;
    debugPrint('[ShareRevokeService] Starting global revoke listener');

    try {
      final userId = CrudApi.userId;
      final topicName = 'user:$userId:device_shares';

      debugPrint('[ShareRevokeService] Subscribing to topic: $topicName');
      _channel = Supabase.instance.client.channel(topicName);

      // Listen for share_revoked event (guest confirmed revoke)
      _channel!.onBroadcast(
        event: 'share_revoked',
        callback: (payload) {
          debugPrint('[ShareRevokeService] ✅ Received share_revoked event: $payload');
          _handleShareRevokedEvent(payload);
        },
      );

      // Also listen for share_revoke_waiting just for logging (DashboardScreen handles the popup)
      _channel!.onBroadcast(
        event: 'share_revoke_waiting',
        callback: (payload) {
          debugPrint('[ShareRevokeService] Share revoke notification sent to guest: $payload');
        },
      );

      _channel!.subscribe((status, error) {
        if (error != null) {
          debugPrint('[ShareRevokeService] ❌ Channel subscribe error: $error');
        } else {
          debugPrint('[ShareRevokeService] ✅ Channel subscribed with status: $status');
        }
      });
    } catch (e) {
      debugPrint('[ShareRevokeService] ❌ Subscribe error: $e');
      _isListening = false;
    }
  }

  Future<void> _handleShareRevokedEvent(Map<String, dynamic> payload) async {
    try {
      final shareId = payload['share_id'] as String?;

      if (shareId == null) {
        debugPrint('[ShareRevokeService] ❌ Event missing share_id');
        return;
      }

      debugPrint('[ShareRevokeService] Guest confirmed revoke for shareId: $shareId');

      // Auto-delete the revoked share
      try {
        await CrudApi.deleteRevokedShare(shareId);
        debugPrint('[ShareRevokeService] ✅ Share deleted automatically');
      } catch (e) {
        debugPrint('[ShareRevokeService] ⚠️ Error deleting share: $e');
      }
    } catch (e) {
      debugPrint('[ShareRevokeService] ❌ Error handling share_revoked event: $e');
    }
  }

  /// Stop listening for revoke events.
  void dispose() {
    if (_channel != null) {
      _channel!.unsubscribe();
      _channel = null;
    }
    _isListening = false;
    debugPrint('[ShareRevokeService] Stopped listening');
  }
}

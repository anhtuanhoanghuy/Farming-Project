import 'dart:async';

import 'package:flutter/material.dart';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../navigation/app_routes.dart';
import '../services/crud_api.dart';

/// Guest listener: listens for 'share_revoke_waiting' and auto-confirms.
/// When guest receives notification from host, they auto-confirm and show popup.
class ShareRevokeListener {
  /// tabIndex: Which tab to return to when revoke is detected
  /// (0=Devices, 1=Diagnostics, null=just pop)
  ShareRevokeListener(
    this.context,
    this.deviceId, {
    this.tabIndex,
  });

  final BuildContext context;
  final String deviceId;
  final int? tabIndex; // 0=Devices, 1=Diagnostics, null=pop
  
  RealtimeChannel? _channel;
  bool _dialogShown = false; // Prevent multiple dialogs

  /// Start listening for share revoke_waiting events via Realtime.
  void start() {
    debugPrint('[ShareRevokeListener] Starting for device: $deviceId (tabIndex: $tabIndex)');
    
    try {
      final userId = CrudApi.userId;
      final topicName = 'user:$userId:device_shares';
      
      debugPrint('[ShareRevokeListener] Subscribing to topic: $topicName');
      _channel = Supabase.instance.client.channel(topicName);
      
      _channel!.onBroadcast(
        event: 'share_revoke_waiting',
        callback: (payload) {
          debugPrint('[ShareRevokeListener] Received revoke_waiting event: $payload');
          _handleRevokeWaitingEvent(payload);
        },
      );
      
      _channel!.subscribe((status, error) {
        if (error != null) {
          debugPrint('[ShareRevokeListener] ❌ Channel subscribe error: $error');
        } else {
          debugPrint('[ShareRevokeListener] ✅ Channel subscribed with status: $status');
        }
      });
    } catch (e) {
      debugPrint('[ShareRevokeListener] ❌ Subscribe error: $e');
    }
  }

  Future<void> _handleRevokeWaitingEvent(Map<String, dynamic> payload) async {
    try {
      final deviceIdFromEvent = payload['device_id'] as String?;
      final shareId = payload['share_id'] as String?;
      
      debugPrint('[ShareRevokeListener] Event deviceId: $deviceIdFromEvent, listening for: $deviceId');
      
      if (deviceIdFromEvent != deviceId) {
        debugPrint('[ShareRevokeListener] No match - ignoring event');
        return;
      }
      
      if (shareId == null) {
        debugPrint('[ShareRevokeListener] ❌ Event missing share_id');
        return;
      }
      
      debugPrint('[ShareRevokeListener] ⚠️  MATCH! Auto-confirming revoke for shareId: $shareId');
      
      // Auto-confirm revoke immediately
      try {
        await CrudApi.confirmRevoke(shareId);
        debugPrint('[ShareRevokeListener] ✅ Revoke confirmed automatically');
      } catch (e) {
        debugPrint('[ShareRevokeListener] ⚠️  Error confirming revoke: $e');
      }
      
      // Show notification popup after confirming
      _showRevokeDialog();
    } catch (e) {
      debugPrint('[ShareRevokeListener] ❌ Error handling revoke event: $e');
    }
  }

  void _showRevokeDialog() {
    // Prevent showing multiple dialogs
    if (_dialogShown) {
      debugPrint('[ShareRevokeListener] ⚠️  Dialog already shown for $deviceId, skipping');
      return;
    }
    _dialogShown = true;
    
    debugPrint('[ShareRevokeListener] 📱 Showing revoke notification for $deviceId');
    if (!context.mounted) {
      debugPrint('[ShareRevokeListener] Context not mounted, skipping');
      _dialogShown = false;
      return;
    }
    
    // Show dialog with message and button
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Lời mời bị thu hồi'),
        content: const Text('Chủ sở hữu đã thu hồi quyền truy cập của bạn.'),
        actions: [
          TextButton(
            onPressed: () {
              debugPrint('[ShareRevokeListener] Dialog dismissed - closing and navigating');
              Navigator.of(ctx).pop(); // Close dialog
              _performNavigation();
            },
            child: const Text('Đóng'),
          ),
        ],
      ),
    );
  }

  void _performNavigation() {
    debugPrint('[ShareRevokeListener] Performing navigation - tabIndex: $tabIndex');
    if (!context.mounted) return;
    
    if (tabIndex != null) {
      // Navigate to specific tab (Devices or Diagnostics)
      debugPrint('[ShareRevokeListener] Opening tab $tabIndex');
      AppRoutes.openTab(context, tabIndex!);
    } else {
      // No tab specified: just pop current screen
      debugPrint('[ShareRevokeListener] Popping current screen');
      if (Navigator.of(context, rootNavigator: false).canPop()) {
        Navigator.of(context, rootNavigator: false).pop();
      }
    }
  }

  /// Stop listening for share revoke events.
  void dispose() {
    _channel?.unsubscribe();
    _channel = null;
  }
}

/// Host listener: listens for 'share_revoked' and auto-deletes the share.
/// When guest confirms they received revoke, trigger broadcasts 'share_revoked'.
/// Host auto-deletes the share from their list.
class HostShareRevokeConfirmListener {
  HostShareRevokeConfirmListener({
    required this.onShareRevoked,
  });

  final Function(String shareId) onShareRevoked;
  
  RealtimeChannel? _channel;

  /// Start listening for share_revoked events via Realtime.
  /// Called when device owner wants to listen for guest confirmation.
  void start() {
    debugPrint('[HostShareRevokeConfirmListener] Starting');
    
    try {
      final userId = CrudApi.userId;
      final topicName = 'user:$userId:device_shares';
      
      debugPrint('[HostShareRevokeConfirmListener] Subscribing to topic: $topicName');
      _channel = Supabase.instance.client.channel(topicName);
      
      _channel!.onBroadcast(
        event: 'share_revoked',
        callback: (payload) {
          debugPrint('[HostShareRevokeConfirmListener] Received share_revoked event: $payload');
          _handleShareRevokedEvent(payload);
        },
      );
      
      _channel!.subscribe((status, error) {
        if (error != null) {
          debugPrint('[HostShareRevokeConfirmListener] ❌ Channel subscribe error: $error');
        } else {
          debugPrint('[HostShareRevokeConfirmListener] ✅ Channel subscribed with status: $status');
        }
      });
    } catch (e) {
      debugPrint('[HostShareRevokeConfirmListener] ❌ Subscribe error: $e');
    }
  }

  Future<void> _handleShareRevokedEvent(Map<String, dynamic> payload) async {
    try {
      final shareId = payload['share_id'] as String?;
      
      if (shareId == null) {
        debugPrint('[HostShareRevokeConfirmListener] ❌ Event missing share_id');
        return;
      }
      
      debugPrint('[HostShareRevokeConfirmListener] ✅ Guest confirmed revoke for shareId: $shareId');
      
      // Auto-delete the revoked share
      try {
        await CrudApi.deleteRevokedShare(shareId);
        debugPrint('[HostShareRevokeConfirmListener] ✅ Share deleted automatically');
      } catch (e) {
        debugPrint('[HostShareRevokeConfirmListener] ⚠️  Error deleting share: $e');
      }
      
      // Notify parent that this share was revoked
      onShareRevoked(shareId);
    } catch (e) {
      debugPrint('[HostShareRevokeConfirmListener] ❌ Error handling share_revoked event: $e');
    }
  }

  /// Stop listening for share revoked events.
  void dispose() {
    _channel?.unsubscribe();
    _channel = null;
  }
}





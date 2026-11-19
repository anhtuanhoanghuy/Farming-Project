import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/error_text.dart';
import '../models/device_record.dart';
import '../models/device_selection.dart';
import '../navigation/app_routes.dart';
import '../protocol/device_snapshot.dart';
import '../services/crud_api.dart';
import '../services/device_repository.dart';
import '../services/mqtt_session_manager.dart';
import '../state/device_health.dart';
import '../state/device_presence.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../widgets/app_buttons.dart';
import '../widgets/app_card.dart';
import '../widgets/screen_scaffold.dart';
import '../widgets/share_revoke_detector.dart';
import '../widgets/status_chip.dart';

class DeviceListScreen extends StatefulWidget {
  const DeviceListScreen({super.key, this.inShell = false});

  final bool inShell;

  @override
  State<DeviceListScreen> createState() => _DeviceListScreenState();
}

class _DeviceListScreenState extends State<DeviceListScreen> {
  final _repository = DeviceRepository.instance;
  List<Map<String, dynamic>> _invitations = [];
  bool _invitationsExpanded = false;
  final Set<String> _revokedSharesNotified = {}; // Track already notified revokes
  StreamSubscription<List<Map<String, dynamic>>>? _guestSharesSub;
  StreamSubscription<List<Map<String, dynamic>>>? _ownerSharesSub;

  @override
  void initState() {
    super.initState();
    DevicePresence.instance.start();
    DeviceHealth.instance.start();
    
    // Load devices first
    _repository.refresh().then((_) {
      if (mounted) unawaited(_loadInvitations());
    }).catchError((e) {
      debugPrint('[DeviceList] Initial refresh failed: $e');
    });
    
    // Stream 1: Shares where user is GUEST (someone shared to them)
    try {
      _guestSharesSub = CrudApi.shareChanges('guest_id', CrudApi.userId).listen(
        (shares) {
          debugPrint('[DeviceList] Guest shares changed');
          
          // Check for revoked status to show notification
          for (final share in shares) {
            final shareId = share['id'] as String?;
            final deviceName = share['device_name'] as String?;
            final status = share['status'] as String?;
            
            if (shareId != null && status == 'revoked' && !_revokedSharesNotified.contains(shareId)) {
              _revokedSharesNotified.add(shareId);
              debugPrint('[DeviceList] 🔔 Share revoked: $deviceName');
              _showRevokeNotification(deviceName ?? 'thiết bị');
            }
          }
          
          if (mounted) unawaited(_loadInvitations());
        },
        onError: (e) {
          debugPrint('[DeviceList] Guest stream error: $e');
        },
        cancelOnError: false,
      );
    } catch (e) {
      debugPrint('[DeviceList] Guest stream error: $e');
    }
    
    // Stream 2: Shares where user is OWNER (they shared to others)
    // This catches revoke status changes
    try {
      _ownerSharesSub = CrudApi.shareChanges('owner_id', CrudApi.userId).listen(
        (_) {
          debugPrint('[DeviceList] Owner shares changed');
          if (mounted) unawaited(_loadInvitations());
        },
        onError: (e) {
          debugPrint('[DeviceList] Owner stream error: $e');
        },
        cancelOnError: false,
      );
    } catch (e) {
      debugPrint('[DeviceList] Owner stream error: $e');
    }
  }

  @override
  void dispose() {
    _guestSharesSub?.cancel();
    _ownerSharesSub?.cancel();
    super.dispose();
  }

  Future<void> _loadInvitations() async {
    try {
      final rows = await CrudApi.run(
        'Tải lời mời chia sẻ',
        CrudApi.listMyInvitations,
      );
      final pending = [
        for (final row in rows)
          if (row['status'] == 'pending') row,
      ];
      if (mounted) setState(() => _invitations = pending);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(userErrorText('Không tải được lời mời chia sẻ', error)),
        ),
      );
    }
  }

  Future<void> _respondInvitation(String shareId, bool accept) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await CrudApi.run(
        accept ? 'Chấp nhận lời mời chia sẻ' : 'Từ chối lời mời chia sẻ',
        () => CrudApi.respondShare(shareId, accept),
      );
      // Real-time subscription handles reload automatically
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(userErrorText('Không phản hồi được lời mời', error)),
        ),
      );
    }
  }

  void _showRevokeNotification(String deviceName) {
    if (!mounted) return;
    
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Thiết bị đã bị thu hồi'),
        content: Text('Chủ sở hữu đã thu hồi quyền truy cập đến "$deviceName".'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Đóng'),
          ),
        ],
      ),
    );
  }

  /// Pull-to-refresh: reloads the devices with a CRUD `SELECT`, shown in the
  /// CRUD log in developer mode.
  Future<void> _reload() async {
    await CrudApi.run(
      'Kéo xuống làm mới danh sách thiết bị',
      _repository.refresh,
    );
    if (mounted) unawaited(_loadInvitations());
  }

  /// Chip from the device's retained presence message (LWT).
  static (String, StatusKind) _presenceChip(bool connected, bool? online) {
    if (!connected) return ('Đang đồng bộ', StatusKind.degraded);
    return switch (online) {
      true => ('Trực tuyến', StatusKind.online),
      false => ('Ngoại tuyến', StatusKind.offline),
      null => ('Đang chờ trạng thái', StatusKind.degraded),
    };
  }

  @override
  Widget build(BuildContext context) {
    final manager = MqttSessionManager.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([
        _repository,
        manager,
        DevicePresence.instance,
        DeviceHealth.instance,
      ]),
      builder: (context, _) {
        final devices = _repository.devices;
        final error = _repository.error;
        final loadingFirst = _repository.isLoading && devices.isEmpty;
        return ScreenScaffold(
          showMore: false,
          title: 'Danh sách thiết bị',
          leadingIcon: Icons.developer_board,
          embedInTab: widget.inShell,
          navIndex: widget.inShell ? null : 0,
          onNavTap: widget.inShell
              ? null
              : (i) => AppRoutes.openTab(context, i),
          body: RefreshIndicator(
            onRefresh: _reload,
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _repository.isAdminMode
                        ? '${devices.length} thiết bị · Tất cả tài khoản'
                        : '${devices.length} thiết bị',
                    style: AppTextStyles.heading,
                  ),
                  const SizedBox(height: 16),
                  PrimaryButton(
                    label: 'Thêm thiết bị',
                    icon: Icons.add,
                    onPressed: () {
                      Navigator.of(
                        context,
                        rootNavigator: true,
                      ).pushNamed(AppRoutes.bleScan);
                    },
                  ),
                  const SizedBox(height: 16),
                  if (error != null) ...[
                    _ErrorCard(
                      message: devices.isEmpty
                          ? error
                          : '$error\nĐang hiển thị danh sách đã lưu trên máy.',
                      retrying: _repository.isLoading,
                      onRetry: _reload,
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (loadingFirst)
                    const AppCard(
                      child: Row(
                        children: [
                          SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          SizedBox(width: 12),
                          Text(
                            'Đang tải danh sách thiết bị...',
                            style: AppTextStyles.bodySecondary,
                          ),
                        ],
                      ),
                    )
                  else if (devices.isEmpty && error == null)
                    const AppCard(
                      child: Text(
                        'Chưa có thiết bị được đăng ký. Hãy thêm thiết bị.',
                        style: AppTextStyles.bodySecondary,
                      ),
                    ),
                  for (var i = 0; i < devices.length; i++) ...[
                    if (i > 0) const SizedBox(height: 12),
                    Builder(
                      builder: (context) {
                        final online = DevicePresence.instance.isOnline(
                          devices[i].macAddress,
                        );
                        final (label, kind) = _presenceChip(
                          manager.isConnected,
                          online,
                        );
                        return _DeviceCard(
                          name: devices[i].name,
                          network: devices[i].macAddress,
                          detail: _repository.isAdminMode
                              ? '${_detail(devices[i])}\nChủ sở hữu: ${_repository.ownerLabel(devices[i].userId)}'
                              : _detail(devices[i]),
                          chipLabel: label,
                          kind: kind,
                          // The "!" is for a device that is online and reports
                          // an error: nothing is flagged without one.
                          hasError:
                              online == true &&
                              DeviceHealth.instance.hasErrors(
                                devices[i].macAddress,
                              ),
                          onView: () => Navigator.of(context).pushNamed(
                            AppRoutes.dashboard,
                            arguments: DeviceSelection(
                              deviceId: devices[i].macAddress,
                              name: devices[i].name,
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                  if (_invitations.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    _InvitationsDropdown(
                      invitations: _invitations,
                      expanded: _invitationsExpanded,
                      onToggle: () => setState(
                        () => _invitationsExpanded = !_invitationsExpanded,
                      ),
                      onRespond: _respondInvitation,
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  static String _detail(DeviceRecord device) {
    final message = MqttSessionManager.instance.latestSnapshot(
      device.macAddress,
    );
    final json = message == null ? null : jsonDecode(message.payload);
    final snapshot = json is Map
        ? DeviceSnapshot.tryParse(json, message!.receivedAt)
        : null;
    String count(int? value, String unit) =>
        value == null ? '? $unit' : '$value $unit';
    return 'Tối đa ${count(snapshot?.capabilities.maxSensorCount ?? device.maxSensorCount, 'cảm biến')} · '
        '${count(snapshot?.capabilities.maxLoadCount ?? device.maxLoadCount, 'tải')}';
  }
}

class _InvitationsDropdown extends StatelessWidget {
  const _InvitationsDropdown({
    required this.invitations,
    required this.expanded,
    required this.onToggle,
    required this.onRespond,
  });

  final List<Map<String, dynamic>> invitations;
  final bool expanded;
  final VoidCallback onToggle;
  final void Function(String shareId, bool accept) onRespond;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  const Icon(
                    Icons.mail_outline_rounded,
                    size: 20,
                    color: AppColors.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Lời mời chia sẻ (${invitations.length})',
                      style: AppTextStyles.cardTitle,
                    ),
                  ),
                  Icon(
                    expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            for (final invite in invitations)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            (invite['device_name'] ?? 'Thiết bị').toString(),
                            style: AppTextStyles.bodyMedium,
                          ),
                          Text(
                            'Từ: ${invite['owner_email'] ?? invite['owner_id']}',
                            style: AppTextStyles.caption,
                          ),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: () =>
                          onRespond(invite['share_id'] as String, false),
                      child: Text(
                        'Từ chối',
                        style: AppTextStyles.link.copyWith(
                          color: AppColors.errorText,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () =>
                          onRespond(invite['share_id'] as String, true),
                      child: const Text('Chấp nhận'),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({
    required this.message,
    required this.retrying,
    required this.onRetry,
  });

  final String message;
  final bool retrying;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            message,
            style: AppTextStyles.bodySecondary.copyWith(
              color: AppColors.errorText,
            ),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: retrying ? null : onRetry,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: Text(retrying ? 'Đang tải...' : 'Thử lại'),
          ),
        ],
      ),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({
    required this.name,
    required this.network,
    required this.detail,
    required this.chipLabel,
    required this.kind,
    required this.hasError,
    required this.onView,
  });

  final String name;
  final String network;
  final String detail;
  final String chipLabel;
  final StatusKind kind;
  final bool hasError;
  final VoidCallback onView;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onView,
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(name, style: AppTextStyles.cardTitle),
                      ),
                      if (hasError) ...[
                        const SizedBox(width: 6),
                        const Icon(
                          Icons.error_rounded,
                          size: 18,
                          color: AppColors.errorText,
                        ),
                      ],
                    ],
                  ),
                ),
                StatusChip(label: chipLabel, kind: kind),
              ],
            ),
            const SizedBox(height: 2),
            Text(network, style: AppTextStyles.bodyMedium),
            const SizedBox(height: 8),
            Text(detail, style: AppTextStyles.bodySecondary),
          ],
        ),
      ),
    );
  }
}

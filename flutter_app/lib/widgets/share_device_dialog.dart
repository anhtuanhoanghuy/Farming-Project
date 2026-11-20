import 'dart:async';

import 'package:flutter/material.dart';

import '../core/error_text.dart';
import '../services/crud_api.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';

/// Owner-only dialog: invite another account by its fixed share code, and
/// manage who the device is currently shared with.
class ShareDeviceDialog extends StatefulWidget {
  const ShareDeviceDialog({
    super.key,
    required this.deviceId,
    required this.deviceName,
  });

  /// `devices.id` (UUID), not the MAC address.
  final String deviceId;
  final String deviceName;

  @override
  State<ShareDeviceDialog> createState() => _ShareDeviceDialogState();
}

class _ShareDeviceDialogState extends State<ShareDeviceDialog> {
  static const _codeLength = 8;
  static const _maxActiveShares = 1;
  static const _activeStatuses = {'pending', 'accepted', 'revoke_waiting'};

  int _activeShareCount = 0;
  bool get _limitReached => _activeShareCount >= _maxActiveShares;

  final _codeController = TextEditingController();
  Future<List<Map<String, dynamic>>>? _sharesFuture;
  StreamSubscription<List<Map<String, dynamic>>>? _sharesSub;
  StreamSubscription<String>? _timeoutSub;
  bool _sharesSeeded = false;
  // Shares revoked from this dialog; kept so they show "Đã thu hồi" after the server deletes them.
  final Map<String, Map<String, dynamic>> _revokedShares = {};

  Map<String, dynamic>? _found;
  bool _checked = false;
  bool _checking = false;
  bool _sending = false;
  String? _checkError;

  @override
  void initState() {
    super.initState();
    _loadShares();
    _timeoutSub = CrudApi.revokeTimedOut.listen((_) {
      if (mounted) setState(_loadShares);
    });
    try {
      _sharesSub = CrudApi.shareChanges('owner_id', CrudApi.userId).listen(
        (shares) {
          if (!_sharesSeeded) {
            _sharesSeeded = true;
            return;
          }
          if (mounted) {
            // On any change, reload shares
            setState(_loadShares);
            
            // Also auto-delete any shares in 'revoked' or 'declined' status (silent, no reload)
            for (final share in shares) {
              final status = share['status'] as String?;
              final shareId = share['id'] as String?;
              if ((status == 'revoked' || status == 'declined') && shareId != null) {
                _silentDeleteShare(shareId);
              }
            }
          }
        },
        onError: (e) {
          debugPrint('[ShareDeviceDialog] Stream error: $e');
        },
      );
    } catch (e) {
      debugPrint('[ShareDeviceDialog] Error subscribing to share changes: $e');
    }
  }

  @override
  void dispose() {
    _sharesSub?.cancel();
    _timeoutSub?.cancel();
    _codeController.dispose();
    super.dispose();
  }

  void _loadShares() {
    _sharesFuture = CrudApi.run(
      'Mở hộp thoại chia sẻ thiết bị "${widget.deviceName}"',
      () => CrudApi.listDeviceShares(widget.deviceId),
    ).then((shares) {
      final count = shares
          .where((s) => _activeStatuses.contains(s['status']))
          .length;
      if (mounted && count != _activeShareCount) {
        setState(() => _activeShareCount = count);
      }
      return shares;
    });
  }

  Future<void> _checkCode() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) return;
    setState(() {
      _checking = true;
      _checked = false;
      _found = null;
      _checkError = null;
    });
    try {
      final found = await CrudApi.run(
        'Kiểm tra mã chia sẻ "$code"',
        () => CrudApi.lookupShareCode(code),
      );
      if (!mounted || _codeController.text.trim() != code) return;
      setState(() {
        _found = found;
        _checked = true;
      });
    } catch (error) {
      if (!mounted || _codeController.text.trim() != code) return;
      setState(() {
        _checkError = userErrorText('Không kiểm tra được mã', error);
        _checked = true;
      });
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _sendInvite() async {
    final code = _codeController.text.trim();
    if (code.isEmpty || _sending) return;
    setState(() => _sending = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await CrudApi.run(
        'Gửi lời mời chia sẻ thiết bị "${widget.deviceName}" bằng mã "$code"',
        () => CrudApi.inviteByShareCode(widget.deviceId, code),
      );
      if (!mounted) return;
      messenger.showSnackBar(const SnackBar(content: Text('Đã gửi lời mời')));
      _codeController.clear();
      setState(() {
        _checked = false;
        _found = null;
        _loadShares();
      });
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text(userErrorText('Không gửi được lời mời', error))),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _revoke(Map<String, dynamic> share) async {
    final shareId = share['share_id'] as String;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await CrudApi.run(
        'Thu hồi chia sẻ thiết bị "${widget.deviceName}"',
        () => CrudApi.revokeShare(shareId),
      );
      if (!mounted) return;
      _revokedShares[shareId] = share;
      setState(_loadShares);
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text(userErrorText('Không thu hồi được', error))),
      );
    }
  }

  Future<void> _silentDeleteShare(String shareId) async {
    try {
      await CrudApi.deleteRevokedShare(shareId);
    } catch (e) {
      debugPrint('[ShareDeviceDialog] Silent delete failed: $e');
    }
  }

  static String _statusLabel(String status) => switch (status) {
    'accepted' => 'Đã thêm thành viên',
    'declined' => 'Đã từ chối',
    'revoke_waiting' => 'Đang chờ xác nhận thu hồi',
    'revoked' => 'Đã thu hồi',
    _ => 'Đang chờ',
  };

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: const Text('Chia sẻ thiết bị', style: AppTextStyles.sectionTitle),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _codeController,
                autofocus: true,
                textCapitalization: TextCapitalization.characters,
                onTapOutside: (_) =>
                    FocusManager.instance.primaryFocus?.unfocus(),
                maxLength: _codeLength,
                onChanged: (value) {
                  setState(() {
                    _checked = false;
                    _found = null;
                    _checkError = null;
                  });
                  if (value.trim().length == _codeLength) _checkCode();
                },
                decoration: const InputDecoration(
                  hintText: 'Nhập mã chia sẻ của tài khoản khách',
                  hintStyle: AppTextStyles.bodySecondary,
                  counterText: '',
                ),
              ),
              if (_checking) ...[
                const SizedBox(height: 10),
                const Text(
                  'Đang kiểm tra...',
                  style: AppTextStyles.bodySecondary,
                ),
              ],
              if (_checked) ...[
                const SizedBox(height: 10),
                if (_checkError != null)
                  Text(
                    _checkError!,
                    style: AppTextStyles.bodySecondary.copyWith(
                      color: AppColors.errorText,
                    ),
                  )
                else if (_found == null)
                  const Text(
                    'Không tìm thấy người này',
                    style: AppTextStyles.bodySecondary,
                  )
                else
                  Text(
                    'Tài khoản: ${_found!['email'] ?? _found!['display_name'] ?? _found!['guest_user_id']}',
                    style: AppTextStyles.bodyMedium,
                  ),
              ],
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: (_found != null && !_sending && !_limitReached)
                      ? _sendInvite
                      : null,
                  child: Text(
                    _limitReached
                        ? 'Vượt quá số lượng lời mời'
                        : _sending
                        ? 'Đang gửi...'
                        : 'Gửi lời mời',
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'Đã chia sẻ với',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              FutureBuilder<List<Map<String, dynamic>>>(
                future: _sharesFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    );
                  }
                  if (snapshot.hasError) {
                    return Text(
                      userErrorText(
                        'Không tải được danh sách chia sẻ',
                        snapshot.error!,
                      ),
                      style: AppTextStyles.bodySecondary.copyWith(
                        color: AppColors.errorText,
                      ),
                    );
                  }
                  final serverShares = snapshot.data ?? const [];
                  final serverIds = {
                    for (final s in serverShares) s['share_id'],
                  };
                  final shares = [
                    ...serverShares,
                    for (final entry in _revokedShares.entries)
                      if (!serverIds.contains(entry.key))
                        {...entry.value, 'status': 'revoked'},
                  ];
                  if (shares.isEmpty) {
                    return const Text(
                      'Chưa chia sẻ với thành viên nào.',
                      style: AppTextStyles.bodySecondary,
                    );
                  }
                  return Column(
                    children: [
                      for (final share in shares)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      (share['guest_email'] ??
                                              share['guest_display_name'] ??
                                              share['guest_id'])
                                          .toString(),
                                      style: AppTextStyles.bodyMedium,
                                    ),
                                    Text(
                                      _statusLabel(
                                        share['status'] as String? ?? '',
                                      ),
                                      style: share['status'] == 'declined'
                                          ? AppTextStyles.caption.copyWith(
                                              color: AppColors.errorText,
                                            )
                                          : AppTextStyles.caption,
                                    ),
                                  ],
                                ),
                              ),
                              if (share['status'] != 'revoked')
                                TextButton(
                                  onPressed: () => _revoke(share),
                                  child: Text(
                                    'Thu hồi',
                                    style: AppTextStyles.link.copyWith(
                                      color: AppColors.errorText,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
            'Đóng',
            style: AppTextStyles.link.copyWith(color: AppColors.textSecondary),
          ),
        ),
      ],
    );
  }
}

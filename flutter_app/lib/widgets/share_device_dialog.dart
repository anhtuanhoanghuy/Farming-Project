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

  final _codeController = TextEditingController();
  Future<List<Map<String, dynamic>>>? _sharesFuture;
  StreamSubscription<List<Map<String, dynamic>>>? _sharesSub;
  bool _sharesSeeded = false;

  Map<String, dynamic>? _found;
  bool _checked = false;
  bool _checking = false;
  bool _sending = false;
  String? _checkError;

  @override
  void initState() {
    super.initState();
    _loadShares();
    try {
      _sharesSub = CrudApi.shareChanges('owner_id', CrudApi.userId).listen(
        (_) {
          // The first event is the initial snapshot, already covered above.
          if (!_sharesSeeded) {
            _sharesSeeded = true;
            return;
          }
          if (mounted) setState(_loadShares);
        },
        onError: (_) {},
      );
    } catch (e) {
      debugPrint('[ShareDeviceDialog] Error subscribing to share changes: $e');
    }
  }

  @override
  void dispose() {
    _sharesSub?.cancel();
    _codeController.dispose();
    super.dispose();
  }

  void _loadShares() {
    _sharesFuture = CrudApi.run(
      'Mở hộp thoại chia sẻ thiết bị "${widget.deviceName}"',
      () => CrudApi.listDeviceShares(widget.deviceId),
    );
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

  Future<void> _revoke(String shareId) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await CrudApi.run(
        'Thu hồi chia sẻ thiết bị "${widget.deviceName}"',
        () => CrudApi.revokeShare(shareId),
      );
      if (!mounted) return;
      setState(_loadShares);
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text(userErrorText('Không thu hồi được', error))),
      );
    }
  }

  static String _statusLabel(String status) => switch (status) {
    'accepted' => 'Đã chấp nhận',
    'declined' => 'Đã từ chối',
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
                  onPressed: (_found != null && !_sending) ? _sendInvite : null,
                  child: Text(_sending ? 'Đang gửi...' : 'Gửi lời mời'),
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
                  final shares = snapshot.data ?? const [];
                  if (shares.isEmpty) {
                    return const Text(
                      'Chưa chia sẻ với ai.',
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
                              TextButton(
                                onPressed: () =>
                                    _revoke(share['share_id'] as String),
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

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/auth_service.dart';
import '../services/device_repository.dart';
import 'developer_access_controller.dart';

class AdminAccessController extends ChangeNotifier {
  AdminAccessController({
    required String? Function() currentUserId,
    required bool Function() developerEnabled,
    required Future<bool> Function(String) checkAdmin,
    required Future<void> Function(bool) setMode,
  }) : _currentUserId = currentUserId,
       _developerEnabled = developerEnabled,
       _checkAdmin = checkAdmin,
       _setMode = setMode;

  static final instance = AdminAccessController(
    currentUserId: () => AuthService.userId,
    developerEnabled: () => DeveloperAccessController.instance.hasAccess,
    checkAdmin: (userId) async {
      final row = await Supabase.instance.client
          .from('app_admins')
          .select('user_id')
          .eq('user_id', userId)
          .maybeSingle();
      return row != null;
    },
    setMode: DeviceRepository.instance.setAdminMode,
  );

  static const tapLimit = 10;

  final String? Function() _currentUserId;
  final bool Function() _developerEnabled;
  final Future<bool> Function(String) _checkAdmin;
  final Future<void> Function(bool) _setMode;
  int _taps = 0;
  int _generation = 0;
  String? _tapUserId;
  bool _active = false;
  bool _busy = false;

  bool get isActive => _active;
  bool get isBusy => _busy;

  Future<bool> tap() async {
    final userId = _currentUserId();
    if (!_developerEnabled() || userId == null) {
      _taps = 0;
      return false;
    }
    if (_busy || _active) return false;
    if (_tapUserId != userId) {
      _tapUserId = userId;
      _taps = 0;
    }
    if (++_taps < tapLimit) return false;
    _taps = 0;
    final generation = _generation;
    _busy = true;
    notifyListeners();
    bool stillValid() =>
        generation == _generation &&
        _developerEnabled() &&
        _currentUserId() == userId;
    try {
      final allowed = await _checkAdmin(userId);
      if (!stillValid()) return false;
      if (!allowed) {
        throw StateError('Tài khoản này không có quyền quản trị.');
      }
      await _setMode(true);
      if (!stillValid()) {
        await _setMode(false);
        return false;
      }
      _active = true;
      return true;
    } catch (error, stackTrace) {
      if (stillValid()) {
        try {
          await _setMode(false);
        } catch (rollbackError) {
          debugPrint(
            '[Admin] Không khôi phục được chế độ thường: $rollbackError',
          );
        }
      }
      Error.throwWithStackTrace(error, stackTrace);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  void reset() {
    _generation++;
    _taps = 0;
    _tapUserId = null;
    _active = false;
    notifyListeners();
  }

  Future<void> deactivate() async {
    reset();
    await _setMode(false);
  }
}

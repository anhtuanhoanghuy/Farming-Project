import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DeveloperAccessController extends ChangeNotifier {
  DeveloperAccessController._();

  static final instance = DeveloperAccessController._();

  static const _key = 'developer_access';

  bool _hasAccess = false;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getBool(_key);
    if (stored != null && stored != _hasAccess) {
      _hasAccess = stored;
      notifyListeners();
    }
  }

  bool get hasAccess => _hasAccess;

  void setAccess(bool value) {
    if (_hasAccess == value) return;
    _hasAccess = value;
    notifyListeners();
    SharedPreferences.getInstance().then((p) => p.setBool(_key, value)).catchError((_) => false);
  }
}

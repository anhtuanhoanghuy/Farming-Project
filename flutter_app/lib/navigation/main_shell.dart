import 'package:flutter/material.dart';

import '../screens/device_list_screen.dart';
import '../screens/diagnostics_screen.dart';
import '../screens/settings_screen.dart';
import '../services/auth_service.dart';
import '../services/device_transfer_watcher.dart';
import '../services/mqtt_session_manager.dart';
import '../state/developer_access_controller.dart';
import '../state/device_health.dart';
import '../state/device_presence.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../widgets/app_bottom_nav.dart';
import 'app_routes.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key, this.initialIndex = 0});

  final int initialIndex;

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  late int _index;
  final _deviceKey = GlobalKey<NavigatorState>();
  final _diagKey = GlobalKey<NavigatorState>();
  final _settingsKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    // Listen before MQTT connects so the retained presence messages are seen.
    DevicePresence.instance.start();
    DeviceHealth.instance.start();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final userId = AuthService.userId;
      if (userId != null) {
        MqttSessionManager.instance.startForUser(userId);
        DeviceTransferWatcher.instance.start(userId);
      }
    });
  }

  Route<dynamic> _route(RouteSettings settings, Widget home) {
    if (settings.name == '/' || settings.name == Navigator.defaultRouteName) {
      return MaterialPageRoute(builder: (_) => home);
    }
    return AppRoutes.onGenerateRoute(settings);
  }

  void _onNavTap(int i) {
    if (i == 1 && !DeveloperAccessController.instance.hasAccess) {
      _diagKey.currentState?.popUntil((route) => route.isFirst);
    }
    if (i == _index) {
      final key = switch (i) {
        0 => _deviceKey,
        1 => _diagKey,
        _ => _settingsKey,
      };
      key.currentState?.popUntil((route) => route.isFirst);
      return;
    }
    setState(() => _index = i);
  }

  void _popNestedNavigator(GlobalKey<NavigatorState> key) {
    final navigator = key.currentState;
    if (navigator?.canPop() ?? false) navigator!.pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: IndexedStack(
        index: _index,
        children: [
          NavigatorPopHandler<Object?>(
            enabled: _index == 0,
            onPopWithResult: (_) => _popNestedNavigator(_deviceKey),
            child: Navigator(
              key: _deviceKey,
              onGenerateRoute: (s) =>
                  _route(s, const DeviceListScreen(inShell: true)),
            ),
          ),
          NavigatorPopHandler<Object?>(
            enabled: _index == 1,
            onPopWithResult: (_) => _popNestedNavigator(_diagKey),
            child: Navigator(
              key: _diagKey,
              onGenerateRoute: (s) =>
                  _route(s, const DiagnosticsScreen(inShell: true)),
            ),
          ),
          NavigatorPopHandler<Object?>(
            enabled: _index == 2,
            onPopWithResult: (_) => _popNestedNavigator(_settingsKey),
            child: Navigator(
              key: _settingsKey,
              onGenerateRoute: (s) =>
                  _route(s, const SettingsScreen(inShell: true)),
            ),
          ),
        ],
      ),
      bottomNavigationBar: ListenableBuilder(
        listenable: Listenable.merge([
          MqttSessionManager.instance,
          DeveloperAccessController.instance,
        ]),
        builder: (context, _) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // The connection strip is a developer aid.
            if (DeveloperAccessController.instance.hasAccess)
              _MqttConnectionStatus(manager: MqttSessionManager.instance),
            AppBottomNav(currentIndex: _index, onTap: _onNavTap),
          ],
        ),
      ),
    );
  }
}

class _MqttConnectionStatus extends StatelessWidget {
  const _MqttConnectionStatus({required this.manager});

  final MqttSessionManager manager;

  @override
  Widget build(BuildContext context) {
    final (label, color, icon) = switch (manager.status) {
      MqttSessionStatus.connected => (
        'MQTT · Đã kết nối · ${manager.deviceIds.length} thiết bị',
        Colors.green,
        Icons.cloud_done_rounded,
      ),
      MqttSessionStatus.connecting => (
        'MQTT · Đang kết nối broker',
        Colors.orange,
        Icons.sync_rounded,
      ),
      MqttSessionStatus.reconnecting => (
        'MQTT · Đang kết nối lại',
        Colors.orange,
        Icons.sync_rounded,
      ),
      MqttSessionStatus.notConfigured => (
        'MQTT · Chưa cấu hình broker',
        Colors.blueGrey,
        Icons.cloud_off_rounded,
      ),
      MqttSessionStatus.error => (
        'MQTT · ${manager.lastError ?? 'Kết nối thất bại'}',
        Colors.red,
        Icons.error_outline_rounded,
      ),
      MqttSessionStatus.disconnected => (
        'MQTT · Đã ngắt kết nối',
        Colors.blueGrey,
        Icons.cloud_off_rounded,
      ),
      MqttSessionStatus.idle => (
        'MQTT · Chưa khởi tạo',
        Colors.blueGrey,
        Icons.cloud_outlined,
      ),
    };
    return Container(
      width: double.infinity,
      color: color.withValues(alpha: 0.08),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.caption.copyWith(color: color),
            ),
          ),
          if (manager.status == MqttSessionStatus.error ||
              manager.status == MqttSessionStatus.disconnected)
            IconButton(
              onPressed: manager.retry,
              tooltip: 'Thử kết nối MQTT lại',
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.refresh_rounded, size: 18, color: color),
            ),
        ],
      ),
    );
  }
}

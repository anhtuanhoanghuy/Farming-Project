import 'package:flutter/material.dart';

import '../screens/ble_scan_screen.dart';
import '../screens/console_screen.dart';
import '../screens/dashboard_screen.dart';
import '../screens/device_list_screen.dart';
import '../screens/load_control_screen.dart';
import '../screens/login_screen.dart';
import '../screens/provision_success_screen.dart';
import '../screens/provision_failure_screen.dart';
import '../screens/sensor_capacity_screen.dart';
import '../screens/sensor_config_screen.dart';
import '../screens/splash_screen.dart';
import '../screens/tech_log_screen.dart';
import '../screens/wifi_config_screen.dart';
import '../models/provision_success_args.dart';
import '../models/provision_failure_args.dart';
import '../models/device_selection.dart';
import '../models/load_control_selection.dart';
import 'main_shell.dart';

class AppRoutes {
  AppRoutes._();

  static const splash = '/';
  static const login = '/login';
  static const console = '/console';
  static const shell = '/shell';
  static const bleScan = '/ble-scan';
  static const wifiConfig = '/wifi-config';
  static const provisionSuccess = '/provision-success';
  static const provisionFailure = '/provision-failure';
  static const dashboard = '/dashboard';
  static const sensorCapacity = '/sensor-capacity';
  static const sensorConfig = '/sensor-config';
  static const loadControl = '/load-control';
  static const techLog = '/tech-log';

  static Route<dynamic> onGenerateRoute(RouteSettings settings) {
    switch (settings.name) {
      case splash:
        return MaterialPageRoute(builder: (_) => const SplashScreen());
      case login:
        return MaterialPageRoute(builder: (_) => const LoginScreen());
      case console:
        final args = settings.arguments is ConsoleArgs
            ? settings.arguments as ConsoleArgs
            : null;
        return MaterialPageRoute(builder: (_) => ConsoleScreen(args: args));
      case shell:
        final index = settings.arguments is int ? settings.arguments as int : 0;
        return MaterialPageRoute(
          builder: (_) => MainShell(initialIndex: index),
        );
      case bleScan:
        return MaterialPageRoute(builder: (_) => const BleScanScreen());
      case wifiConfig:
        return MaterialPageRoute(
          builder: (_) =>
              WifiConfigScreen(args: settings.arguments! as WifiConfigArgs),
        );
      case provisionSuccess:
        final args = settings.arguments;
        if (args is! ProvisionSuccessArgs) {
          throw ArgumentError('ProvisionSuccessArgs is required');
        }
        return MaterialPageRoute(
          builder: (_) => ProvisionSuccessScreen(args: args),
        );
      case provisionFailure:
        final args = settings.arguments;
        if (args is! ProvisionFailureArgs) {
          throw ArgumentError('ProvisionFailureArgs is required');
        }
        return MaterialPageRoute(
          builder: (_) => ProvisionFailureScreen(args: args),
        );
      case dashboard:
        final selection = settings.arguments;
        if (selection is! DeviceSelection) {
          throw ArgumentError('DeviceSelection is required for the dashboard');
        }
        return MaterialPageRoute(
          builder: (_) => DashboardScreen(device: selection),
        );
      case sensorCapacity:
        final selection = settings.arguments;
        if (selection is! DeviceSelection) {
          throw ArgumentError(
            'DeviceSelection is required for sensor capacity',
          );
        }
        return MaterialPageRoute(
          builder: (_) => SensorCapacityScreen(device: selection),
        );
      case sensorConfig:
        final selection = settings.arguments;
        if (selection is! SensorConfigSelection) {
          throw ArgumentError(
            'SensorConfigSelection is required for sensor configuration',
          );
        }
        return MaterialPageRoute(
          builder: (_) => SensorConfigScreen(selection: selection),
        );
      case loadControl:
        final args = settings.arguments;
        if (args is! LoadControlSelection) {
          throw ArgumentError('LoadControlSelection is required');
        }
        return MaterialPageRoute(
          builder: (_) =>
              LoadControlScreen(device: args.device, load: args.load),
        );
      case techLog:
        return MaterialPageRoute(builder: (_) => const TechLogScreen());
      default:
        return MaterialPageRoute(
          builder: (_) => const DeviceListScreen(inShell: true),
        );
    }
  }

  static void openTab(BuildContext context, int index) {
    Navigator.of(
      context,
      rootNavigator: true,
    ).pushNamedAndRemoveUntil(shell, (route) => false, arguments: index);
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'navigation/app_routes.dart';
import 'services/crud_api.dart';
import 'state/developer_access_controller.dart';
import 'theme/app_colors.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DeveloperAccessController.instance.load();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
    ),
  );

  runApp(const SenseConnectApp());
}

class SenseConnectApp extends StatelessWidget {
  const SenseConnectApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SenseConnect',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      color: AppColors.background,
      scaffoldMessengerKey: appMessengerKey,
      navigatorKey: appNavigatorKey,
      initialRoute: AppRoutes.splash,
      onGenerateRoute: AppRoutes.onGenerateRoute,
      // Tapping outside a text field drops its focus and hides the keyboard.
      builder: (context, child) => GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
        child: child,
      ),
    );
  }
}

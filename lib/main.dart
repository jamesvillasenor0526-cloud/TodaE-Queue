import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:provider/provider.dart';
import 'firebase_options.dart';
import 'config/routes.dart';
import 'config/theme.dart';
import 'config/theme_controller.dart';
import 'core/services/notification_service.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await NotificationService.instance.initialize();

  // Load saved theme
  await ThemeController.instance.loadTheme();

  NotificationService.onNotificationTap = (payload) {
    if (payload == 'dispatch') {
      navigatorKey.currentState?.pushNamedAndRemoveUntil(
        AppRoutes.driverHome,
        (route) => false,
      );
    } else if (payload == 'sos') {
      navigatorKey.currentState?.pushNamedAndRemoveUntil(
        AppRoutes.sos,
        (route) => false,
      );
    }
  };

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => ThemeController.instance,
      child: Consumer<ThemeController>(
        builder: (context, themeController, _) {
          return MaterialApp(
            title: 'TODA E-QUEUE+',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.lightTheme,
            darkTheme: AppTheme.darkTheme,
            themeMode: themeController.isDarkMode
                ? ThemeMode.dark
                : ThemeMode.light,
            navigatorKey: navigatorKey,
            onGenerateRoute: AppRoutes.generateRoute,
            initialRoute: AppRoutes.splash,
          );
        },
      ),
    );
  }
}

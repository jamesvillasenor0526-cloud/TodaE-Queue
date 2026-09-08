import 'package:flutter/material.dart';
import '../features/auth/screens/splash_screen.dart';
import '../features/auth/screens/login_screen.dart';
import '../features/auth/screens/register_screen.dart';
import '../features/auth/screens/role_select_screen.dart';
import '../features/passenger/booking/passenger_home_screen.dart';
import '../features/passenger/booking/terminal_map_screen.dart';
import '../features/passenger/sos/sos_screen.dart';
import '../features/passenger/trip_tracking/trip_tracking_screen.dart';
import '../features/driver/queue/driver_home_screen.dart';
import '../features/shared/trip_detail_screen.dart';
import '../features/shared/user_profile_screen.dart';
import '../features/shared/receipt_screen.dart';
import '../features/auth/screens/forgot_password_screen.dart';
import '../features/auth/screens/verify_email_screen.dart';
import '../features/passenger/booking/fare_matrix_screen.dart';
import '../features/shared/send_ticket_screen.dart';
import '../features/shared/about_screen.dart';

class AppRoutes {
  static const String userProfile = '/user-profile';
  static const String tripDetail = '/trip-detail';
  static const String splash = '/';
  static const String login = '/login';
  static const String register = '/register';
  static const String roleSelect = '/role-select';
  static const String passengerHome = '/passenger/home';
  static const String driverHome = '/driver/home';
  static const String terminalMap = '/terminal-map';
  static const String tripTracking = '/passenger/tracking';
  static const String sos = '/sos';
  static const String profile = '/profile';
  static const String receipt = '/receipt';
  static const String forgotPassword = '/forgot-password';
  static const String verifyEmail = '/verify-email';
  static const String fareMatrix = '/fare-matrix';
  static const String sendTicket = '/send-ticket';
  static const String about = '/about';

  static Route<dynamic> generateRoute(RouteSettings settings) {
    switch (settings.name) {
      case splash:
        return MaterialPageRoute(builder: (_) => const SplashScreen());
      case login:
        return MaterialPageRoute(builder: (_) => const LoginScreen());
      case register:
        return MaterialPageRoute(builder: (_) => const RegisterScreen());
      case roleSelect:
        return MaterialPageRoute(builder: (_) => const RoleSelectScreen());
      case passengerHome:
        return MaterialPageRoute(builder: (_) => const PassengerHomeScreen());
      case driverHome:
        return MaterialPageRoute(builder: (_) => const DriverHomeScreen());
      case terminalMap:
        return MaterialPageRoute(builder: (_) => const TerminalMapScreen());
      case sos:
        return MaterialPageRoute(builder: (_) => const SosScreen());
      case forgotPassword:
        return MaterialPageRoute(builder: (_) => const ForgotPasswordScreen());
      case verifyEmail:
        return MaterialPageRoute(builder: (_) => const VerifyEmailScreen());
      case fareMatrix:
        return MaterialPageRoute(builder: (_) => const FareMatrixScreen());
      case sendTicket:
        return MaterialPageRoute(builder: (_) => const SendTicketScreen());
      case about:
        return MaterialPageRoute(builder: (_) => const AboutScreen());
      case userProfile:
        final args = settings.arguments as Map<String, dynamic>?;
        return MaterialPageRoute(
          builder: (_) => UserProfileScreen(
            uid: args?['uid']?.toString() ?? '',
            viewerRole: args?['viewerRole']?.toString() ?? 'passenger',
          ),
        );
      case tripDetail:
        final args = settings.arguments as Map<String, dynamic>?;
        return MaterialPageRoute(
          builder: (_) => TripDetailScreen(
            bookingId: args?['bookingId']?.toString() ?? '',
            userRole: args?['userRole']?.toString() ?? 'passenger',
          ),
        );
      case tripTracking:
        final args = settings.arguments as Map<String, dynamic>?;
        return MaterialPageRoute(
          builder: (_) => TripTrackingScreen(
            bookingId: args?['bookingId']?.toString() ?? '',
            driverName: args?['driverName']?.toString() ?? 'Driver',
            terminalName: args?['terminalName']?.toString() ?? 'Terminal',
          ),
        );
      case receipt:
        return MaterialPageRoute(
          builder: (_) =>
              ReceiptScreen(bookingId: settings.arguments as String),
        );
      default:
        return MaterialPageRoute(
          builder: (_) => Scaffold(
            body: Center(child: Text('Route ${settings.name} not found')),
          ),
        );
    }
  }
}

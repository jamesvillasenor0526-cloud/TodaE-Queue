import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../config/routes.dart';
import '../../../config/theme.dart';
import '../../driver/verification/resubmit_screen.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

class RoleSelectScreen extends StatefulWidget {
  const RoleSelectScreen({super.key});

  @override
  State<RoleSelectScreen> createState() => _RoleSelectScreenState();
}

class _RoleSelectScreenState extends State<RoleSelectScreen> {
  @override
  void initState() {
    super.initState();
    _checkUserRole();
  }

  Future<void> _checkUserRole() async {
    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;

      // Save FCM token
      final fcmToken = await FirebaseMessaging.instance.getToken();
      if (fcmToken != null) {
        await FirebaseFirestore.instance.collection('users').doc(uid).update({
          'fcmToken': fcmToken,
        });
      }

      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();

      if (!mounted) return;

      if (!doc.exists) {
        Navigator.pushReplacementNamed(context, AppRoutes.login);
        return;
      }

      // An admin can disable an account from the dashboard. It stays in the
      // records — trips, ratings, receipts — but the app is closed to it.
      if (doc.data()?['isActive'] == false) {
        _showDisabledMessage();
        return;
      }

      final role = doc.data()?['role'] ?? 'passenger';

      switch (role) {
        case 'driver':
          // A rejected driver has nothing to do in the queue, on the map or
          // in their history: they go straight to why, and the form to fix
          // it.
          if (doc.data()?['verificationStatus'] == 'rejected') {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(
                builder: (_) => ResubmitScreen(profile: doc.data()!),
              ),
            );
            break;
          }
          Navigator.pushReplacementNamed(context, AppRoutes.driverHome);
          break;
        case 'toda_admin':
          _showAdminMessage();
          break;
        case 'super_admin':
          _showAdminMessage();
          break;
        default:
          Navigator.pushReplacementNamed(context, AppRoutes.passengerHome);
      }
    } catch (e) {
      if (mounted) {
        Navigator.pushReplacementNamed(context, AppRoutes.login);
      }
    }
  }

  void _showDisabledMessage() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('Account disabled'),
        content: const Text(
          'This account has been disabled by your TODA admin. '
          'Contact them to have it turned back on.',
        ),
        actions: [
          TextButton(
            onPressed: () {
              FirebaseAuth.instance.signOut();
              Navigator.pushReplacementNamed(context, AppRoutes.login);
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showAdminMessage() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Admin Account'),
        content: const Text(
          'Admin access is available via the web dashboard only.',
        ),
        actions: [
          TextButton(
            onPressed: () {
              FirebaseAuth.instance.signOut();
              Navigator.pushReplacementNamed(context, AppRoutes.login);
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: AppTheme.primaryGreen,
      body: Center(child: CircularProgressIndicator(color: AppTheme.white)),
    );
  }
}

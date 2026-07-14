import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/material.dart';

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  // Callback for when notification is tapped
  static void Function(String?)? onNotificationTap;

  Future<void> initialize() async {
    if (_initialized) return;

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: android);

    await _plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: (response) {
        onNotificationTap?.call(response.payload);
      },
    );

    _initialized = true;
  }

  Future<void> showDispatchNotification({
    required String driverName,
    required String terminalName,
  }) async {
    await initialize();

    const androidDetails = AndroidNotificationDetails(
      'dispatch_channel',
      'Dispatch Notifications',
      channelDescription: 'Notifications when a driver is dispatched',
      importance: Importance.max,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
      icon: '@mipmap/ic_launcher',
    );

    const details = NotificationDetails(android: androidDetails);

    await _plugin.show(
      1,
      '🚖 You have been dispatched!',
      'A passenger is waiting. Head to the pickup point.',
      details,
      payload: 'dispatch',
    );
  }

  Future<void> showSOSNotification({
    required String userName,
    required String userRole,
  }) async {
    await initialize();

    const androidDetails = AndroidNotificationDetails(
      'sos_channel',
      'SOS Alerts',
      channelDescription: 'Emergency SOS alerts',
      importance: Importance.max,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
      color: Colors.red,
      icon: '@mipmap/ic_launcher',
    );

    const details = NotificationDetails(android: androidDetails);

    await _plugin.show(
      2,
      '🆘 SOS Alert!',
      '$userName ($userRole) has triggered an SOS alert.',
      details,
      payload: 'sos',
    );
  }

  Future<void> showQueueNotification({
    required String terminalName,
    required int position,
  }) async {
    await initialize();

    const androidDetails = AndroidNotificationDetails(
      'queue_channel',
      'Queue Notifications',
      channelDescription: 'Queue position updates',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      icon: '@mipmap/ic_launcher',
    );

    const details = NotificationDetails(android: androidDetails);

    await _plugin.show(
      3,
      '📋 Queue Update',
      'You are #$position in queue at $terminalName.',
      details,
      payload: 'queue',
    );
  }
}

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:geolocator/geolocator.dart';

class SosService {
  static final _firestore = FirebaseFirestore.instance;
  static final _auth = FirebaseAuth.instance;

  static Future<String?> triggerSOS({
    required String userName,
    required String userRole,
  }) async {
    try {
      // Get current location
      Position? position;
      try {
        position =
            await Geolocator.getCurrentPosition(
              locationSettings: const LocationSettings(
                accuracy: LocationAccuracy.high,
              ),
            ).timeout(
              const Duration(seconds: 5),
              onTimeout: () => Future.error('timeout'),
            );
      } catch (_) {
        position = null;
      }

      final uid = _auth.currentUser!.uid;

      // Save SOS alert to Firestore
      final docRef = await _firestore.collection('sosAlerts').add({
        'userId': uid,
        'userName': userName,
        'userRole': userRole,
        'latitude': position?.latitude,
        'longitude': position?.longitude,
        'status': 'active',
        'triggeredAt': FieldValue.serverTimestamp(),
        'resolvedAt': null,
      });

      return docRef.id;
    } catch (e) {
      return null;
    }
  }

  static Future<void> resolveSOS(String alertId) async {
    await _firestore.collection('sosAlerts').doc(alertId).update({
      'status': 'resolved',
      'resolvedAt': FieldValue.serverTimestamp(),
    });
  }
}

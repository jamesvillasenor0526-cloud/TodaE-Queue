/// Raises, follows and closes SOS alerts.
///
/// The order of work is the point. The alert is written first, with what is
/// known instantly — who, and the phone's last known position — and filled in
/// afterwards with a fresh GPS reading and the trip the person is on. The old
/// version waited up to five seconds for GPS before writing anything, and when
/// GPS was slow it sent no location at all: 18 of the 50 alerts in the
/// database have none.
///
/// While an alert is open its location keeps updating, so responders follow a
/// moving tricycle rather than the spot where the button was pressed.
library;

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../models/sos_alert.dart';
import '../models/trip_state.dart';

class SosException implements Exception {
  final String message;
  SosException(this.message);
  @override
  String toString() => message;
}

class SosService {
  SosService._();
  static final SosService instance = SosService._();

  final _firestore = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  CollectionReference<Map<String, dynamic>> get _alerts =>
      _firestore.collection('sosAlerts');

  static DateTime? _toDate(dynamic v) =>
      v is Timestamp ? v.toDate() : (v is DateTime ? v : null);

  /// How long to wait for the server before telling the person the alert is
  /// queued. Firestore keeps the write and sends it once there is signal; it
  /// is the waiting that has to stop, so the screen can say "call 911".
  static const Duration _deliveryWait = Duration(seconds: 8);

  /// The signed-in person's open alert, newest first, or null.
  ///
  /// This is what lets the app remember an alert after the SOS screen is
  /// left. It used to forget: reopening showed a fresh "PRESS" button, the
  /// open alert could no longer be cancelled, and pressing again made a
  /// second one. Three alerts in the database have been "active" for days.
  Stream<SosAlert?> watchMyOpenAlert() {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return Stream.value(null);
    // Equality on one field, sorted here, so no composite index is needed.
    return _alerts.where('userId', isEqualTo: uid).snapshots().map((snap) {
      final open = [
        for (final d in snap.docs)
          SosAlert.fromMap(d.id, d.data(), toDate: _toDate),
      ].where((a) => a.status.isOpen).toList()
        ..sort((a, b) {
          final x = a.triggeredAt, y = b.triggeredAt;
          if (x == null) return -1; // just written, not yet timestamped
          if (y == null) return 1;
          return y.compareTo(x);
        });
      return open.isEmpty ? null : open.first;
    });
  }

  /// [alertId] as the server has it now, bypassing the local cache.
  ///
  /// The live listener can die without saying so: on the first end-to-end
  /// test, Firestore's stream closed ("Keepalive failed. The connection is
  /// likely gone") and the admin's acknowledgement never reached the screen,
  /// which went on saying "Waiting for one to respond". Asking the server
  /// directly both fetches the current status and proves whether the phone
  /// can reach it at all. Throws when it cannot.
  Future<SosAlert> fetchFromServer(String alertId) async {
    final snap = await _alerts
        .doc(alertId)
        .get(const GetOptions(source: Source.server))
        .timeout(const Duration(seconds: 8));
    final data = snap.data();
    if (data == null) throw SosException('Alert not found.');
    return SosAlert.fromMap(snap.id, data, toDate: _toDate);
  }

  /// Raises an alert now.
  ///
  /// [delivered] is false when the server could not be reached in time: the
  /// alert is saved on the phone and will send itself when signal returns,
  /// and the screen says so rather than pretending it went.
  Future<({String id, bool delivered})> trigger() async {
    final user = _auth.currentUser;
    if (user == null) throw SosException('Please sign in to send an SOS.');

    final profile = await _profile(user.uid);
    final last = await _lastKnownPosition();

    final ref = _alerts.doc();
    final data = <String, dynamic>{
      'userId': user.uid,
      'userName': profile.name,
      'userRole': profile.role,
      'userPhone': profile.phone,
      'status': SosStatus.active.wire,
      'triggeredAt': FieldValue.serverTimestamp(),
      'resolvedAt': null,
      // Old dashboards read these two directly, so they are always present.
      'latitude': last?.latitude,
      'longitude': last?.longitude,
      if (last != null) ..._locationFields(last, SosLocationSource.lastKnown),
    };

    var delivered = true;
    try {
      await ref.set(data).timeout(_deliveryWait);
    } on TimeoutException {
      delivered = false; // queued; Firestore sends it when back online
    } on FirebaseException catch (e) {
      throw SosException(
        e.code == 'permission-denied'
            ? 'Your account could not send an SOS. Call 911 now.'
            : 'The alert could not be sent. Call 911 now.',
      );
    }

    // Filled in afterwards: nothing here may delay the alert itself.
    unawaited(_enrich(ref, user.uid));
    track(ref.id);
    return (id: ref.id, delivered: delivered);
  }

  /// Adds a fresh GPS reading and the trip, as each becomes available.
  Future<void> _enrich(
    DocumentReference<Map<String, dynamic>> ref,
    String uid,
  ) async {
    try {
      final trip = await _activeTrip(uid);
      if (trip != null) await ref.update({'trip': trip.toMap()});
    } catch (e) {
      debugPrint('SOS: could not attach the trip: $e');
    }
    try {
      if (!await _locationAllowed()) return;
      final fresh = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      ).timeout(const Duration(seconds: 25));
      await ref.update(_locationFields(fresh, SosLocationSource.gps));
    } catch (e) {
      debugPrint('SOS: no fresh position yet: $e');
    }
  }

  // ---- Following an open alert --------------------------------------------

  StreamSubscription<Position>? _tracking;
  Timer? _heartbeat;
  String? _trackingId;
  DateTime? _lastWrite;

  /// Writes are at most this frequent while following an alert.
  static const Duration _trackEvery = Duration(seconds: 10);

  /// The longest a still phone goes without sending a fresh fix.
  ///
  /// The stream only reports movement of 15 m or more, so someone who has
  /// stopped — held somewhere, or collapsed — sent nothing, and responders
  /// saw "updated 3 min ago" on the second end-to-end test and could not
  /// tell a person standing still from a phone that had gone quiet.
  static const Duration _heartbeatEvery = Duration(minutes: 1);

  /// Keeps [alertId]'s location current while it is open. Safe to call
  /// repeatedly — the SOS screen and the SOS button both do.
  void track(String alertId) {
    if (_trackingId == alertId && _tracking != null) return;
    stopTracking();
    _trackingId = alertId;
    _startTracking(alertId);
  }

  Future<void> _startTracking(String alertId) async {
    if (!await _locationAllowed()) return;
    if (_trackingId != alertId) return;
    _tracking = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 15,
      ),
    ).listen((p) {
      final now = DateTime.now();
      if (_lastWrite != null && now.difference(_lastWrite!) < _trackEvery) {
        return;
      }
      _writeLocation(alertId, p);
    }, onError: (Object e) => debugPrint('SOS: tracking error: $e'));
    _heartbeat = Timer.periodic(_heartbeatEvery, (_) async {
      final last = _lastWrite;
      if (last != null &&
          DateTime.now().difference(last) < _heartbeatEvery - _trackEvery) {
        return; // moving, so the stream is already writing
      }
      try {
        // A fresh fix, not the cached one: its own timestamp is what says
        // "updated just now", so resending an old fix would prove nothing.
        final p = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
          ),
        ).timeout(const Duration(seconds: 20));
        if (_trackingId == alertId) _writeLocation(alertId, p);
      } catch (e) {
        debugPrint('SOS: heartbeat fix: $e');
      }
    });
  }

  void _writeLocation(String alertId, Position p) {
    _lastWrite = DateTime.now();
    _alerts
        .doc(alertId)
        .update(_locationFields(p, SosLocationSource.gps))
        .catchError((Object e) => debugPrint('SOS: location update: $e'));
  }

  void stopTracking() {
    _tracking?.cancel();
    _tracking = null;
    _heartbeat?.cancel();
    _heartbeat = null;
    _trackingId = null;
    _lastWrite = null;
  }

  /// "I'm safe." Recorded as a cancellation, not a resolution, so admins can
  /// tell the two apart — the old version wrote both as "resolved".
  ///
  /// Closes every alert this person has open, not just [alertId]. "I'm safe"
  /// means safe: someone who pressed three times in a panic should not have
  /// to say so three times. The one test account in the database with stuck
  /// alerts had exactly that — three raised within twenty minutes, because
  /// the old app forgot each one and the button was pressed again.
  Future<void> cancel(String alertId) async {
    stopTracking();
    final uid = _auth.currentUser?.uid;
    final ids = <String>{alertId};
    if (uid != null) {
      try {
        final mine = await _alerts
            .where('userId', isEqualTo: uid)
            .get()
            .timeout(const Duration(seconds: 6));
        for (final d in mine.docs) {
          if (SosStatus.fromWire(d.data()['status'] as String?).isOpen) {
            ids.add(d.id);
          }
        }
      } catch (_) {
        // Cancelling the one in view still goes ahead.
      }
    }
    final batch = _firestore.batch();
    for (final id in ids) {
      batch.update(_alerts.doc(id), {
        'status': SosStatus.cancelled.wire,
        'cancelledAt': FieldValue.serverTimestamp(),
      });
    }
    try {
      await batch.commit();
    } on FirebaseException {
      throw SosException('Could not cancel the alert. Check your connection.');
    }
  }

  // ---- Helpers -------------------------------------------------------------

  Map<String, dynamic> _locationFields(Position p, SosLocationSource source) => {
    'latitude': p.latitude,
    'longitude': p.longitude,
    'locationAccuracy': p.accuracy,
    'locationAt': Timestamp.fromDate(p.timestamp),
    'locationSource': source.wire,
  };

  Future<bool> _locationAllowed() async {
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      return permission != LocationPermission.denied &&
          permission != LocationPermission.deniedForever;
    } catch (_) {
      return false;
    }
  }

  /// The phone's last known position, if recent enough to send.
  Future<Position?> _lastKnownPosition() async {
    try {
      final p = await Geolocator.getLastKnownPosition().timeout(
        const Duration(seconds: 2),
      );
      if (p == null) return null;
      if (DateTime.now().difference(p.timestamp) > kMaxLastKnownAge) {
        return null;
      }
      return p;
    } catch (_) {
      return null;
    }
  }

  /// Name, role and phone, from the cache if the network is slow.
  Future<({String name, String role, String? phone})> _profile(
    String uid,
  ) async {
    try {
      final doc = await _firestore
          .collection('users')
          .doc(uid)
          .get()
          .timeout(const Duration(seconds: 3));
      final data = doc.data() ?? const {};
      final name = (data['name'] ?? data['fullName']) as String?;
      return (
        name: (name == null || name.trim().isEmpty) ? 'Unknown' : name.trim(),
        role: (data['role'] as String?) ?? 'passenger',
        phone: data['phone'] as String?,
      );
    } catch (_) {
      // An SOS must go out even if the profile cannot be read.
      return (
        name: _auth.currentUser?.displayName ?? 'Unknown',
        role: 'passenger',
        phone: _auth.currentUser?.phoneNumber,
      );
    }
  }

  /// The trip [uid] is on now, as passenger or driver, if any.
  Future<SosTrip?> _activeTrip(String uid) async {
    final bookings = _firestore.collection('bookings');
    final found = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    for (final field in const ['passengerId', 'driverId']) {
      try {
        final snap = await bookings
            .where(field, isEqualTo: uid)
            .get()
            .timeout(const Duration(seconds: 5));
        found.addAll(snap.docs);
      } catch (_) {
        // One side failing should not lose the other.
      }
    }
    final active = found
        .where((d) => TripState.fromMap(d.id, d.data()).isActive)
        .toList();
    if (active.isEmpty) return null;
    // The most recent, if somehow more than one is open.
    active.sort((a, b) {
      final x = _toDate(a.data()['createdAt']);
      final y = _toDate(b.data()['createdAt']);
      if (x == null || y == null) return 0;
      return y.compareTo(x);
    });
    final booking = active.first;
    final data = booking.data();

    String? plate, body;
    final driverId = data['driverId'] as String?;
    if (driverId != null && driverId.isNotEmpty) {
      try {
        final driver = await _firestore
            .collection('users')
            .doc(driverId)
            .get()
            .timeout(const Duration(seconds: 3));
        plate = driver.data()?['plateNumber'] as String?;
        body = driver.data()?['bodyNumber'] as String?;
      } catch (_) {
        // The booking alone still says who the driver is.
      }
    }

    return SosTrip(
      bookingId: booking.id,
      driverName: data['driverName'] as String?,
      driverPhone: data['driverPhone'] as String?,
      plateNumber: plate,
      bodyNumber: body,
      passengerName: data['passengerName'] as String?,
    );
  }
}

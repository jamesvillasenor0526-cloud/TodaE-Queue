import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../models/road_report.dart';
import 'cloudinary_service.dart';
import 'traffic_incident_service.dart';

/// Raised when a report can't be submitted. The message is safe to show.
class ReportException implements Exception {
  final String message;
  ReportException(this.message);
  @override
  String toString() => message;
}

/// Outcome of a submission, so the UI can say what actually happened rather
/// than always claiming a new report was filed.
enum ReportOutcome { created, confirmedExisting }

/// Owns the crowd-sourced `reports` collection: traffic conditions and
/// incidents tagged by drivers and passengers.
///
/// Reports expire on read rather than being deleted by a scheduled job —
/// [ReportType.lifespan] decides how long each type is trusted — so this
/// needs no Cloud Function to stay tidy.
class ReportService {
  ReportService._();
  static final ReportService instance = ReportService._();

  final _firestore = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  /// Two reports of the same type closer than this are treated as the same
  /// event, so the map shows one corroborated pin instead of a cluster of
  /// duplicates.
  static const double dedupeRadiusKm = 0.15;

  CollectionReference<Map<String, dynamic>> get _col =>
      _firestore.collection('reports');

  static DateTime? _toDate(dynamic v) =>
      v is Timestamp ? v.toDate() : (v is DateTime ? v : null);

  RoadReport _fromDoc(QueryDocumentSnapshot<Map<String, dynamic>> d) =>
      RoadReport.fromMap(d.id, d.data(), toDate: _toDate);

  /// Live reports near [origin], nearest first.
  ///
  /// The Firestore query is deliberately over-inclusive (everything created
  /// within the longest lifespan) and the precise expiry/radius filtering
  /// happens on the client. That keeps it to a single-field index, and a
  /// periodic tick re-emits the filtered list so pins disappear when they go
  /// stale instead of lingering until the next write.
  Stream<List<RoadReport>> watchNearby(
    LatLng origin, {
    double radiusKm = 5,
    ReportCategory? only,
  }) {
    const maxLifespan = Duration(hours: 3);
    late StreamController<List<RoadReport>> controller;
    StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? sub;
    Timer? ticker;
    var latest = <RoadReport>[];

    void emit() {
      if (controller.isClosed) return;
      controller.add(
        visibleReports(
          latest,
          origin,
          now: DateTime.now(),
          radiusKm: radiusKm,
          only: only,
        ),
      );
    }

    controller = StreamController<List<RoadReport>>(
      onListen: () {
        sub = _col
            .where(
              'createdAt',
              isGreaterThan: Timestamp.fromDate(
                DateTime.now().subtract(maxLifespan),
              ),
            )
            .orderBy('createdAt', descending: true)
            .limit(200)
            .snapshots()
            .listen(
              (snap) {
                latest = snap.docs.map(_fromDoc).toList();
                emit();
              },
              onError: controller.addError,
            );
        ticker = Timer.periodic(const Duration(minutes: 1), (_) => emit());
      },
      onCancel: () async {
        ticker?.cancel();
        await sub?.cancel();
      },
    );

    return controller.stream;
  }

  /// Reports the signed-in user filed, newest first — used by "My reports".
  ///
  /// Sorted on the client so this stays a single-field equality query and
  /// needs no composite index.
  Stream<List<RoadReport>> watchMine() {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return Stream.value(const []);
    return _col.where('reportedBy', isEqualTo: uid).snapshots().map((s) {
      final list = s.docs.map(_fromDoc).toList();
      list.sort((a, b) {
        final x = a.createdAt, y = b.createdAt;
        if (x == null || y == null) return 0;
        return y.compareTo(x);
      });
      return list;
    });
  }

  /// Current device location, or null if it can't be obtained.
  ///
  /// A report without a location is useless, so callers treat null as a hard
  /// failure rather than filing a pin at (0, 0).
  Future<LatLng?> currentLocation() async {
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      ).timeout(const Duration(seconds: 8));
      return LatLng(pos.latitude, pos.longitude);
    } catch (_) {
      return null;
    }
  }

  /// Files a report at [location].
  ///
  /// If someone already flagged the same thing nearby, this confirms that
  /// report instead of adding a duplicate pin, and says so in the result.
  Future<ReportOutcome> submit({
    required ReportType type,
    required LatLng location,
    required String reporterName,
    required String reporterRole,
    String? note,
    File? photo,
    String? tripId,
  }) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) {
      throw ReportException('Please sign in before reporting.');
    }

    final existing = await _findNearbyDuplicate(type, location);
    if (existing != null) {
      // Someone beat us to it — corroborate rather than clutter the map.
      await confirm(existing.id);
      return ReportOutcome.confirmedExisting;
    }

    // Uploaded before the write so the report never points at a half-finished
    // upload; a failed upload downgrades to a text-only report rather than
    // losing the whole thing.
    String? photoUrl;
    if (photo != null) {
      photoUrl = await CloudinaryService.instance.uploadImage(photo, 'reports');
    }

    // Ask the live traffic feed whether it can see the same thing. Only ever
    // used to support the report — a feed that lags, or does not cover a
    // barangay street, saying nothing is not evidence the driver is wrong.
    var corroborated = false;
    try {
      final measured = await TrafficIncidentService.instance.near(location);
      corroborated = liveTrafficAgreesWith(type, location, measured);
    } catch (_) {
      // Corroboration is a bonus, never a gate on filing a report.
    }

    final now = DateTime.now();
    final trimmed = note?.trim();
    try {
      await _col.add({
        'type': type.wire,
        'category': type.category.name,
        'latitude': location.latitude,
        'longitude': location.longitude,
        'note': (trimmed == null || trimmed.isEmpty) ? null : trimmed,
        'photoUrl': photoUrl,
        'reportedBy': uid,
        'reporterName': reporterName,
        'reporterRole': reporterRole,
        // Lets an admin see which journey a report came from.
        'tripId': tripId,
        'confirmations': 0,
        'confirmedBy': <String>[],
        // Independent agreement from measured traffic at the moment of
        // filing. Counts as one corroboration; never written as false to
        // mean "contradicted", only "not seen".
        'corroboratedByTraffic': corroborated,
        'cleared': false,
        // Starts unverified: corroboration or an admin promotes it.
        'status': IncidentStatus.reported.wire,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        // Absolute expiry, so every client agrees on when this goes stale
        // without needing a scheduled cleanup.
        'expiresAt': Timestamp.fromDate(now.add(type.lifespan)),
      });
    } on FirebaseException catch (e) {
      throw ReportException(_friendly(e));
    }
    return ReportOutcome.created;
  }

  /// A live report of the same type close enough to be the same event.
  Future<RoadReport?> _findNearbyDuplicate(
    ReportType type,
    LatLng location,
  ) async {
    // Only the recency window is filtered server-side; type and distance are
    // matched on the client so this stays a single-field query with no
    // composite index to deploy.
    try {
      final snap = await _col
          .where(
            'createdAt',
            isGreaterThan: Timestamp.fromDate(
              DateTime.now().subtract(type.lifespan),
            ),
          )
          .orderBy('createdAt', descending: true)
          .limit(50)
          .get();
      final now = DateTime.now();
      for (final doc in snap.docs) {
        final r = _fromDoc(doc);
        if (r.type == type &&
            r.isLive(now) &&
            distanceKm(location, r.location) <= dedupeRadiusKm) {
          return r;
        }
      }
    } catch (_) {
      // Dedupe is an optimisation; if the lookup fails, file the report.
    }
    return null;
  }

  /// Corroborates a report: bumps the count and pushes back its expiry, so
  /// conditions people keep confirming stay on the map.
  ///
  /// Confirming twice, or confirming your own report, is a no-op.
  Future<void> confirm(String reportId) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) throw ReportException('Please sign in first.');

    try {
      await _firestore.runTransaction((tx) async {
        final ref = _col.doc(reportId);
        final snap = await tx.get(ref);
        if (!snap.exists) {
          throw ReportException('That report is no longer there.');
        }
        final report = RoadReport.fromMap(
          reportId,
          snap.data() ?? const {},
          toDate: _toDate,
        );
        if (report.confirmedByUser(uid) || report.reportedBy == uid) return;

        tx.update(ref, {
          'confirmations': FieldValue.increment(1),
          'confirmedBy': FieldValue.arrayUnion([uid]),
          'expiresAt': Timestamp.fromDate(
            DateTime.now().add(report.type.lifespan),
          ),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      });
    } on FirebaseException catch (e) {
      throw ReportException(_friendly(e));
    }
  }

  /// Marks a report as no longer applicable. Only the person who filed it can
  /// do this from the app; admins clear anything from the dashboard.
  Future<void> clear(String reportId) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) throw ReportException('Please sign in first.');
    try {
      await _col.doc(reportId).update({
        'cleared': true,
        'clearedAt': FieldValue.serverTimestamp(),
        'clearedBy': uid,
      });
    } on FirebaseException catch (e) {
      throw ReportException(_friendly(e));
    }
  }

  String _friendly(FirebaseException e) => switch (e.code) {
    'permission-denied' => 'You don\'t have permission to do that.',
    'unavailable' => 'Can\'t reach the server. Check your connection.',
    _ => 'Something went wrong. Please try again.',
  };
}

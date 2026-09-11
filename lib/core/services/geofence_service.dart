import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

/// Handles location permissions and live position streaming, and checks
/// whether a position falls inside a terminal's boundary polygon (as
/// stored in the `terminals` collection in Firestore).
///
/// Position updates are broadcast: multiple independent listeners (e.g.
/// arrival-detection logic AND a "show me on the map" widget) can each
/// subscribe to [positionStream] without cancelling one another out.
class GeofenceService {
  GeofenceService._();
  static final GeofenceService instance = GeofenceService._();

  StreamSubscription<Position>? _rawSub;
  final StreamController<Position> _positionController =
      StreamController<Position>.broadcast();
  bool _isTracking = false;

  /// Broadcast stream of live position updates. Safe for multiple
  /// widgets to listen to independently.
  Stream<Position> get positionStream => _positionController.stream;

  /// Requests location permission if needed. Returns true if granted.
  Future<bool> ensurePermission() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return false;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.deniedForever) return false;

    return permission == LocationPermission.whileInUse ||
        permission == LocationPermission.always;
  }

  Future<Position?> getCurrentPosition() async {
    final granted = await ensurePermission();
    if (!granted) return null;
    return Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    );
  }

  /// Starts the shared GPS stream if it isn't already running. Idempotent
  /// — safe to call from multiple places (each caller should still keep
  /// its own subscription to [positionStream] and cancel that on dispose,
  /// rather than calling [stopTracking] itself).
  ///
  /// Returns whether tracking is active (false if permission was denied).
  Future<bool> startTracking() async {
    if (_isTracking) return true;

    final granted = await ensurePermission();
    if (!granted) return false;

    // Every ~3 m, at most every 2 s. On Android the interval has to be
    // asked for, or the system delivers a reading only every 5 s — too
    // coarse for the passenger's and the dashboard's live maps, which this
    // stream feeds (through the driver home screen's location writes).
    final settings = defaultTargetPlatform == TargetPlatform.android
        ? AndroidSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 3,
            intervalDuration: const Duration(seconds: 2),
          )
        : const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 3, // re-check after moving ~3 meters
          );
    _rawSub = Geolocator.getPositionStream(
      locationSettings: settings,
    ).listen((pos) => _positionController.add(pos));

    _isTracking = true;
    return true;
  }

  /// Stops the shared GPS stream entirely. Only call this when location
  /// tracking should truly end for the whole app (e.g. on logout) —
  /// individual widgets should cancel their own subscription to
  /// [positionStream] in their own dispose() instead.
  void stopTracking() {
    _rawSub?.cancel();
    _rawSub = null;
    _isTracking = false;
  }

  /// Ray-casting point-in-polygon test.
  bool isPointInPolygon(LatLng point, List<LatLng> polygon) {
    if (polygon.length < 3) return false;
    bool inside = false;
    for (int i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
      final xi = polygon[i].longitude, yi = polygon[i].latitude;
      final xj = polygon[j].longitude, yj = polygon[j].latitude;
      final intersect =
          ((yi > point.latitude) != (yj > point.latitude)) &&
          (point.longitude <
              (xj - xi) * (point.latitude - yi) / (yj - yi) + xi);
      if (intersect) inside = !inside;
    }
    return inside;
  }

  /// Checks all terminals in Firestore and returns the first one whose
  /// boundary polygon contains [point], or null if none match.
  Future<QueryDocumentSnapshot<Map<String, dynamic>>?> findTerminalAtPoint(
    LatLng point,
  ) async {
    final snapshot = await FirebaseFirestore.instance
        .collection('terminals')
        .get();

    for (final doc in snapshot.docs) {
      final data = doc.data();
      final rawBoundary = data['boundary'] as List<dynamic>? ?? [];
      final polygon = rawBoundary.map(_parsePoint).whereType<LatLng>().toList();

      if (polygon.length >= 3 && isPointInPolygon(point, polygon)) {
        return doc;
      }
    }
    return null;
  }

  LatLng? _parsePoint(dynamic raw) {
    try {
      if (raw is GeoPoint) return LatLng(raw.latitude, raw.longitude);
      if (raw is List && raw.length >= 2) {
        final lat = _toDouble(raw[0]);
        final lng = _toDouble(raw[1]);
        if (lat != null && lng != null) return LatLng(lat, lng);
      }
      if (raw is Map) {
        final lat = _toDouble(raw['lat'] ?? raw['latitude']);
        final lng = _toDouble(raw['lng'] ?? raw['longitude']);
        if (lat != null && lng != null) return LatLng(lat, lng);
      }
    } catch (_) {}
    return null;
  }

  double? _toDouble(dynamic v) {
    if (v == null) return null;
    if (v is double) return v;
    if (v is int) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }
}

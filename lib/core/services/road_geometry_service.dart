import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../models/road_report.dart';
import '../models/traffic_segment.dart';

/// Fetches the shape of the roads under a set of congestion zones, so
/// traffic can be painted along the road instead of as a blob over it.
///
/// Uses the public Overpass API against OpenStreetMap data — the same free
/// stack as the tiles and routing, no key and no quota to manage. Overpass
/// is a shared community service, so this is written to be a light guest:
/// one batched request for all zones, results cached, and a hard cap on how
/// often it will ask.
///
/// Every failure path degrades to "no geometry", which the map renders as
/// the older zone shading rather than an error.
class RoadGeometryService {
  RoadGeometryService._();
  static final RoadGeometryService instance = RoadGeometryService._();

  /// Overpass mirrors, tried in order.
  ///
  /// The main instance is popular and answers 504 under load often enough to
  /// see in casual testing, so a single endpoint would leave the overlay
  /// stuck on zone shading for no good reason. All three are public
  /// community mirrors of the same OpenStreetMap data.
  static const _endpoints = [
    'https://overpass-api.de/api/interpreter',
    'https://overpass.kumi.systems/api/interpreter',
    'https://overpass.private.coffee/api/interpreter',
  ];

  /// How far from a report a road can be and still be considered the one
  /// meant. Wide enough for GPS drift on a moving tricycle, tight enough not
  /// to grab the road one block over.
  static const double snapRadiusMeters = 60;

  /// Overpass asks clients not to hammer it; nothing here is time-critical.
  static const _minInterval = Duration(seconds: 30);

  final Map<String, List<RoadWay>> _cache = {};
  DateTime? _lastRequest;
  Future<List<RoadWay>>? _inFlight;

  /// Cache key for a location, rounded to roughly 30 m so that a zone whose
  /// centre drifts slightly still reuses the roads already fetched.
  String _key(LatLng p) =>
      '${p.latitude.toStringAsFixed(3)},${p.longitude.toStringAsFixed(3)}';

  /// Roads near [zones], from cache where possible.
  ///
  /// Returns an empty list rather than throwing: the overlay must keep
  /// working when Overpass is slow, rate-limiting, or unreachable.
  Future<List<RoadWay>> waysFor(List<CongestionZone> zones) async {
    if (zones.isEmpty) return const [];

    final cached = <RoadWay>[];
    final missing = <CongestionZone>[];
    for (final zone in zones) {
      final hit = _cache[_key(zone.center)];
      if (hit != null) {
        cached.addAll(hit);
      } else {
        missing.add(zone);
      }
    }
    if (missing.isEmpty) return cached;

    // Throttle: serve what is cached now and pick the rest up on a later
    // refresh rather than queueing requests behind each other.
    final last = _lastRequest;
    if (last != null && DateTime.now().difference(last) < _minInterval) {
      return cached;
    }
    // Coalesce concurrent callers — four maps can be alive at once.
    if (_inFlight != null) {
      final pending = await _inFlight!;
      return [...cached, ...pending];
    }

    _lastRequest = DateTime.now();
    final future = _fetch(missing);
    _inFlight = future;
    try {
      final fetched = await future;
      return [...cached, ...fetched];
    } finally {
      _inFlight = null;
    }
  }

  Future<List<RoadWay>> _fetch(List<CongestionZone> zones) async {
    // One request covering every zone, rather than one per zone.
    final clauses = zones
        .map(
          (z) =>
              'way(around:${snapRadiusMeters.toInt()},'
              '${z.center.latitude.toStringAsFixed(6)},'
              '${z.center.longitude.toStringAsFixed(6)})'
              '["highway"~"^(motorway|trunk|primary|secondary|tertiary|'
              'unclassified|residential|living_street|service|road)\$"];',
        )
        .join();
    final query = '[out:json][timeout:20];($clauses);out geom;';

    for (final endpoint in _endpoints) {
      try {
        final response = await http
            .post(
              Uri.parse(endpoint),
              headers: const {
                'Content-Type': 'application/x-www-form-urlencoded',
                // Overpass asks that clients identify themselves.
                'User-Agent': 'TodaEqueuePlus/1.0 (Baliwag City TODA)',
              },
              body: {'data': query},
            )
            .timeout(const Duration(seconds: 20));

        if (response.statusCode != 200) {
          // 429 and 504 mean this mirror is busy, not that the data is
          // missing — worth asking the next one.
          debugPrint('Overpass $endpoint returned ${response.statusCode}');
          continue;
        }

        // Fragments are joined into whole roads here so the map paints a
        // coloured street rather than a stub between two junctions.
        final ways = mergeConnectedWays(parseOverpassWays(response.body));
        if (ways.isEmpty) return const [];

        // Cache per zone so a later refresh with the same centres needs no
        // request at all.
        for (final zone in zones) {
          _cache[_key(zone.center)] = [
            for (final w in ways)
              if ((nearestOnWay(w.points, zone.center)?.distanceMeters ??
                      double.infinity) <=
                  snapRadiusMeters * 2)
                w,
          ];
        }
        return ways;
      } catch (e) {
        debugPrint('Overpass $endpoint unavailable: $e');
      }
    }
    return const [];
  }

  @visibleForTesting
  void clearCache() {
    _cache.clear();
    _lastRequest = null;
  }
}

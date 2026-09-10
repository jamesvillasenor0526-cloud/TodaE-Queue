/// Turns two points into real, drivable routes.
///
/// Built on the public OSRM server, which is free and needs no key. Two of
/// its properties shape everything here, and both were confirmed against the
/// live service rather than assumed:
///
///   * It returns turn-by-turn steps with real street names.
///   * It returns exactly **one** route. `alternatives=true` and
///     `alternatives=3` both come back with a single route, so alternatives
///     have to be produced another way.
///
/// So alternatives are obtained by asking OSRM to route *via* a waypoint set
/// off to one side. Every route that comes back is still a genuine OSRM
/// result on real roads — nothing is invented — it has simply been pushed
/// through a different corridor. Measured on a Baliwag pair, this yields
/// routes sharing only ~50% of their geometry with the direct one.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../models/navigation_state.dart';
import '../models/traffic_segment.dart' show nearestOnWay;
import 'tomtom_router.dart';

class NavigationRouter {
  NavigationRouter._();
  static final NavigationRouter instance = NavigationRouter._();

  static const _base = 'https://router.project-osrm.org/route/v1/driving/';

  /// OSRM is a free community service; this keeps the app a light guest.
  static const _timeout = Duration(seconds: 15);

  /// The direct route between two points, with turn instructions.
  ///
  /// Falls back to a straight line only if OSRM cannot be reached, and the
  /// result is flagged so the UI can say routing is unavailable instead of
  /// drawing an invented road.
  Future<NavRoute> route(LatLng from, LatLng to) async {
    final result = await _request([from, to]);
    return result ?? NavRoute.straightLine(from, to);
  }

  /// The direct route plus up to [maxAlternatives] genuinely different ones.
  ///
  /// [avoid] biases the detour waypoints away from a known problem, which is
  /// what makes "route around this closure" work rather than just offering
  /// arbitrary detours.
  Future<List<NavRoute>> routeWithAlternatives(
    LatLng from,
    LatLng to, {
    int maxAlternatives = 2,
    List<LatLng> avoid = const [],
  }) async {
    // TomTom returns genuine alternatives and traffic-aware times, so when
    // a key is configured there is nothing to force with detour waypoints.
    if (TomTomRouter.isConfigured) {
      final fromTomTom = await TomTomRouter.instance.route(
        from,
        to,
        maxAlternatives: maxAlternatives,
        // Previously not passed at all: the avoid point only ever shaped the
        // OSRM fallback, so on TomTom a reported incident could be ranked
        // against but never actually routed around.
        avoid: avoid,
      );
      if (fromTomTom.isNotEmpty) return fromTomTom;
      // Key present but the call failed or was over quota: fall through to
      // OSRM rather than leaving the driver without a route.
    }

    final direct = await _request([from, to]);
    final routes = <NavRoute>[?direct];

    if (direct == null) {
      // No point generating detours around a route we could not fetch.
      return [NavRoute.straightLine(from, to)];
    }

    // Push the detour off to each side of whatever we are avoiding — or of
    // the midpoint, when simply looking for options.
    final pivot = avoid.firstOrNull ?? _midpoint(from, to);
    final span = _degreesBetween(from, to);

    // Gentle offsets first, so the least contrived detour is found before
    // the wilder ones. A big offset produces a route that is certainly
    // different and almost certainly useless.
    for (final offset in const [0.12, -0.12, 0.22, -0.22, 0.35, -0.35]) {
      if (routes.length > maxAlternatives) break;
      final waypoint = _perpendicularOffset(from, to, pivot, span * offset);
      final candidate = await _request([from, waypoint, to]);
      if (candidate == null) continue;

      // A detour half again as long as the direct route is not a choice a
      // driver would make. This used to allow 2.2x, which is how a 7.7 km
      // run ended up offered against a 10.6 km loop.
      if (candidate.distanceMeters > direct.distanceMeters * 1.5) continue;
      if (routes.any((r) => _overlapFraction(r, candidate) > 0.8)) continue;
      routes.add(candidate);
    }
    return routes;
  }

  /// Ways from [from] to [to] that stay clear of every point in [avoid],
  /// found on OpenStreetMap's road network, plus OSRM's direct route for
  /// calibrating their times.
  ///
  /// This exists because TomTom's map is missing roads OSM has — barangay
  /// streets, which are exactly where tricycles drive. Asked to avoid a
  /// confirmed accident on the road out of Calantipay, TomTom returned the
  /// same three routes straight through it; even told to go via Ramos
  /// Street, it drove through the accident to get there. OSRM found the way
  /// round on Ramos Street, 257 m clear of it.
  ///
  /// Only routes that actually keep [clearanceMeters] from every point are
  /// returned. A waypoint pushes a route into a corridor but does not stop
  /// it passing the incident on the way there, and a "way round" that goes
  /// through what it is going round is worse than none.
  Future<({NavRoute? direct, List<NavRoute> around})> osmWaysAround(
    LatLng from,
    LatLng to, {
    required List<LatLng> avoid,
    double clearanceMeters = kIncidentOnRouteMeters,
    int maxRoutes = 1,
  }) async {
    final direct = await _request([from, to]);
    if (direct == null || avoid.isEmpty) return (direct: direct, around: <NavRoute>[]);

    bool clearOfAll(NavRoute r) => avoid.every(
      (a) =>
          (nearestOnWay(r.points, a)?.distanceMeters ?? double.infinity) >
          clearanceMeters,
    );

    final around = <NavRoute>[];
    final span = _degreesBetween(from, to);
    // Gentle offsets first, as for alternatives: the least contrived way
    // round is the one a driver would actually take.
    for (final offset in const [0.12, -0.12, 0.22, -0.22, 0.35, -0.35]) {
      if (around.length >= maxRoutes) break;
      final waypoint = _perpendicularOffset(from, to, avoid.first, span * offset);
      final candidate = await _request([from, waypoint, to]);
      if (candidate == null) continue;
      // Twice the direct distance is a tour of the district, not a detour.
      if (candidate.distanceMeters > direct.distanceMeters * 2) continue;
      if (!clearOfAll(candidate)) continue;
      if (around.any((r) => _overlapFraction(r, candidate) > 0.8)) continue;
      around.add(candidate);
    }
    return (direct: direct, around: around);
  }

  Future<NavRoute?> _request(List<LatLng> waypoints) async {
    final path = waypoints
        .map((p) => '${p.longitude},${p.latitude}')
        .join(';');
    final uri = Uri.parse(
      '$_base$path?overview=full&geometries=geojson&steps=true',
    );

    try {
      final response = await http
          .get(uri, headers: const {'User-Agent': 'TodaEqueuePlus/1.0'})
          .timeout(_timeout);
      if (response.statusCode != 200) {
        debugPrint('OSRM returned ${response.statusCode}');
        return null;
      }
      return parseOsrmRoute(response.body);
    } catch (e) {
      debugPrint('OSRM unreachable: $e');
      return null;
    }
  }

  LatLng _midpoint(LatLng a, LatLng b) => LatLng(
    (a.latitude + b.latitude) / 2,
    (a.longitude + b.longitude) / 2,
  );

  double _degreesBetween(LatLng a, LatLng b) => math.sqrt(
    math.pow(b.latitude - a.latitude, 2) +
        math.pow(b.longitude - a.longitude, 2),
  );

  /// A point [amount] degrees to the side of the line from [a] to [b],
  /// measured out from [pivot].
  LatLng _perpendicularOffset(
    LatLng a,
    LatLng b,
    LatLng pivot,
    double amount,
  ) {
    final dx = b.longitude - a.longitude;
    final dy = b.latitude - a.latitude;
    final length = math.sqrt(dx * dx + dy * dy);
    if (length == 0) return pivot;
    // Rotate the direction 90° to get the perpendicular.
    return LatLng(
      pivot.latitude + (dx / length) * amount,
      pivot.longitude - (dy / length) * amount,
    );
  }

  /// Roughly how much of [b] runs along [a], for rejecting near-duplicates.
  double _overlapFraction(NavRoute a, NavRoute b) {
    if (b.points.isEmpty) return 1;
    String key(LatLng p) =>
        '${p.latitude.toStringAsFixed(4)},${p.longitude.toStringAsFixed(4)}';
    final seen = a.points.map(key).toSet();
    final shared = b.points.where((p) => seen.contains(key(p))).length;
    return shared / b.points.length;
  }
}

/// Reads an OSRM response into a [NavRoute].
///
/// Pure and tolerant, so it can be tested against a captured response and so
/// a malformed reply degrades to "no route" rather than throwing.
NavRoute? parseOsrmRoute(String body) {
  try {
    final data = json.decode(body) as Map<String, dynamic>;
    if (data['code'] != 'Ok') return null;
    final routes = data['routes'] as List?;
    if (routes == null || routes.isEmpty) return null;

    final route = routes.first as Map<String, dynamic>;
    final coords =
        (route['geometry'] as Map<String, dynamic>?)?['coordinates'] as List?;
    if (coords == null || coords.length < 2) return null;

    final points = <LatLng>[];
    for (final c in coords) {
      if (c is! List || c.length < 2) continue;
      final lng = (c[0] as num?)?.toDouble();
      final lat = (c[1] as num?)?.toDouble();
      if (lat != null && lng != null) points.add(LatLng(lat, lng));
    }
    if (points.length < 2) return null;

    final steps = <NavStep>[];
    for (final leg in (route['legs'] as List? ?? const [])) {
      if (leg is! Map) continue;
      for (final step in (leg['steps'] as List? ?? const [])) {
        if (step is! Map) continue;
        final maneuver = step['maneuver'];
        steps.add(
          NavStep(
            road: (step['name'] as String?) ?? '',
            maneuver: maneuver is Map
                ? (maneuver['type'] as String? ?? '')
                : '',
            modifier: maneuver is Map
                ? maneuver['modifier'] as String?
                : null,
            distanceMeters: (step['distance'] as num?)?.toDouble() ?? 0,
          ),
        );
      }
    }

    return NavRoute(
      points: points,
      distanceMeters: (route['distance'] as num?)?.toDouble() ?? 0,
      durationSeconds: (route['duration'] as num?)?.toDouble() ?? 0,
      steps: steps,
    );
  } catch (e) {
    debugPrint('Could not read OSRM response: $e');
    return null;
  }
}

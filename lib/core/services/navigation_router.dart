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

import '../models/live_route.dart' show findLoop, throughPointAfter;
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
      final candidate = await _withoutLoop(
        from,
        to,
        await _request([from, waypoint, to]),
      );
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

  /// Complete routes from [from] to [to] on OpenStreetMap's road network,
  /// each taking a genuinely different way: OSRM's own direct route, plus
  /// routes pushed through points off to either side. Quickest first.
  ///
  /// Two jobs, both because TomTom's map is missing roads OSM has —
  /// barangay streets, which are exactly where tricycles drive:
  ///
  ///   * **Going round a blocked road.** With [avoid] given, only routes
  ///     keeping [clearanceMeters] from every point are returned. On the
  ///     Calantipay trip TomTom sent all three of its routes through a
  ///     confirmed accident and could not be made to avoid it.
  ///   * **Offering real alternatives.** TomTom's alternatives there all left
  ///     on the same road and split later — the main way again. Apple Maps
  ///     offered ways that differed from the start; so does this.
  ///
  /// The direct route used to be fetched only to calibrate times and then
  /// thrown away, and the first way round that cleared the accident was
  /// taken. OSRM's direct route went east — 6.6 km, 749 m clear of the
  /// accident, the way Apple sent its fastest — but the app sent the driver
  /// west, 7.3 km, because that was the first one tried. Now every side is
  /// tried, the direct route is a candidate like any other, and scoring
  /// picks the quickest.
  ///
  /// Requests run in parallel: the public OSRM server can take seconds each,
  /// and a driver waiting on a reroute should not wait for them in turn.
  Future<({NavRoute? direct, List<NavRoute> routes})> osmCorridors(
    LatLng from,
    LatLng to, {
    List<LatLng> avoid = const [],
    double clearanceMeters = kIncidentOnRouteMeters,
    int maxRoutes = 3,
  }) async {
    final direct = await _request([from, to]);
    if (direct == null) return (direct: null, routes: <NavRoute>[]);

    bool clearOfAll(NavRoute r) => avoid.every(
      (a) =>
          (nearestOnWay(r.points, a)?.distanceMeters ?? double.infinity) >
          clearanceMeters,
    );

    // Off either side of whatever is in the way — or of the midpoint, when
    // simply looking for other ways.
    final pivot = avoid.firstOrNull ?? _midpoint(from, to);
    final span = _degreesBetween(from, to);
    final pushed = await Future.wait([
      for (final offset in const [0.15, -0.15, 0.3, -0.3])
        _through(from, to, _perpendicularOffset(from, to, pivot, span * offset)),
    ]);

    final candidates = [direct, ...pushed.whereType<NavRoute>()]
      ..sort((a, b) => a.durationSeconds.compareTo(b.durationSeconds));

    final out = <NavRoute>[];
    for (final c in candidates) {
      if (out.length >= maxRoutes) break;
      // Twice the direct distance is a tour of the district, not a detour.
      if (c.distanceMeters > direct.distanceMeters * 2) continue;
      if (avoid.isNotEmpty && !clearOfAll(c)) continue;
      if (findLoop(c.points) != null) continue;
      if (out.any((r) => _overlapFraction(r, c) > 0.8)) continue;
      out.add(c);
    }
    return (direct: direct, routes: out);
  }

  /// A route pushed through [via], with any out-and-back removed.
  Future<NavRoute?> _through(LatLng from, LatLng to, LatLng via) async =>
      _withoutLoop(from, to, await _request([from, via, to]));

  /// [route] with any out-and-back removed — by asking again, not by
  /// editing the geometry.
  ///
  /// A route forced through a point can go up a dead-end side street to
  /// reach it and come straight back. Cutting the spur out of the line would
  /// leave turn instructions for a street no longer on it, so instead the
  /// router is asked for the same way round through a point on the road the
  /// route rejoins, which it can pass without the spur. Anything that still
  /// loops is dropped: a route that tells a driver to go up a street and
  /// back is not one to offer.
  Future<NavRoute?> _withoutLoop(LatLng from, LatLng to, NavRoute? route) async {
    if (route == null) return null;
    final loop = findLoop(route.points);
    if (loop == null) return route;

    final through = throughPointAfter(route.points, loop);
    if (through == null) return null;
    final retry = await _request([from, through, to]);
    if (retry == null || findLoop(retry.points) != null) return null;
    return retry;
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

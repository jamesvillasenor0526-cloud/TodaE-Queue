/// Routing via TomTom, when a key is configured.
///
/// This exists because the public OSRM server returns exactly one route —
/// confirmed against the live service — so alternatives had to be forced by
/// routing through an offset waypoint. That produces a real road, but one
/// picked by geometry rather than by a router weighing options, and it
/// sometimes offered detours no driver would take.
///
/// TomTom returns genuine alternatives (`maxAlternatives`, 0–5) and, more
/// importantly, real traffic: with `traffic=true` the travel times are
/// measured rather than free-flow, and `trafficDelayInSeconds` says how much
/// of the estimate is congestion. That is the live traffic feed this app has
/// never had.
///
/// The free tier allows 2,500 routing requests a day and needs no card. With
/// no key the app stays on OSRM — everything still works, just without
/// traffic or real alternatives.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../../config/api_keys.dart';
import '../models/navigation_state.dart';

class TomTomRouter {
  TomTomRouter._();
  static final TomTomRouter instance = TomTomRouter._();

  static const _host = 'api.tomtom.com';
  static const _timeout = Duration(seconds: 15);

  /// Whether a key has been configured. When false the app uses OSRM.
  static bool get isConfigured => ApiKeys.tomTom.trim().isNotEmpty;

  /// Routes from [from] to [to], best first.
  ///
  /// [avoid] marks places TomTom must route around, such as a closure or an
  /// accident a driver reported. Without it the app can only choose among
  /// the alternatives TomTom happened to offer, and when all of them pass
  /// through the same incident the driver is sent through it regardless.
  ///
  /// Returns an empty list on any failure so the caller can fall back to
  /// OSRM rather than leaving the driver without a route.
  Future<List<NavRoute>> route(
    LatLng from,
    LatLng to, {
    int maxAlternatives = 2,
    List<LatLng> avoid = const [],
  }) async {
    if (!isConfigured) return const [];

    final uri = Uri.https(
      _host,
      '/routing/1/calculateRoute/'
          '${from.latitude},${from.longitude}:'
          '${to.latitude},${to.longitude}/json',
      {
        'key': ApiKeys.tomTom,
        // 0–5. Asking for more than we will show wastes the daily quota.
        'maxAlternatives': '${maxAlternatives.clamp(0, 5)}',
        // The whole point: measured travel times, not free-flow.
        'traffic': 'true',
        'routeType': 'fastest',
        // Closest match for a tricycle — it shares a motorcycle's access to
        // narrow roads without being treated as a car on highways.
        'travelMode': 'motorcycle',
        'instructionsType': 'text',
      },
    );

    try {
      // Avoid areas are only accepted in a POST body; the query parameters
      // above apply to both. Verified against the live API over the Glorieta
      // Rotonda: the plain route had 22 points inside the box, the avoiding
      // one none, with guidance and alternatives intact.
      final response = avoid.isEmpty
          ? await http.get(uri).timeout(_timeout)
          : await http
                .post(
                  uri,
                  headers: const {'Content-Type': 'application/json'},
                  body: json.encode(avoidAreasBody(avoid)),
                )
                .timeout(_timeout);
      if (response.statusCode != 200) {
        // 403 usually means the key is wrong or over quota; either way the
        // driver should get an OSRM route rather than nothing.
        debugPrint('TomTom routing returned ${response.statusCode}');
        return const [];
      }
      return parseTomTomRoutes(response.body);
    } catch (e) {
      debugPrint('TomTom routing unavailable: $e');
      return const [];
    }
  }
}

/// Half the side of the square avoided around each reported incident.
///
/// A report is a point where a driver stood, not the extent of the problem.
/// 70 m either way covers the Glorieta Rotonda's whole ring — 187 m around —
/// and the approach to an ordinary junction, without closing off parallel
/// streets a detour would need.
const double kAvoidHalfMeters = 70;

/// The most areas sent in one request. More would make it likelier TomTom
/// finds no route at all, and a report beyond the tenth worst on one trip is
/// not going to change which road is best.
const int kMaxAvoidAreas = 10;

/// The POST body that asks TomTom to route around [points].
///
/// Pure, so the shape can be tested without the network: TomTom rejects a
/// malformed body outright, and the driver would silently fall back to a
/// route that goes straight through the incident.
Map<String, dynamic> avoidAreasBody(
  List<LatLng> points, {
  double halfMeters = kAvoidHalfMeters,
}) {
  const metresPerDegree = 111320.0;
  return {
    'avoidAreas': {
      'rectangles': [
        for (final p in points.take(kMaxAvoidAreas))
          () {
            final dLat = halfMeters / metresPerDegree;
            // A degree of longitude shrinks towards the poles; at Baliwag's
            // 15° it is still 97% of a degree of latitude, but computed
            // rather than assumed.
            final dLng =
                halfMeters /
                (metresPerDegree * math.cos(p.latitude * math.pi / 180));
            return {
              'southWestCorner': {
                'latitude': p.latitude - dLat,
                'longitude': p.longitude - dLng,
              },
              'northEastCorner': {
                'latitude': p.latitude + dLat,
                'longitude': p.longitude + dLng,
              },
            };
          }(),
      ],
    },
  };
}

/// Reads a TomTom Calculate Route response into [NavRoute]s.
///
/// Pure and tolerant: a malformed or partial reply yields fewer routes, never
/// an exception, because the driver falling back to OSRM is always better
/// than a crash mid-trip.
List<NavRoute> parseTomTomRoutes(String body) {
  try {
    final data = json.decode(body) as Map<String, dynamic>;
    final routes = data['routes'] as List?;
    if (routes == null || routes.isEmpty) return const [];

    final out = <NavRoute>[];
    for (final raw in routes) {
      if (raw is! Map) continue;

      final summary = raw['summary'];
      final points = <LatLng>[];
      final steps = <NavStep>[];

      for (final leg in (raw['legs'] as List? ?? const [])) {
        if (leg is! Map) continue;
        for (final p in (leg['points'] as List? ?? const [])) {
          if (p is! Map) continue;
          final lat = (p['latitude'] as num?)?.toDouble();
          final lng = (p['longitude'] as num?)?.toDouble();
          if (lat != null && lng != null) points.add(LatLng(lat, lng));
        }
      }
      if (points.length < 2) continue;

      // Guidance is optional; a route without it is still drivable.
      final guidance = raw['guidance'];
      if (guidance is Map) {
        final instructions = (guidance['instructions'] as List? ?? const [])
            .whereType<Map>()
            .toList();

        for (var n = 0; n < instructions.length; n++) {
          final i = instructions[n];

          // routeOffsetInMeters is the distance from the *start of the
          // route*, not the length of this step. Using it directly would
          // tell a driver "turn left in 1851 m" when the turn is 1851 m
          // from where the trip began and possibly right in front of them.
          // The gap to the next instruction is the distance actually
          // travelled on this one, which is what OSRM's steps mean too.
          final here = (i['routeOffsetInMeters'] as num?)?.toDouble() ?? 0;
          final next = n + 1 < instructions.length
              ? (instructions[n + 1]['routeOffsetInMeters'] as num?)
                    ?.toDouble()
              : null;

          steps.add(
            NavStep(
              road:
                  (i['street'] as String?) ??
                  (i['roadNumbers'] is List
                      ? ((i['roadNumbers'] as List).firstOrNull as String? ??
                            '')
                      : ''),
              maneuver: _maneuverFrom(i['maneuver'] as String?),
              modifier: _modifierFrom(i['maneuver'] as String?),
              distanceMeters: next == null ? 0 : (next - here).clamp(0, 1e9),
              // TomTom phrases these itself, and names roads we would
              // otherwise have to guess at.
              text: i['message'] as String?,
            ),
          );
        }
      }

      out.add(
        NavRoute(
          points: points,
          distanceMeters:
              (summary is Map ? summary['lengthInMeters'] as num? : null)
                  ?.toDouble() ??
              0,
          // Already traffic-aware, which is why routes from here must not
          // also carry this app's modelled traffic penalty.
          durationSeconds:
              (summary is Map ? summary['travelTimeInSeconds'] as num? : null)
                  ?.toDouble() ??
              0,
          trafficDelaySeconds:
              (summary is Map
                      ? summary['trafficDelayInSeconds'] as num?
                      : null)
                  ?.toDouble() ??
              0,
          steps: steps,
          source: 'tomtom',
        ),
      );
    }
    return out;
  } catch (e) {
    debugPrint('Could not read TomTom response: $e');
    return const [];
  }
}

/// Maps TomTom's manoeuvre vocabulary onto the one [NavStep] already uses,
/// so instructions read the same whichever router produced them.
String _maneuverFrom(String? m) {
  if (m == null) return '';
  if (m == 'DEPART') return 'depart';
  if (m == 'ARRIVE' || m.startsWith('ARRIVE_')) return 'arrive';
  if (m.contains('ROUNDABOUT')) return 'roundabout';
  if (m.startsWith('KEEP_')) return 'fork';
  if (m.startsWith('MERGE')) return 'merge';
  if (m.contains('STRAIGHT')) return 'continue';
  return 'turn';
}

String? _modifierFrom(String? m) {
  if (m == null) return null;
  if (m.contains('SHARP_LEFT')) return 'sharp left';
  if (m.contains('SHARP_RIGHT')) return 'sharp right';
  if (m.contains('SLIGHT_LEFT')) return 'slight left';
  if (m.contains('SLIGHT_RIGHT')) return 'slight right';
  if (m.contains('LEFT')) return 'left';
  if (m.contains('RIGHT')) return 'right';
  if (m.contains('UTURN')) return 'uturn';
  if (m.contains('STRAIGHT')) return 'straight';
  return null;
}

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

/// How long any single routing request may take before it is given up on.
///
/// These calls had no limit at all: on a slow connection the destination
/// picker sat on 'Calculating Route...' with no cancel and no error, for as
/// long as the socket stayed open. A caller that times out falls back to a
/// straight-line estimate, which is worse than a real route and far better
/// than a screen that never finishes.
const Duration kRoutingTimeout = Duration(seconds: 10);

class RoutingService {
  static final RoutingService instance = RoutingService._();
  RoutingService._();

  Future<List<LatLng>> getRoute(LatLng start, LatLng end) async {
    try {
      // Try driving first
      final drivingUrl =
          'https://router.project-osrm.org/route/v1/driving/'
          '${start.longitude},${start.latitude};'
          '${end.longitude},${end.latitude}'
          '?overview=full&geometries=geojson';

      final drivingResponse = await http
          .get(Uri.parse(drivingUrl))
          .timeout(kRoutingTimeout);

      if (drivingResponse.statusCode == 200) {
        final data = json.decode(drivingResponse.body);
        final routes = data['routes'] as List;
        if (routes.isNotEmpty) {
          final geometry = routes[0]['geometry']['coordinates'] as List;
          return geometry.map((coord) {
            final lat = (coord[1] as num).toDouble();
            final lng = (coord[0] as num).toDouble();
            return LatLng(lat, lng);
          }).toList();
        }
      }

      // Try walking profile (follows sidewalks, bridges)
      final walkingUrl =
          'https://router.project-osrm.org/route/v1/walking/'
          '${start.longitude},${start.latitude};'
          '${end.longitude},${end.latitude}'
          '?overview=full&geometries=geojson';

      final walkingResponse = await http
          .get(Uri.parse(walkingUrl))
          .timeout(kRoutingTimeout);

      if (walkingResponse.statusCode == 200) {
        final data = json.decode(walkingResponse.body);
        final routes = data['routes'] as List;
        if (routes.isNotEmpty) {
          final geometry = routes[0]['geometry']['coordinates'] as List;
          return geometry.map((coord) {
            final lat = (coord[1] as num).toDouble();
            final lng = (coord[0] as num).toDouble();
            return LatLng(lat, lng);
          }).toList();
        }
      }
    } catch (e) {
      debugPrint('OSRM routing error: $e');
    }
    return [start, end];
  }

  Future<double> getRouteDistance(LatLng start, LatLng end) async {
    // Try driving first
    try {
      final url =
          'https://router.project-osrm.org/route/v1/driving/'
          '${start.longitude},${start.latitude};'
          '${end.longitude},${end.latitude}'
          '?overview=false';

      final response = await http.get(Uri.parse(url)).timeout(kRoutingTimeout);

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final routes = data['routes'] as List;
        if (routes.isNotEmpty) {
          final distanceMeters = (routes[0]['distance'] as num).toDouble();
          final km = distanceMeters / 1000.0;
          debugPrint('Driving distance: $km km');
          return km;
        }
      }
    } catch (e) {
      debugPrint('Driving distance error: $e');
    }

    // Try walking profile
    try {
      final walkingUrl =
          'https://router.project-osrm.org/route/v1/walking/'
          '${start.longitude},${start.latitude};'
          '${end.longitude},${end.latitude}'
          '?overview=false';

      final response = await http
          .get(Uri.parse(walkingUrl))
          .timeout(kRoutingTimeout);

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final routes = data['routes'] as List;
        if (routes.isNotEmpty) {
          final distanceMeters = (routes[0]['distance'] as num).toDouble();
          final km = distanceMeters / 1000.0;
          debugPrint('Walking distance: $km km');
          return km;
        }
      }
    } catch (e) {
      debugPrint('Walking distance error: $e');
    }

    // No route: the straight line, allowed for the way streets wind. The
    // fare is worked out from this, and a straight line through the blocks
    // undercharges every ride the router could not reach.
    final straight = const Distance().as(LengthUnit.Kilometer, start, end);
    debugPrint('Fallback distance: $straight km (estimated from the line)');
    return straightLineRoadEstimate(straight);
  }

  /// As [getRouteDistance], and whether it is a measured road distance or an
  /// estimate, so the fare can be shown honestly.
  Future<({double km, bool measured})> roadDistance(
    LatLng start,
    LatLng end,
  ) async {
    final straight = const Distance().as(LengthUnit.Kilometer, start, end);
    final km = await getRouteDistance(start, end);
    // The fallback returns exactly the estimate; anything else came from the
    // router.
    final measured = (km - straightLineRoadEstimate(straight)).abs() > 0.0005;
    return (km: km, measured: measured);
  }
}

/// How much further a street route runs than the straight line between two
/// points, in a town laid out like Baliwag. Used only when the router cannot
/// be reached, so a fare is not worked out from a line through the blocks.
const double kStreetWindingFactor = 1.3;

double straightLineRoadEstimate(double straightLineKm) =>
    double.parse((straightLineKm * kStreetWindingFactor).toStringAsFixed(3));

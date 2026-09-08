import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

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

      final drivingResponse = await http.get(Uri.parse(drivingUrl));

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

      final walkingResponse = await http.get(Uri.parse(walkingUrl));

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

      final response = await http.get(Uri.parse(url));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final routes = data['routes'] as List;
        if (routes.isNotEmpty) {
          final distanceMeters = (routes[0]['distance'] as num).toDouble();
          final km = distanceMeters / 1000.0;
          debugPrint('🔍 Driving distance: $km km');
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

      final response = await http.get(Uri.parse(walkingUrl));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final routes = data['routes'] as List;
        if (routes.isNotEmpty) {
          final distanceMeters = (routes[0]['distance'] as num).toDouble();
          final km = distanceMeters / 1000.0;
          debugPrint('🔍 Walking distance: $km km');
          return km;
        }
      }
    } catch (e) {
      debugPrint('Walking distance error: $e');
    }

    // Fallback: Haversine distance (more accurate than simple straight line)
    final straight = const Distance().as(LengthUnit.Kilometer, start, end);
    debugPrint('⚠️ Fallback distance: $straight km');
    return straight;
  }
}

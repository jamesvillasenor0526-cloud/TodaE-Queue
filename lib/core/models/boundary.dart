/// Whether a point is inside a mapped outline, and how far outside it is.
///
/// Used for two different outlines: a terminal's boundary, which decides
/// whether a driver is still at their terminal, and the town's boundary,
/// which decides whether a trip leaves Baliwag.
library;

import 'package:latlong2/latlong.dart';

import 'traffic_segment.dart' show nearestOnWay;

/// How far [point] lies outside [boundary]; zero when inside it.
///
/// Measured to the boundary itself rather than its centre, so outlines of
/// any size and shape get the same margin.
double metersOutsideBoundary(LatLng point, List<LatLng> boundary) {
  if (boundary.length < 3) return 0; // no usable outline: never outside
  if (insideBoundary(point, boundary)) return 0;
  final ring = [...boundary, boundary.first];
  return nearestOnWay(ring, point)?.distanceMeters ?? 0;
}

/// Ray casting: whether [p] falls inside [polygon].
bool insideBoundary(LatLng p, List<LatLng> polygon) {
  if (polygon.length < 3) return false;
  var inside = false;
  for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
    final xi = polygon[i].longitude, yi = polygon[i].latitude;
    final xj = polygon[j].longitude, yj = polygon[j].latitude;
    final crosses =
        ((yi > p.latitude) != (yj > p.latitude)) &&
        (p.longitude < (xj - xi) * (p.latitude - yi) / (yj - yi) + xi);
    if (crosses) inside = !inside;
  }
  return inside;
}

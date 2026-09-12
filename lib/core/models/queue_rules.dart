/// When a driver's place in the queue is kept, and when it is lost.
///
/// Three rules, all of them about fairness at the terminal:
///
///   * A driver who leaves the terminal leaves the queue. Checking in used
///     to be the last time position was considered, so a driver could check
///     in, drive away, and still be sent the next passenger from a terminal
///     they were nowhere near.
///   * A passenger cancelling does not cost the driver their place: they
///     were waiting, and did nothing wrong. Their entry used to be
///     cancelled outright, sending them to the back of the queue.
///   * A driver who never answers does not hold a passenger indefinitely.
///     Nothing timed out a dispatch, so an ignored booking waited forever.
///
/// Pure, so the thresholds are tested without a device or a network.
library;

import 'package:latlong2/latlong.dart';

import 'traffic_segment.dart' show nearestOnWay;

/// How far outside the terminal's boundary counts as having left it.
///
/// Generous: GPS in town drifts, and a tricycle parked at the edge of a
/// terminal may read as just outside it.
const double kQueueExitMeters = 80;

/// Consecutive readings outside before the place is given up, so one stray
/// reading does not cost a driver their turn.
const int kQueueExitFixes = 3;

/// How long a dispatched driver has to accept before the passenger is
/// offered another driver.
const Duration kAcceptWindow = Duration(seconds: 90);

/// How far [point] lies outside [boundary]; zero when inside it.
///
/// Measured to the boundary itself rather than its centre, so terminals of
/// different sizes all get the same margin.
double metersOutsideBoundary(LatLng point, List<LatLng> boundary) {
  if (boundary.length < 3) return 0; // no usable boundary: never eject
  if (_inside(point, boundary)) return 0;
  final ring = [...boundary, boundary.first];
  return nearestOnWay(ring, point)?.distanceMeters ?? 0;
}

/// Whether a waiting driver has left the terminal for good.
bool leavesQueue({
  required double metersOutside,
  required int consecutiveOutside,
}) =>
    metersOutside > kQueueExitMeters && consecutiveOutside >= kQueueExitFixes;

/// Whether a dispatched driver has had long enough to answer.
bool waitedLongEnoughToReassign(Duration sinceDispatch) =>
    sinceDispatch >= kAcceptWindow;

/// Ray casting, the same test the geofence uses.
bool _inside(LatLng p, List<LatLng> polygon) {
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

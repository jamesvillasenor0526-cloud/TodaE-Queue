/// Where a vehicle should be *drawn* right now, which is not the same as
/// where it was last heard from.
///
/// Gliding between two readings (see glide.dart) is honest but always one
/// reading behind: the marker sets off for a position the vehicle has
/// already left, and arrives as the next reading does. On the passenger's
/// map, where the driver's position comes through the database every couple
/// of seconds, that is several seconds of lag and a visible stop-start.
///
/// Navigation apps do something else. They know the road the vehicle is on
/// and how fast it is going, so between readings they carry it forward
/// along that road at that speed, and correct when the next reading
/// arrives. The vehicle appears to move continuously because it is being
/// driven along the route rather than dragged between two dots — and it
/// follows the bends of the road instead of cutting across them.
///
/// That is what this does. Three rules keep it honest:
///
///   * it only carries a vehicle forward along a route it is actually on
///     (see [kOnRouteMeters]); off the route there is nothing to project
///     along, and the last known position is drawn as-is;
///   * it never carries it further than [kMaxCarryForward], so a phone that
///     stops reporting does not sail off down the road on its own;
///   * it never carries it past the end of the route.
///
/// Pure — no clock, no plugin — so all of it is tested without a device.
library;

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'live_route.dart';

/// The longest a vehicle is moved on from its last known position.
///
/// A few seconds covers the gap between readings — 1 s on the driver's own
/// phone, 2 s or so through the database for the passenger — and a little
/// late delivery. Beyond that the vehicle has genuinely stopped reporting
/// and inventing movement would be a lie: a tricycle at 30 km/h covers 40 m
/// in five seconds, which is a junction's worth of wrong.
const Duration kMaxCarryForward = Duration(seconds: 5);

/// Below this a vehicle is treated as stopped, in metres per second.
///
/// GPS speed jitters around a metre a second while stationary; projecting
/// that would have a parked tricycle creeping down the road.
const double kMovingAtLeast = 1.0;

/// The point [meters] along [points], with the bearing of the road there.
///
/// Before the start, the start; past the end, the end.
({LatLng at, double heading})? alongRoute(
  List<LatLng> points,
  double meters, {
  List<double>? cumulative,
}) {
  if (points.length < 2) return null;
  final cum = cumulative ?? cumulativeMeters(points);
  final total = cum.last;
  final target = meters.isFinite ? meters.clamp(0.0, total) : 0.0;

  for (var i = 0; i < points.length - 1; i++) {
    if (cum[i + 1] < target) continue;
    final segment = cum[i + 1] - cum[i];
    final t = segment <= 0 ? 0.0 : (target - cum[i]) / segment;
    return (
      at: lerpAlong(points[i], points[i + 1], t),
      heading: bearingDegrees(points[i], points[i + 1]),
    );
  }
  final last = points.length - 1;
  return (
    at: points[last],
    heading: bearingDegrees(points[last - 1], points[last]),
  );
}

/// Straight-line interpolation between two points a few metres apart.
LatLng lerpAlong(LatLng a, LatLng b, double t) {
  final k = t.clamp(0.0, 1.0);
  return LatLng(
    a.latitude + (b.latitude - a.latitude) * k,
    a.longitude + (b.longitude - a.longitude) * k,
  );
}

/// How quickly a correction is worked in, as a time constant rather than a
/// fraction per frame.
///
/// A fixed fraction per frame is smooth at sixty frames a second and
/// noticeably slower at thirty — the correction rate then depends on how
/// busy the phone is, which is exactly when it should not. Expressed as a
/// time constant, the same correction takes the same wall-clock time
/// whatever the frame rate: about this long to close two thirds of the gap.
const Duration kCatchUp = Duration(milliseconds: 220);

/// How much of the remaining gap to close after [since] has elapsed.
///
/// Exponential: fast at first, easing in as it arrives, and never
/// overshooting. A frame that took unusually long closes proportionally
/// more, so a stutter does not leave the marker trailing.
double catchUpFraction(Duration since, {Duration constant = kCatchUp}) {
  final ms = since.inMicroseconds / 1000.0;
  final tau = constant.inMicroseconds / 1000.0;
  if (ms <= 0 || tau <= 0) return 0;
  return (1 - math.exp(-ms / tau)).clamp(0.0, 1.0);
}

/// The route ahead of [at], beginning exactly at [at].
///
/// Trimming to what is ahead is not enough on its own: it starts the line
/// at the nearest point on the road, which is metres away from where the
/// vehicle is drawn, and at close zoom that gap reads as a broken line.
/// Joining the two makes the line start under the vehicle.
///
/// When the vehicle is off the route altogether, the join is the honest
/// picture rather than a cosmetic fix: here is you, there is the road you
/// are meant to be on.
List<LatLng> lineFromVehicle(List<LatLng> route, LatLng? at) =>
    trimmedFromVehicle(route, at).line;

/// As [lineFromVehicle], but reporting which segment the vehicle was found
/// on so the next frame can start looking there.
///
/// Without it every frame scans the whole route to find the vehicle — a few
/// hundred segments, sixty times a second, for a line that moved a metre.
/// The hint also keeps the answer stable where a route passes close to
/// itself: a loop round a block, or a U-turn at the start.
({List<LatLng> line, int? segment}) trimmedFromVehicle(
  List<LatLng> route,
  LatLng? at, {
  int? hint,
}) {
  if (at == null) return (line: route, segment: hint);
  final progress = progressAlong(route, at, hint: hint);
  final ahead = lineAhead(route, at, hint: hint);
  if (ahead.isEmpty) return (line: ahead, segment: progress?.segment);
  final gap = const Distance().as(LengthUnit.Meter, at, ahead.first);
  // Under a metre is the same point as far as any map is concerned, and
  // repeating it would draw a zero-length segment.
  return (line: gap < 1 ? ahead : [at, ...ahead], segment: progress?.segment);
}

/// Where to draw a vehicle [sinceFix] after its last known position.
///
/// With a route it is on, it is carried along that route at [speed].
/// Without one — off route, stopped, no route published yet — the last
/// known position is returned unchanged, because there is nothing to
/// project along and a guess would put it on the wrong road.
({LatLng at, double? heading}) carriedForward({
  required LatLng lastFix,
  required Duration sinceFix,
  double speed = 0,
  List<LatLng> route = const [],
  double? heading,
}) {
  final still = (at: lastFix, heading: heading);
  if (route.length < 2) return still;
  if (!speed.isFinite || speed < kMovingAtLeast) return still;
  if (sinceFix <= Duration.zero) return still;

  final progress = progressAlong(route, lastFix);
  if (progress == null || progress.offRouteMeters > kOnRouteMeters) {
    return still;
  }

  final carried = sinceFix > kMaxCarryForward ? kMaxCarryForward : sinceFix;
  final seconds =
      carried.inMilliseconds / Duration.millisecondsPerSecond.toDouble();
  final ahead = alongRoute(route, progress.travelledMeters + speed * seconds);
  if (ahead == null) return still;
  return (at: ahead.at, heading: ahead.heading);
}

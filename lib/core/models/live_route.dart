/// The moving-start-point geometry behind live navigation.
///
/// Everything here is pure: given a real route from the router and a real
/// GPS reading, it works out where the driver is along the road, what is
/// left to drive, how far the next turn is, which way to point the arrow,
/// and where a "2 min slower" label belongs. No plugin, no clock, no
/// network — so each rule is tested against routes TomTom actually
/// returned over Baliwag, walked point by point as a drive would be.
///
/// It exists because navigation used to measure everything from where the
/// route was last *fetched*. A route is fetched every 45 s, so for 45 s at
/// a time the line did not shorten, the next turn stayed "400 m" away while
/// the driver closed on it, and the start of the route sat behind them.
library;

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'navigation_state.dart';
import 'traffic_segment.dart' show nearestOnWay;

const double _earthRadius = 6371000;

/// Metres between consecutive points, as a running total. Element i is the
/// distance along the route from its start to [points] i.
List<double> cumulativeMeters(List<LatLng> points) {
  final out = List<double>.filled(points.length, 0);
  for (var i = 1; i < points.length; i++) {
    out[i] = out[i - 1] + _haversine(points[i - 1], points[i]);
  }
  return out;
}

/// Where a position sits along a route.
class RouteProgress {
  /// Index of the point that starts the segment the driver is on.
  final int segment;

  /// The driver's position moved onto the road line.
  final LatLng snapped;

  /// How far the GPS reading is from the road line.
  final double offRouteMeters;

  /// Distance along the route from its start to [snapped].
  final double travelledMeters;

  /// Length of the whole route.
  final double totalMeters;

  const RouteProgress({
    required this.segment,
    required this.snapped,
    required this.offRouteMeters,
    required this.travelledMeters,
    required this.totalMeters,
  });

  double get remainingMeters =>
      math.max(0, totalMeters - travelledMeters).toDouble();

  /// Share of the route still to drive, 0–1.
  double get remainingFraction =>
      totalMeters <= 0 ? 0 : (remainingMeters / totalMeters).clamp(0.0, 1.0);
}

/// How far back and forward of the last known segment to look first.
///
/// A route can pass close to itself — a U-turn at the start, a loop round a
/// block — and snapping a reading to the globally nearest segment would
/// then jump the driver forward or back along the route. Searching near
/// where they were keeps progress continuous; a reading nowhere near that
/// window falls back to the whole route.
const int _hintBehind = 3;
const int _hintAhead = 60;
const double _hintTrustMeters = 50;

/// Moves [position] onto [points] and measures the result.
///
/// [hint] is the segment from the previous reading, which keeps progress
/// continuous where the route passes near itself. [cumulative] may be
/// passed in to avoid recomputing it on every GPS reading.
RouteProgress? progressAlong(
  List<LatLng> points,
  LatLng position, {
  int? hint,
  List<double>? cumulative,
}) {
  if (points.length < 2) return null;
  final cum = cumulative ?? cumulativeMeters(points);

  _Projection? best;
  if (hint != null) {
    final from = math.max(0, hint - _hintBehind);
    final to = math.min(points.length - 2, hint + _hintAhead);
    best = _nearest(points, position, from, to);
    if (best != null && best.distance > _hintTrustMeters) best = null;
  }
  best ??= _nearest(points, position, 0, points.length - 2);
  if (best == null) return null;

  final i = best.segment;
  final segLength = cum[i + 1] - cum[i];
  return RouteProgress(
    segment: i,
    snapped: best.point,
    offRouteMeters: best.distance,
    travelledMeters: cum[i] + segLength * best.t,
    totalMeters: cum.last,
  );
}

/// The part of the route still ahead: from the driver's snapped position to
/// the destination. This is the line drawn, so it starts under the driver
/// and shortens as they go rather than trailing behind them.
List<LatLng> remainingLine(List<LatLng> points, RouteProgress p) => [
  p.snapped,
  ...points.sublist(math.min(p.segment + 1, points.length)),
];

/// How far from a route a position may be and still be considered on it,
/// for the purpose of drawing the line ahead.
///
/// Generous: this only decides whether the line is trimmed, and a driver on
/// a service road beside the highway should still see the road shorten in
/// front of them.
const double kOnRouteMeters = 150;

/// The part of [points] still ahead of [position] — the line as it should
/// be drawn on any map following a trip.
///
/// A route is fetched once and then only occasionally refetched, so drawing
/// it whole leaves a line that never moves while the driver does: the
/// marker slides along a line that keeps its tail behind them the whole
/// way. Trimmed here, the line starts under the vehicle and shortens as it
/// goes, on every map, without asking the router for anything.
///
/// A position that is nowhere near the route — more than [kOnRouteMeters]
/// away — leaves it whole. Snapping something that far off would draw a
/// line from a place the driver is not.
List<LatLng> lineAhead(List<LatLng> points, LatLng? position) {
  if (position == null || points.length < 2) return points;
  final progress = progressAlong(points, position);
  if (progress == null || progress.offRouteMeters > kOnRouteMeters) {
    return points;
  }
  return remainingLine(points, progress);
}

/// [route] from the driver's position onwards, as if fetched from there.
///
/// For reusing a route found a minute or two ago without asking for it
/// again. Its time, distance, line and turn list all start from [p], so it
/// compares fairly with a route fetched from here just now — otherwise a
/// cached alternative would carry the road already driven, and its "2 min
/// slower" would be overstated by however long the driver had been going.
/// Time is scaled by distance left, which is the same assumption the ETA
/// makes.
NavRoute trimRouteTo(NavRoute route, RouteProgress p) {
  final steps = route.steps;
  final stepsTotal = steps.fold(0.0, (s, st) => s + st.distanceMeters);
  final scale = (stepsTotal > 0 && p.totalMeters > 0)
      ? p.totalMeters / stepsTotal
      : 1.0;

  final kept = <NavStep>[];
  var offset = 0.0;
  for (final step in steps) {
    final start = offset * scale;
    final end = (offset + step.distanceMeters) * scale;
    offset += step.distanceMeters;
    if (end <= p.travelledMeters) continue; // wholly behind the driver
    if (start < p.travelledMeters) {
      // The step the driver is part-way along: its manoeuvre is behind them,
      // so it becomes the new start, with only the distance still to run.
      kept.add(
        NavStep(
          road: step.road,
          maneuver: 'depart',
          distanceMeters: (end - p.travelledMeters) / scale,
        ),
      );
    } else {
      kept.add(step);
    }
  }

  return NavRoute(
    points: remainingLine(route.points, p),
    distanceMeters: p.remainingMeters,
    durationSeconds: route.durationSeconds * p.remainingFraction,
    steps: kept,
    source: route.source,
    trafficDelaySeconds: route.trafficDelaySeconds * p.remainingFraction,
  );
}

/// Compass bearing from [a] to [b], 0 = north, clockwise, in degrees.
double bearingDegrees(LatLng a, LatLng b) {
  final lat1 = a.latitude * math.pi / 180;
  final lat2 = b.latitude * math.pi / 180;
  final dLng = (b.longitude - a.longitude) * math.pi / 180;
  final y = math.sin(dLng) * math.cos(lat2);
  final x =
      math.cos(lat1) * math.sin(lat2) -
      math.sin(lat1) * math.cos(lat2) * math.cos(dLng);
  return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
}

/// The direction the road runs where the driver is.
double routeBearingAt(List<LatLng> points, RouteProgress p) {
  final i = math.min(p.segment, points.length - 2);
  return bearingDegrees(points[i], points[i + 1]);
}

/// Within this of the road, the arrow is drawn on the road.
///
/// Urban GPS wanders tens of metres, and an arrow drifting beside the line
/// — or on the wrong side of a building — reads as the driver being lost
/// when they are not. Every navigation app matches the arrow to the road
/// when it is this close; further out it shows where the GPS actually is,
/// because then the driver may really have left the route.
const double kSnapToRoadMeters = 30;

/// Where to draw the driver: on the road when close enough to it, at the
/// GPS reading otherwise.
LatLng displayPosition(LatLng gps, RouteProgress? progress) =>
    (progress != null && progress.offRouteMeters <= kSnapToRoadMeters)
    ? progress.snapped
    : gps;

/// Below this, a phone's GPS heading is noise — a stationary phone reports
/// headings that swing through every direction.
const double kMinSpeedForGpsHeading = 1.5; // m/s, about 5 km/h

/// Which way to point the driver's arrow.
///
/// GPS heading when moving fast enough for it to mean something; otherwise
/// the direction of the road they are on, which is what a driver stopped at
/// a light expects to see; otherwise whatever it was last.
double displayHeading({
  required double? gpsHeading,
  required double speedMetersPerSecond,
  required double? roadBearing,
  double previous = 0,
}) {
  if (gpsHeading != null &&
      gpsHeading >= 0 &&
      speedMetersPerSecond >= kMinSpeedForGpsHeading) {
    return gpsHeading % 360;
  }
  return roadBearing ?? previous;
}

/// The shortest turn from [from] to [to], in degrees, -180 to 180. Used to
/// animate the arrow the short way round rather than spinning through 350°.
double shortestTurn(double from, double to) {
  final d = (to - from) % 360;
  return d > 180 ? d - 360 : (d < -180 ? d + 360 : d);
}

/// How far past a turn the driver can be before the next one takes over.
///
/// GPS lags and the snapped position trails the true one slightly; flipping
/// the instant the distance reaches zero would drop "turn left" while the
/// driver is still in the middle of turning.
const double kTurnPassedMeters = 12;

/// The next manoeuvre from where the driver is now, with the live distance
/// to it.
///
/// Router step distances and the drawn geometry are measured differently
/// and can disagree by a few percent, so the steps are scaled to the
/// geometry's length before being compared with [travelledMeters].
UpcomingTurn? upcomingAt(
  NavRoute route,
  double travelledMeters, {
  double? geometryMeters,
}) {
  final steps = route.steps;
  if (steps.isEmpty) return null;
  final stepsTotal = steps.fold(0.0, (s, st) => s + st.distanceMeters);
  final length = geometryMeters ?? cumulativeMeters(route.points).last;
  final scale = (stepsTotal > 0 && length > 0) ? length / stepsTotal : 1.0;

  var offset = 0.0;
  for (final step in steps) {
    if (step.maneuver != 'depart' &&
        offset * scale > travelledMeters - kTurnPassedMeters) {
      return UpcomingTurn(
        step: step,
        metersAway: math.max(0, offset * scale - travelledMeters).toDouble(),
      );
    }
    offset += step.distanceMeters;
  }
  return null;
}

/// Where along [alternative] to put its "2 min slower" label.
///
/// On the alternative's own road, not a stretch it shares with [main]:
/// a label on the shared road would sit on top of the fastest route and say
/// nothing about which line it belongs to. Takes the middle of the longest
/// stretch that runs at least [minSeparation] metres from [main]. Returns
/// null when the two never separate by that much, in which case there is no
/// honest place for the label.
///
/// [others] are the other alternatives. Two alternatives often share a road
/// for most of their length — Apple's two on the same trip both ran down
/// NIA Road — and labels placed only by distance from [main] land on that
/// shared road, one on top of the other. So the stretch where this route is
/// apart from *every* other line is preferred, and only if there is none is
/// the label placed by [main] alone.
LatLng? labelAnchor(
  List<LatLng> alternative,
  List<LatLng> main, {
  double minSeparation = 40,
  List<List<LatLng>> others = const [],
}) {
  if (alternative.length < 2 || main.length < 2) return null;
  if (others.isNotEmpty) {
    final alone = _longestApart(alternative, [main, ...others], minSeparation);
    if (alone != null) return alone;
  }
  return _longestApart(alternative, [main], minSeparation);
}

/// The middle of the longest stretch of [line] at least [minSeparation]
/// from every line in [from].
LatLng? _longestApart(
  List<LatLng> line,
  List<List<LatLng>> from,
  double minSeparation,
) {
  final alternative = line;
  // Runs of consecutive points that are apart from all of [from].
  var bestStart = -1, bestEnd = -1;
  var bestLength = 0.0;
  var runStart = -1;
  var runLength = 0.0;
  for (var i = 0; i < alternative.length; i++) {
    final apart = from.every(
      (other) =>
          (other.length < 2
              ? double.infinity
              : (nearestOnWay(other, alternative[i])?.distanceMeters ?? 0)) >=
          minSeparation,
    );
    if (apart) {
      if (runStart < 0) {
        runStart = i;
        runLength = 0;
      } else {
        runLength += _haversine(alternative[i - 1], alternative[i]);
      }
      if (runLength > bestLength || bestStart < 0) {
        bestStart = runStart;
        bestEnd = i;
        bestLength = runLength;
      }
    } else {
      runStart = -1;
    }
  }
  if (bestStart < 0) return null;

  // The point halfway along that run, by distance.
  final half = bestLength / 2;
  var walked = 0.0;
  for (var i = bestStart + 1; i <= bestEnd; i++) {
    final step = _haversine(alternative[i - 1], alternative[i]);
    if (walked + step >= half) {
      final t = step == 0 ? 0.0 : (half - walked) / step;
      final a = alternative[i - 1], b = alternative[i];
      return LatLng(
        a.latitude + (b.latitude - a.latitude) * t,
        a.longitude + (b.longitude - a.longitude) * t,
      );
    }
    walked += step;
  }
  return alternative[bestStart];
}

/// "2 min slower", "3 min faster", "Similar time" — how an alternative
/// compares with the route being driven.
///
/// Compared with the *active* route, not always the fastest: a driver who
/// chose the longer way should see the others as faster, which is what
/// they are. A time that is partly this app's estimate is marked "≈".
String timeDifferenceLabel({
  required double alternativeSeconds,
  required double activeSeconds,
  bool estimate = false,
}) {
  final diff = alternativeSeconds - activeSeconds;
  final minutes = (diff.abs() / 60).round();
  if (minutes == 0) return 'Similar time';
  final prefix = estimate ? '≈' : '';
  return '$prefix$minutes min ${diff > 0 ? 'slower' : 'faster'}';
}

/// A stretch where a route leaves a spot and comes back to it.
class RouteLoop {
  /// Index of the point where the route leaves.
  final int start;

  /// Index of the point where it is back.
  final int end;

  /// Distance driven between the two, for nothing.
  final double wastedMeters;

  const RouteLoop({
    required this.start,
    required this.end,
    required this.wastedMeters,
  });
}

/// A route that returns within [closeMeters] of where it already was after
/// driving at least [minLoopMeters] — an out-and-back no router chooses on
/// its own, because skipping it is always shorter.
///
/// Forcing OSRM round an incident through a chosen point produces these: it
/// must pass the point, and when the nearest road to it is a dead-end side
/// street, the route goes up it and back. Found on a live trip: 141 m up a
/// side street and back, 310 m for nothing, about 900 m into the way round
/// a confirmed accident.
RouteLoop? findLoop(
  List<LatLng> points, {
  double minLoopMeters = 150,
  double closeMeters = 25,
}) {
  if (points.length < 3) return null;
  final cum = cumulativeMeters(points);
  for (var j = 1; j < points.length; j++) {
    for (var i = 0; i < j; i++) {
      if (cum[j] - cum[i] < minLoopMeters) break;
      if (_haversine(points[i], points[j]) <= closeMeters) {
        // An out-and-back pairs up all along its length — each point going
        // out sits beside one coming back — so the first pair found is
        // somewhere along it, not at its base. Unzip outwards to the spot
        // where the route actually left and rejoined.
        var start = i, end = j;
        while (start > 0 &&
            end + 1 < points.length &&
            _haversine(points[start - 1], points[end + 1]) <= closeMeters) {
          start--;
          end++;
        }
        return RouteLoop(
          start: start,
          end: end,
          wastedMeters: cum[end] - cum[start],
        );
      }
    }
  }
  return null;
}

/// A point on the genuine road just past [loop], for asking the router to
/// go the same way round without the out-and-back.
///
/// The loop exists only to reach the point the route was forced through, so
/// a point further along the road it rejoins keeps the route in the same
/// corridor — round the incident — while giving the router no reason to
/// detour up the side street.
LatLng? throughPointAfter(
  List<LatLng> points,
  RouteLoop loop, {
  double beyondMeters = 80,
}) {
  final cum = cumulativeMeters(points);
  for (var k = loop.end + 1; k < points.length; k++) {
    if (cum[k] - cum[loop.end] >= beyondMeters) return points[k];
  }
  return null;
}

class _Projection {
  final int segment;
  final double t;
  final LatLng point;
  final double distance;
  const _Projection(this.segment, this.t, this.point, this.distance);
}

/// Nearest point on segments [from]..[to] of [points] to [p].
///
/// Projects in a local flat frame centred on [p] — at the scale of a road
/// segment the curvature of the earth is far below GPS error.
_Projection? _nearest(List<LatLng> points, LatLng p, int from, int to) {
  if (from > to) return null;
  final cosLat = math.cos(p.latitude * math.pi / 180);
  double x(LatLng q) =>
      (q.longitude - p.longitude) * math.pi / 180 * _earthRadius * cosLat;
  double y(LatLng q) =>
      (q.latitude - p.latitude) * math.pi / 180 * _earthRadius;

  _Projection? best;
  for (var i = from; i <= to; i++) {
    final a = points[i], b = points[i + 1];
    final ax = x(a), ay = y(a), bx = x(b), by = y(b);
    final dx = bx - ax, dy = by - ay;
    final len2 = dx * dx + dy * dy;
    // The driver is the origin, so the projection is of (0,0) onto a→b.
    var t = len2 == 0 ? 0.0 : (-(ax * dx) - (ay * dy)) / len2;
    t = t.clamp(0.0, 1.0);
    final px = ax + dx * t, py = ay + dy * t;
    final d = math.sqrt(px * px + py * py);
    if (best == null || d < best.distance) {
      best = _Projection(
        i,
        t,
        LatLng(
          a.latitude + (b.latitude - a.latitude) * t,
          a.longitude + (b.longitude - a.longitude) * t,
        ),
        d,
      );
    }
  }
  return best;
}

double _haversine(LatLng a, LatLng b) {
  final dLat = (b.latitude - a.latitude) * math.pi / 180;
  final dLng = (b.longitude - a.longitude) * math.pi / 180;
  final lat1 = a.latitude * math.pi / 180, lat2 = b.latitude * math.pi / 180;
  final h =
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1) * math.cos(lat2) * math.sin(dLng / 2) * math.sin(dLng / 2);
  return 2 * _earthRadius * math.asin(math.sqrt(h));
}

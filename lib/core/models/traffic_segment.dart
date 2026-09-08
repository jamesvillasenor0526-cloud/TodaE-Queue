/// Painting traffic along the roads themselves rather than as blobs over
/// them, the way a navigation app does.
///
/// The geometry here is pure so it can be tested without a network: fetching
/// the road shapes is [RoadGeometryService]'s job, turning them into a
/// coloured line is this file's.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import 'road_report.dart';

/// One road's shape, as returned by OpenStreetMap.
class RoadWay {
  final int id;
  final String? name;
  final List<LatLng> points;

  const RoadWay({required this.id, required this.points, this.name});
}

/// A stretch of road shaded with a traffic colour.
class TrafficSegment {
  /// The road's shape, clipped to the affected stretch.
  final List<LatLng> points;

  /// 0 (clear) to 1 (impassable).
  final double severity;

  /// Road name, when OpenStreetMap has one.
  final String? roadName;

  /// The reports this stretch was derived from.
  final List<RoadReport> reports;

  const TrafficSegment({
    required this.points,
    required this.severity,
    required this.reports,
    this.roadName,
  });

  Color get color => severityColor(severity);

  String get label => severityLabel(severity);

  /// Bad traffic is drawn heavier, so severity reads from the stroke as well
  /// as the colour — it stays legible for anyone who struggles with the
  /// red/green distinction.
  double get strokeWidth => 6 + 4 * severity.clamp(0.0, 1.0);
}

/// Metres per degree of latitude. Longitude is scaled by cos(latitude).
const double _metersPerDegLat = 111320;

/// Local flat-earth projection, accurate enough over the few hundred metres
/// these calculations span and far cheaper than proper geodesics.
({double x, double y}) _project(LatLng p, double refLat) => (
  x: p.longitude * _metersPerDegLat * math.cos(refLat * math.pi / 180),
  y: p.latitude * _metersPerDegLat,
);

LatLng _unproject(double x, double y, double refLat) => LatLng(
  y / _metersPerDegLat,
  x / (_metersPerDegLat * math.cos(refLat * math.pi / 180)),
);

double _metersBetween(LatLng a, LatLng b, double refLat) {
  final pa = _project(a, refLat);
  final pb = _project(b, refLat);
  return math.sqrt(
    math.pow(pa.x - pb.x, 2).toDouble() + math.pow(pa.y - pb.y, 2).toDouble(),
  );
}

/// Where [target] falls on [way]: how far off it is in metres, which segment
/// it lands on, and the point projected onto the line.
///
/// Returns null for a way with fewer than two points, which OSM occasionally
/// yields for a clipped query.
({double distanceMeters, int index, double t, LatLng point})? nearestOnWay(
  List<LatLng> way,
  LatLng target,
) {
  if (way.length < 2) return null;
  final refLat = target.latitude;
  final p = _project(target, refLat);

  var bestDistance = double.infinity;
  var bestIndex = 0;
  var bestT = 0.0;
  LatLng? bestPoint;

  for (var i = 0; i < way.length - 1; i++) {
    final a = _project(way[i], refLat);
    final b = _project(way[i + 1], refLat);
    final dx = b.x - a.x;
    final dy = b.y - a.y;
    final lengthSquared = dx * dx + dy * dy;

    // A zero-length segment (duplicated node) would divide by zero; treat it
    // as the vertex itself.
    var t = 0.0;
    if (lengthSquared > 0) {
      t = (((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared).clamp(
        0.0,
        1.0,
      );
    }
    final projX = a.x + t * dx;
    final projY = a.y + t * dy;
    final distance = math.sqrt(
      math.pow(p.x - projX, 2).toDouble() + math.pow(p.y - projY, 2).toDouble(),
    );

    if (distance < bestDistance) {
      bestDistance = distance;
      bestIndex = i;
      bestT = t;
      bestPoint = _unproject(projX, projY, refLat);
    }
  }

  if (bestPoint == null) return null;
  return (
    distanceMeters: bestDistance,
    index: bestIndex,
    t: bestT,
    point: bestPoint,
  );
}

/// The stretch of [way] reaching [halfLengthMeters] either side of [at].
///
/// Returns an empty list when [at] is nowhere near the way, so a caller can
/// fall back to zone shading rather than drawing a line down the wrong road.
List<LatLng> clipWayAround(
  List<LatLng> way,
  LatLng at,
  double halfLengthMeters, {
  double maxOffsetMeters = 60,
}) {
  final hit = nearestOnWay(way, at);
  if (hit == null || hit.distanceMeters > maxOffsetMeters) return const [];

  final refLat = at.latitude;
  final anchor = hit.point;

  // Walk backwards from the anchor, then forwards, stopping once each
  // direction has covered the requested distance.
  final before = <LatLng>[];
  var travelled = _metersBetween(anchor, way[hit.index], refLat);
  var i = hit.index;
  before.add(way[i]);
  while (travelled < halfLengthMeters && i > 0) {
    travelled += _metersBetween(way[i], way[i - 1], refLat);
    i--;
    before.add(way[i]);
  }

  final after = <LatLng>[];
  travelled = _metersBetween(anchor, way[hit.index + 1], refLat);
  var j = hit.index + 1;
  after.add(way[j]);
  while (travelled < halfLengthMeters && j < way.length - 1) {
    travelled += _metersBetween(way[j], way[j + 1], refLat);
    j++;
    after.add(way[j]);
  }

  return [...before.reversed, anchor, ...after];
}

/// Reads road shapes out of an Overpass API response.
///
/// Tolerant by design: a malformed or partial response yields fewer roads,
/// never an exception, because the overlay must survive whatever a public
/// community endpoint hands back.
List<RoadWay> parseOverpassWays(String body) {
  try {
    final data = json.decode(body) as Map<String, dynamic>;
    final elements = data['elements'] as List? ?? const [];
    final ways = <RoadWay>[];

    for (final element in elements) {
      if (element is! Map) continue;
      if (element['type'] != 'way') continue;
      final geometry = element['geometry'] as List?;
      if (geometry == null || geometry.length < 2) continue;

      final points = <LatLng>[];
      for (final node in geometry) {
        if (node is! Map) continue;
        final lat = (node['lat'] as num?)?.toDouble();
        final lon = (node['lon'] as num?)?.toDouble();
        if (lat != null && lon != null) points.add(LatLng(lat, lon));
      }
      if (points.length < 2) continue;

      ways.add(
        RoadWay(
          id: (element['id'] as num?)?.toInt() ?? 0,
          name: (element['tags'] as Map?)?['name'] as String?,
          points: points,
        ),
      );
    }
    return ways;
  } catch (_) {
    return const [];
  }
}

/// Whether two nodes are the same point on the ground.
///
/// OpenStreetMap ways that meet share an exact node, so this only has to
/// absorb floating-point noise, not real distance.
bool _sameNode(LatLng a, LatLng b) =>
    (a.latitude - b.latitude).abs() < 1e-6 &&
    (a.longitude - b.longitude).abs() < 1e-6;

/// Joins road fragments back into continuous roads.
///
/// OpenStreetMap splits a single street into many short ways wherever its
/// tags change or another road meets it — around Baliwag's rotonda a road
/// can arrive as half a dozen pieces of three or four nodes each. Painting
/// those directly gives stubs of colour instead of a coloured street, so
/// same-named fragments that share an endpoint are chained together first.
///
/// Unnamed ways are left alone: without a name there is nothing to say two
/// touching fragments are the same road rather than a junction.
List<RoadWay> mergeConnectedWays(Iterable<RoadWay> ways) {
  final byName = <String, List<RoadWay>>{};
  final loose = <RoadWay>[];

  for (final way in ways) {
    final name = way.name;
    if (name == null || name.isEmpty) {
      loose.add(way);
    } else {
      byName.putIfAbsent(name, () => []).add(way);
    }
  }

  final merged = <RoadWay>[...loose];
  for (final entry in byName.entries) {
    final pending = [...entry.value];
    while (pending.isNotEmpty) {
      final seed = pending.removeAt(0);
      final points = [...seed.points];

      // Extend from both ends until nothing else connects.
      var extended = true;
      while (extended) {
        extended = false;
        for (var i = 0; i < pending.length; i++) {
          final candidate = pending[i].points;
          if (_sameNode(points.last, candidate.first)) {
            points.addAll(candidate.skip(1));
          } else if (_sameNode(points.last, candidate.last)) {
            points.addAll(candidate.reversed.skip(1));
          } else if (_sameNode(points.first, candidate.last)) {
            points.insertAll(0, candidate.take(candidate.length - 1));
          } else if (_sameNode(points.first, candidate.first)) {
            points.insertAll(0, candidate.reversed.take(candidate.length - 1));
          } else {
            continue;
          }
          pending.removeAt(i);
          extended = true;
          break;
        }
      }

      merged.add(RoadWay(id: seed.id, name: entry.key, points: points));
    }
  }
  return merged;
}

/// Total length of a polyline in metres.
double wayLengthMeters(List<LatLng> points) {
  if (points.length < 2) return 0;
  final refLat = points.first.latitude;
  var total = 0.0;
  for (var i = 0; i < points.length - 1; i++) {
    total += _metersBetween(points[i], points[i + 1], refLat);
  }
  return total;
}

/// Added to an unnamed way's score, in metres. Nameless fragments are
/// usually slip roads and junction connectors rather than the street someone
/// means when they report traffic.
const double unnamedWayPenaltyMeters = 30;

/// Ways shorter than this are treated as fragments and scored down in
/// proportion to how far short they fall.
const double substantialWayMeters = 120;

/// Picks the road a report most likely refers to, out of everything nearby.
///
/// Not simply the nearest centreline. Junctions — exactly where congestion
/// gets reported — are dense with tiny unnamed connector ways, and on real
/// OpenStreetMap data around Baliwag's rotonda the closest way to the middle
/// of the junction is a 76 m unnamed stub. Painting that says nothing useful
/// to another driver, whereas the street it hangs off says everything.
///
/// So candidates are scored on offset plus a penalty for being nameless or
/// short. [maxOffsetMeters] still applies as a hard limit on the raw
/// distance, so this never reaches for a road that isn't really there.
RoadWay? bestWayFor(
  Iterable<RoadWay> ways,
  LatLng at, {
  double maxOffsetMeters = 60,
}) {
  RoadWay? best;
  var bestScore = double.infinity;

  for (final way in ways) {
    final hit = nearestOnWay(way.points, at);
    if (hit == null || hit.distanceMeters > maxOffsetMeters) continue;

    var score = hit.distanceMeters;
    if (way.name == null || way.name!.isEmpty) {
      score += unnamedWayPenaltyMeters;
    }
    final length = wayLengthMeters(way.points);
    if (length < substantialWayMeters) {
      score += (substantialWayMeters - length) * 0.25;
    }

    if (score < bestScore) {
      bestScore = score;
      best = way;
    }
  }
  return best;
}

/// Turns congestion zones into coloured road segments.
///
/// Zones with no road under them come back in [unplaced] for the caller to
/// shade as areas instead — better a soft blob in roughly the right place
/// than a confident red line down a road nobody reported. That is also the
/// state before the road shapes have finished loading, when [ways] is empty
/// and every zone is unplaced.
({List<TrafficSegment> segments, List<CongestionZone> unplaced})
buildTrafficSegments(
  List<CongestionZone> zones,
  Iterable<RoadWay> ways,
) {
  final segments = <TrafficSegment>[];
  final unplaced = <CongestionZone>[];

  for (final zone in zones) {
    final way = bestWayFor(ways, zone.center);
    final points = way == null
        ? const <LatLng>[]
        : clipWayAround(way.points, zone.center, zone.radiusMeters);

    if (points.length < 2) {
      unplaced.add(zone);
      continue;
    }
    segments.add(
      TrafficSegment(
        points: points,
        severity: zone.severity,
        roadName: way!.name,
        reports: zone.reports,
      ),
    );
  }
  return (segments: segments, unplaced: unplaced);
}

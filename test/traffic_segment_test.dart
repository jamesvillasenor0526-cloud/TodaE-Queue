import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:toda_equeue_plus/core/models/road_report.dart';
import 'package:toda_equeue_plus/core/models/traffic_segment.dart';

/// A straight east–west road through Baliwag, roughly 1.1 km long with a
/// node every ~110 m.
RoadWay _straightRoad({String? name = 'Test Road'}) => RoadWay(
  id: 1,
  name: name,
  points: [
    for (var i = 0; i <= 10; i++) LatLng(14.9540, 120.9010 + i * 0.001),
  ],
);

const _onRoad = LatLng(14.9540, 120.9060); // midway along it
const _offRoad = LatLng(14.9700, 120.9060); // ~1.8 km north

RoadReport _report({
  String id = 'r1',
  ReportType type = ReportType.trafficHeavy,
  LatLng at = _onRoad,
}) => RoadReport(
  id: id,
  type: type,
  location: at,
  reportedBy: 'uid',
  reporterName: 'Test',
  reporterRole: 'driver',
  expiresAt: DateTime(2026, 9, 8, 13),
  createdAt: DateTime(2026, 9, 8, 12),
);

CongestionZone _zone({
  LatLng center = _onRoad,
  double severity = 1,
  double radiusMeters = 200,
}) => CongestionZone(
  center: center,
  severity: severity,
  radiusMeters: radiusMeters,
  reports: [_report(at: center)],
);

/// Total length of a polyline in metres.
double _lengthMeters(List<LatLng> points) {
  const d = Distance();
  var total = 0.0;
  for (var i = 0; i < points.length - 1; i++) {
    total += d.as(LengthUnit.Meter, points[i], points[i + 1]);
  }
  return total;
}

void main() {
  group('nearestOnWay', () {
    test('a point on the road reports essentially no offset', () {
      final hit = nearestOnWay(_straightRoad().points, _onRoad)!;
      expect(hit.distanceMeters, lessThan(1));
    });

    test('a point beside the road reports the perpendicular offset', () {
      // ~55 m north of the centreline.
      final beside = LatLng(_onRoad.latitude + 0.0005, _onRoad.longitude);
      final hit = nearestOnWay(_straightRoad().points, beside)!;
      expect(hit.distanceMeters, closeTo(55, 8));
    });

    test('a far-off point reports a large offset', () {
      final hit = nearestOnWay(_straightRoad().points, _offRoad)!;
      expect(hit.distanceMeters, greaterThan(1000));
    });

    test('the projected point lands on the line, not on a vertex', () {
      // Deliberately between two nodes.
      final between = LatLng(14.9540, 120.90655);
      final hit = nearestOnWay(_straightRoad().points, between)!;
      expect(hit.point.longitude, closeTo(120.90655, 1e-4));
    });

    test('a way with too few points yields nothing', () {
      expect(nearestOnWay(const [], _onRoad), isNull);
      expect(nearestOnWay(const [LatLng(14.954, 120.901)], _onRoad), isNull);
    });

    test('a duplicated node does not blow up the projection', () {
      const p = LatLng(14.9540, 120.9010);
      final hit = nearestOnWay(const [p, p, LatLng(14.9540, 120.9020)], p);
      expect(hit, isNotNull);
      expect(hit!.distanceMeters, lessThan(1));
    });
  });

  group('clipWayAround', () {
    test('clips to roughly the requested length either side', () {
      final clipped = clipWayAround(_straightRoad().points, _onRoad, 200);
      expect(clipped.length, greaterThan(2));
      // 200 m each way, plus up to a node's spacing of overshoot per side.
      expect(_lengthMeters(clipped), inInclusiveRange(400, 640));
    });

    test('a longer request returns a longer stretch', () {
      final short = clipWayAround(_straightRoad().points, _onRoad, 150);
      final long = clipWayAround(_straightRoad().points, _onRoad, 450);
      expect(_lengthMeters(long), greaterThan(_lengthMeters(short)));
    });

    test('does not run past the end of the road', () {
      final road = _straightRoad();
      final clipped = clipWayAround(road.points, road.points.first, 5000);
      expect(_lengthMeters(clipped), lessThan(_lengthMeters(road.points) + 1));
    });

    test('refuses a point that is not near the road', () {
      expect(clipWayAround(_straightRoad().points, _offRoad, 200), isEmpty);
    });

    test('respects a tightened offset limit', () {
      final beside = LatLng(_onRoad.latitude + 0.0005, _onRoad.longitude);
      expect(
        clipWayAround(_straightRoad().points, beside, 200,
            maxOffsetMeters: 20),
        isEmpty,
      );
      expect(
        clipWayAround(_straightRoad().points, beside, 200,
            maxOffsetMeters: 80),
        isNotEmpty,
      );
    });
  });

  group('mergeConnectedWays', () {
    // OpenStreetMap hands back a street as several short pieces; these three
    // are consecutive stretches of one road.
    const a = RoadWay(
      id: 1,
      name: 'Aquino Avenue',
      points: [LatLng(14.9540, 120.9010), LatLng(14.9540, 120.9020)],
    );
    const b = RoadWay(
      id: 2,
      name: 'Aquino Avenue',
      points: [LatLng(14.9540, 120.9020), LatLng(14.9540, 120.9030)],
    );
    const c = RoadWay(
      id: 3,
      name: 'Aquino Avenue',
      points: [LatLng(14.9540, 120.9030), LatLng(14.9540, 120.9040)],
    );

    test('chains consecutive fragments of the same road', () {
      final merged = mergeConnectedWays([a, b, c]);
      expect(merged, hasLength(1));
      expect(merged.single.points.first, const LatLng(14.9540, 120.9010));
      expect(merged.single.points.last, const LatLng(14.9540, 120.9040));
    });

    test('does not duplicate the shared node at a join', () {
      expect(mergeConnectedWays([a, b]).single.points, hasLength(3));
    });

    test('chains fragments given out of order', () {
      final merged = mergeConnectedWays([c, a, b]);
      expect(merged, hasLength(1));
      expect(merged.single.points, hasLength(4));
    });

    test('reverses a fragment that was drawn the other way round', () {
      final reversed = RoadWay(
        id: 2,
        name: 'Aquino Avenue',
        points: b.points.reversed.toList(),
      );
      final merged = mergeConnectedWays([a, reversed]);
      expect(merged, hasLength(1));
      expect(merged.single.points.last, const LatLng(14.9540, 120.9030));
    });

    test('keeps different roads apart even where they touch', () {
      const crossing = RoadWay(
        id: 9,
        name: 'Rizal Street',
        points: [LatLng(14.9540, 120.9020), LatLng(14.9550, 120.9020)],
      );
      final merged = mergeConnectedWays([a, crossing]);
      expect(merged, hasLength(2));
    });

    test('leaves disconnected fragments of one road separate', () {
      final merged = mergeConnectedWays([a, c]);
      expect(merged, hasLength(2));
    });

    test('does not merge unnamed ways, which could be any junction', () {
      const u1 = RoadWay(
        id: 4,
        points: [LatLng(14.9540, 120.9010), LatLng(14.9540, 120.9020)],
      );
      const u2 = RoadWay(
        id: 5,
        points: [LatLng(14.9540, 120.9020), LatLng(14.9540, 120.9030)],
      );
      expect(mergeConnectedWays([u1, u2]), hasLength(2));
    });

    test('merging makes a longer stretch paintable', () {
      // The point of the exercise: before merging, a 300 m request can only
      // paint the fragment it landed on.
      const at = LatLng(14.9540, 120.9020);
      final unmerged = clipWayAround(a.points, at, 300);
      final merged = clipWayAround(
        mergeConnectedWays([a, b, c]).single.points,
        at,
        300,
      );
      expect(_lengthMeters(merged), greaterThan(_lengthMeters(unmerged)));
    });
  });

  group('bestWayFor', () {
    test('picks the nearer of two roads', () {
      final near = _straightRoad(name: 'Near');
      final far = RoadWay(
        id: 2,
        name: 'Far',
        points: [
          for (var i = 0; i <= 10; i++)
            LatLng(14.9545, 120.9010 + i * 0.001),
        ],
      );
      expect(bestWayFor([far, near], _onRoad)?.name, 'Near');
    });

    test('returns nothing when every road is too far', () {
      expect(bestWayFor([_straightRoad()], _offRoad), isNull);
    });

    test('returns nothing when there are no roads at all', () {
      expect(bestWayFor(const [], _onRoad), isNull);
    });

    test('prefers a named street over a closer unnamed stub', () {
      // The shape of a real junction: a short nameless connector right under
      // the report, and the actual street a little further off.
      const stub = RoadWay(
        id: 9,
        points: [LatLng(14.9540, 120.9059), LatLng(14.9540, 120.9061)],
      );
      final street = _straightRoad(name: 'Aquino Avenue');
      final slightlyOff = LatLng(_onRoad.latitude + 0.0002, _onRoad.longitude);

      expect(bestWayFor([stub, street], slightlyOff)?.name, 'Aquino Avenue');
    });

    test('prefers a substantial road over a short fragment of one', () {
      const fragment = RoadWay(
        id: 9,
        name: 'Short Bit',
        points: [LatLng(14.9540, 120.9059), LatLng(14.9540, 120.9061)],
      );
      final street = _straightRoad(name: 'Aquino Avenue');
      final slightlyOff = LatLng(_onRoad.latitude + 0.0002, _onRoad.longitude);

      expect(bestWayFor([fragment, street], slightlyOff)?.name,
          'Aquino Avenue');
    });

    test('still takes the nearest when candidates are comparable', () {
      final near = _straightRoad(name: 'Near');
      final far = RoadWay(
        id: 2,
        name: 'Far',
        points: [
          for (var i = 0; i <= 10; i++) LatLng(14.9545, 120.9010 + i * 0.001),
        ],
      );
      expect(bestWayFor([far, near], _onRoad)?.name, 'Near');
    });

    test('the penalty never reaches past the hard offset limit', () {
      // A named road well outside the snap radius must stay ineligible, no
      // matter how poor the nearby candidates are.
      const stub = RoadWay(
        id: 9,
        points: [LatLng(14.9540, 120.9059), LatLng(14.9540, 120.9061)],
      );
      expect(bestWayFor([stub], _offRoad), isNull);
    });
  });

  group('wayLengthMeters', () {
    test('measures a polyline', () {
      expect(wayLengthMeters(_straightRoad().points), closeTo(1075, 40));
    });

    test('a degenerate way has no length', () {
      expect(wayLengthMeters(const []), 0);
      expect(wayLengthMeters(const [LatLng(14.954, 120.901)]), 0);
    });
  });

  group('buildTrafficSegments', () {
    test('places a zone that sits on a road', () {
      final result = buildTrafficSegments([_zone()], [_straightRoad()]);
      expect(result.segments, hasLength(1));
      expect(result.unplaced, isEmpty);
      expect(result.segments.single.roadName, 'Test Road');
    });

    test('a zone with no road under it stays unplaced', () {
      final result = buildTrafficSegments(
        [_zone(center: _offRoad)],
        [_straightRoad()],
      );
      expect(result.segments, isEmpty);
      expect(result.unplaced, hasLength(1));
    });

    test('with no geometry loaded yet, every zone is unplaced', () {
      // This is the first-paint state, and the map must still show something.
      final result = buildTrafficSegments([_zone()], const []);
      expect(result.segments, isEmpty);
      expect(result.unplaced, hasLength(1));
    });

    test('carries severity and reports onto the segment', () {
      final result = buildTrafficSegments(
        [_zone(severity: 0.8)],
        [_straightRoad()],
      );
      final segment = result.segments.single;
      expect(segment.severity, 0.8);
      expect(segment.reports, hasLength(1));
      expect(segment.label, 'Heavy traffic');
    });

    test('worse traffic is drawn thicker as well as redder', () {
      final light = buildTrafficSegments(
        [_zone(severity: 0.1)],
        [_straightRoad()],
      ).segments.single;
      final heavy = buildTrafficSegments(
        [_zone(severity: 1)],
        [_straightRoad()],
      ).segments.single;

      expect(heavy.strokeWidth, greaterThan(light.strokeWidth));
      expect(heavy.color, isNot(light.color));
    });

    test('a bigger zone paints a longer stretch of road', () {
      final small = buildTrafficSegments(
        [_zone(radiusMeters: 120)],
        [_straightRoad()],
      ).segments.single;
      final large = buildTrafficSegments(
        [_zone(radiusMeters: 400)],
        [_straightRoad()],
      ).segments.single;

      expect(
        _lengthMeters(large.points),
        greaterThan(_lengthMeters(small.points)),
      );
    });

    test('mixed zones split into placed and unplaced', () {
      final result = buildTrafficSegments(
        [_zone(), _zone(center: _offRoad)],
        [_straightRoad()],
      );
      expect(result.segments, hasLength(1));
      expect(result.unplaced, hasLength(1));
    });
  });
}

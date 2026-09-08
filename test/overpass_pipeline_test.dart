/// End-to-end check of the road-snapping pipeline against a real Overpass
/// response, captured from the public API for the Glorieta Rotonda in
/// Baliwag — the busiest junction the app serves.
///
/// The synthetic tests in traffic_segment_test.dart use tidy straight roads.
/// This one uses the messy article: fifteen fragments, five named streets, a
/// roundabout, and several unnamed slip ways.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:toda_equeue_plus/core/models/road_report.dart';
import 'package:toda_equeue_plus/core/models/traffic_segment.dart';

/// The junction the fixture was captured around.
const _rotonda = LatLng(14.9540, 120.9010);

double _lengthMeters(List<LatLng> points) {
  const d = Distance();
  var total = 0.0;
  for (var i = 0; i < points.length - 1; i++) {
    total += d.as(LengthUnit.Meter, points[i], points[i + 1]);
  }
  return total;
}

void main() {
  final body = File(
    'test/fixtures/overpass_baliwag_rotonda.json',
  ).readAsStringSync();

  test('parses the real response into usable roads', () {
    final ways = parseOverpassWays(body);
    expect(ways, hasLength(15));
    expect(ways.every((w) => w.points.length >= 2), isTrue);
    expect(
      ways.map((w) => w.name).whereType<String>(),
      contains('Benigno S. Aquino Avenue'),
    );
  });

  test('merging joins the fragments into whole streets', () {
    final raw = parseOverpassWays(body);
    final merged = mergeConnectedWays(raw);

    // Fewer pieces after chaining, and no road is lost in the process.
    expect(merged.length, lessThan(raw.length));
    expect(
      merged.map((w) => w.name).whereType<String>().toSet(),
      containsAll(<String>{
        'Benigno S. Aquino Avenue',
        'Glorieta Rotonda',
        'J. P. Rizal Street',
      }),
    );
  });

  test('merging paints a longer stretch at the junction', () {
    final raw = parseOverpassWays(body);
    final merged = mergeConnectedWays(raw);

    double paintedAtRotonda(List<RoadWay> ways) {
      final way = bestWayFor(ways, _rotonda);
      if (way == null) return 0;
      return _lengthMeters(clipWayAround(way.points, _rotonda, 300));
    }

    // The rotonda arrives as six fragments; chained, it is one 187 m loop.
    expect(paintedAtRotonda(merged), greaterThan(paintedAtRotonda(raw) * 2));
  });

  test('a report at the rotonda snaps onto a named road', () {
    final ways = mergeConnectedWays(parseOverpassWays(body));
    final way = bestWayFor(ways, _rotonda);

    expect(way, isNotNull);
    expect(way!.name, isNotNull);
  });

  test('does not snap to the unnamed slip way at the junction', () {
    // The closest centreline to the middle of the rotonda is a 76 m unnamed
    // connector. Colouring that tells another driver nothing, so the scoring
    // has to reach past it to the street itself.
    final ways = mergeConnectedWays(parseOverpassWays(body));

    final nearest = ways.reduce((a, b) {
      final da = nearestOnWay(a.points, _rotonda)?.distanceMeters ?? 1e9;
      final db = nearestOnWay(b.points, _rotonda)?.distanceMeters ?? 1e9;
      return da <= db ? a : b;
    });
    expect(nearest.name, isNull, reason: 'fixture should still have the stub');

    expect(bestWayFor(ways, _rotonda)!.name, isNotNull);
  });

  test('a congestion zone there paints a real stretch of road', () {
    final ways = mergeConnectedWays(parseOverpassWays(body));
    final zone = CongestionZone(
      center: _rotonda,
      severity: 0.9,
      radiusMeters: 250,
      reports: const [],
    );

    final result = buildTrafficSegments([zone], ways);
    expect(result.segments, hasLength(1));
    expect(result.unplaced, isEmpty);

    final segment = result.segments.single;
    expect(segment.points.length, greaterThan(2));
    // Long enough to read as a coloured street rather than a stub.
    expect(_lengthMeters(segment.points), greaterThan(150));
    expect(segment.label, 'Heavy traffic');
  });

  test('a zone well away from these roads is left unplaced', () {
    final ways = mergeConnectedWays(parseOverpassWays(body));
    final zone = CongestionZone(
      // ~5 km north, outside anything in the fixture.
      center: const LatLng(15.0, 120.9010),
      severity: 0.9,
      radiusMeters: 250,
      reports: const [],
    );

    final result = buildTrafficSegments([zone], ways);
    expect(result.segments, isEmpty);
    expect(result.unplaced, hasLength(1));
  });

  test('a truncated or junk response degrades to no roads', () {
    expect(parseOverpassWays(body.substring(0, 200)), isEmpty);
    expect(parseOverpassWays('<html>503 Service Unavailable</html>'), isEmpty);
    expect(parseOverpassWays('{"elements":[]}'), isEmpty);
  });
}

/// Tests for the TomTom routing parser.
///
/// Two sets. The inline fixtures cover the documented shape and the ways a
/// reply can be malformed. The other set runs against a response actually
/// captured from the live service for a Baliwag trip, which is what caught
/// the parser reading `routeOffsetInMeters` — distance from the start of the
/// route — as though it were the length of a single step.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:toda_equeue_plus/core/models/navigation_state.dart';
import 'package:toda_equeue_plus/core/models/road_report.dart';
import 'package:toda_equeue_plus/config/api_keys.dart';
import 'package:toda_equeue_plus/core/services/tomtom_router.dart';

const _twoRoutes = '''
{
  "routes": [
    {
      "summary": {
        "lengthInMeters": 7700,
        "travelTimeInSeconds": 900,
        "trafficDelayInSeconds": 180
      },
      "legs": [
        {
          "points": [
            {"latitude": 14.9540, "longitude": 120.9010},
            {"latitude": 14.9545, "longitude": 120.9050},
            {"latitude": 14.9550, "longitude": 120.9090}
          ]
        }
      ],
      "guidance": {
        "instructions": [
          {
            "maneuver": "DEPART",
            "street": "Dr. Gonzales Street",
            "routeOffsetInMeters": 0
          },
          {
            "maneuver": "TURN_LEFT",
            "street": "A. Mabini Street",
            "routeOffsetInMeters": 650
          },
          {"maneuver": "ARRIVE", "routeOffsetInMeters": 7700}
        ]
      }
    },
    {
      "summary": {
        "lengthInMeters": 8900,
        "travelTimeInSeconds": 960,
        "trafficDelayInSeconds": 0
      },
      "legs": [
        {
          "points": [
            {"latitude": 14.9540, "longitude": 120.9010},
            {"latitude": 14.9600, "longitude": 120.9050}
          ]
        }
      ]
    }
  ]
}
''';

void main() {
  final now = DateTime(2026, 9, 9, 12);

  group('parsing a documented response', () {
    test('reads every route, best first', () {
      final routes = parseTomTomRoutes(_twoRoutes);
      expect(routes, hasLength(2));
      expect(routes.first.distanceMeters, 7700);
      expect(routes.first.durationSeconds, 900);
      expect(routes.last.distanceMeters, 8900);
    });

    test('reads the geometry out of the legs', () {
      final route = parseTomTomRoutes(_twoRoutes).first;
      expect(route.points, hasLength(3));
      expect(route.points.first, const LatLng(14.9540, 120.9010));
      expect(route.points.last, const LatLng(14.9550, 120.9090));
    });

    test('carries the measured traffic delay', () {
      final routes = parseTomTomRoutes(_twoRoutes);
      expect(routes.first.trafficDelaySeconds, 180);
      expect(routes.last.trafficDelaySeconds, 0);
    });

    test('marks the route as traffic-aware', () {
      final route = parseTomTomRoutes(_twoRoutes).first;
      expect(route.source, 'tomtom');
      expect(route.isTrafficAware, isTrue);
      expect(route.isRealRoute, isTrue);
    });

    test('translates guidance into the app\'s own instructions', () {
      final steps = parseTomTomRoutes(_twoRoutes).first.steps;
      expect(steps, hasLength(3));
      expect(steps.first.instruction, contains('Dr. Gonzales Street'));
      expect(steps[1].instruction, 'Turn left onto A. Mabini Street');
      expect(steps.last.instruction, 'You have arrived');
    });

    test('a route without guidance is still usable', () {
      // Guidance is optional; a route with no instructions still draws and
      // still has an ETA.
      final second = parseTomTomRoutes(_twoRoutes).last;
      expect(second.steps, isEmpty);
      expect(second.points.length, greaterThanOrEqualTo(2));
    });
  });

  group('degrading safely', () {
    test('junk, empty and truncated replies yield no routes', () {
      expect(parseTomTomRoutes('{"routes":[]}'), isEmpty);
      expect(parseTomTomRoutes('<html>403 Forbidden</html>'), isEmpty);
      expect(parseTomTomRoutes(_twoRoutes.substring(0, 80)), isEmpty);
      expect(parseTomTomRoutes('{}'), isEmpty);
    });

    test('a route with too few points is skipped, not returned broken', () {
      const thin = '''
      {"routes":[{"summary":{"lengthInMeters":10,"travelTimeInSeconds":5},
      "legs":[{"points":[{"latitude":14.9,"longitude":120.9}]}]}]}
      ''';
      expect(parseTomTomRoutes(thin), isEmpty);
    });

    test('a missing summary does not throw', () {
      const noSummary = '''
      {"routes":[{"legs":[{"points":[
        {"latitude":14.9,"longitude":120.9},
        {"latitude":14.91,"longitude":120.91}]}]}]}
      ''';
      final routes = parseTomTomRoutes(noSummary);
      expect(routes, hasLength(1));
      expect(routes.first.distanceMeters, 0);
    });

    test('being configured is exactly having a non-empty key', () {
      // Deliberately not asserting which state this machine is in.
      // api_keys.dart is gitignored, so it holds a key on a developer's
      // machine and none on a fresh clone; a test that demanded either
      // would fail for somebody. What must hold in both is that the flag
      // tracks the key, since it is what decides between TomTom and OSRM.
      expect(TomTomRouter.isConfigured, ApiKeys.tomTom.trim().isNotEmpty);
    });
  });

  group('against a response captured from the live service', () {
    final body = File(
      'test/fixtures/tomtom_baliwag_route.json',
    ).readAsStringSync();

    test('returns the real alternatives TomTom found', () {
      // The reason for this whole integration: OSRM returns one route for
      // this pair, TomTom returns three.
      final routes = parseTomTomRoutes(body);
      expect(routes, hasLength(3));
      for (final r in routes) {
        expect(r.points.length, greaterThan(100));
        expect(r.distanceMeters, greaterThan(1000));
        expect(r.durationSeconds, greaterThan(0));
        expect(r.isTrafficAware, isTrue);
      }
    });

    test('the first route is the quickest, as TomTom orders them', () {
      final routes = parseTomTomRoutes(body);
      for (final other in routes.skip(1)) {
        expect(
          routes.first.durationSeconds,
          lessThanOrEqualTo(other.durationSeconds),
        );
      }
    });

    test('step distances are per-step, not measured from the start', () {
      // routeOffsetInMeters counts from the beginning of the route. Read
      // directly it would have told a driver to turn in 1851 m when the
      // turn was 1851 m from where the trip started.
      final steps = parseTomTomRoutes(body).first.steps;
      expect(steps.length, greaterThan(2));

      final total = parseTomTomRoutes(body).first.distanceMeters;
      for (final s in steps) {
        expect(s.distanceMeters, lessThan(total));
        expect(s.distanceMeters, greaterThanOrEqualTo(0));
      }
      // Summing the steps should approximate the route, not exceed it.
      final summed = steps.fold<double>(0, (a, s) => a + s.distanceMeters);
      expect(summed, lessThanOrEqualTo(total + 1));
    });

    test('uses the phrasing TomTom supplies', () {
      final steps = parseTomTomRoutes(body).first.steps;
      expect(steps.first.instruction, isNotEmpty);
      // The arrival instruction names the street TomTom knows about.
      expect(steps.last.instruction.toLowerCase(), contains('arrived'));
    });

    test('every step yields a usable instruction', () {
      for (final r in parseTomTomRoutes(body)) {
        for (final s in r.steps) {
          expect(s.instruction, isNotEmpty, reason: s.maneuver);
        }
      }
    });
  });

  group('not counting the same congestion twice', () {
    NavRoute lineOf(String source) => NavRoute(
      points: [
        for (var i = 0; i <= 10; i++) LatLng(14.9540, 120.9010 + i * 0.001),
      ],
      distanceMeters: 1075,
      durationSeconds: 600,
      source: source,
    );

    RoadReport reportOf(ReportType type) => RoadReport(
      id: 'r1',
      type: type,
      location: const LatLng(14.9540, 120.9060),
      reportedBy: 'uid',
      reporterName: 'Test',
      reporterRole: 'driver',
      createdAt: now,
      expiresAt: now.add(const Duration(hours: 1)),
    );

    test('a traffic report the feed measured is not counted again', () {
      // TomTom already measured this congestion; adding the app's estimate
      // of the same jam on top would count it twice.
      //
      // This used to assume TomTom measured *every* jam on its routes and
      // ignored all traffic reports outright. It does not: a driver reported
      // heavy traffic at the Glorieta Rotonda with TomTom's nearest incident
      // 2.9 km away, and the report changed nothing. The skip now applies
      // only where the measured data demonstrably has the jam.
      final score = scoreRoute(
        lineOf('tomtom'),
        [reportOf(ReportType.trafficHeavy)],
        now: now,
        alreadyMeasured: (_) => true,
      );
      expect(score.penaltySeconds, 0);
      expect(score.isEstimate, isFalse);
    });

    test('but still counts on an OSRM route, which has no traffic feed', () {
      final score = scoreRoute(
        lineOf('osrm'),
        [reportOf(ReportType.trafficHeavy)],
        now: now,
      );
      expect(score.penaltySeconds, greaterThan(0));
    });

    test('an accident counts either way — a router cannot see one', () {
      for (final source in ['tomtom', 'osrm']) {
        final score = scoreRoute(
          lineOf(source),
          [reportOf(ReportType.accident)],
          now: now,
        );
        expect(score.penaltySeconds, greaterThan(0), reason: source);
      }
    });

    test('a closure still blocks a traffic-aware route', () {
      final score = scoreRoute(
        lineOf('tomtom'),
        [reportOf(ReportType.roadClosure)],
        now: now,
      );
      expect(score.isBlocked, isTrue);
    });
  });

  group('asking TomTom to route around an incident', () {
    const rotonda = LatLng(14.9540, 120.9010);

    Map<String, dynamic> rect(Map<String, dynamic> body, int i) =>
        ((body['avoidAreas'] as Map)['rectangles'] as List)[i]
            as Map<String, dynamic>;

    test('builds the body shape TomTom accepted live', () {
      // This exact shape routed around the Glorieta Rotonda: 22 route points
      // inside the box without it, none with it.
      final body = avoidAreasBody([rotonda]);
      final r = rect(body, 0);
      expect(r.keys, containsAll(['southWestCorner', 'northEastCorner']));
      expect(
        (r['southWestCorner'] as Map).keys,
        containsAll(['latitude', 'longitude']),
      );
    });

    test('the box surrounds the reported spot', () {
      final r = rect(avoidAreasBody([rotonda]), 0);
      final sw = r['southWestCorner'] as Map, ne = r['northEastCorner'] as Map;
      expect(sw['latitude'] as double, lessThan(rotonda.latitude));
      expect(sw['longitude'] as double, lessThan(rotonda.longitude));
      expect(ne['latitude'] as double, greaterThan(rotonda.latitude));
      expect(ne['longitude'] as double, greaterThan(rotonda.longitude));
    });

    test('is big enough to cover the rotonda ring and no more', () {
      // The ring is 187 m around, about 60 m across. The box has to take all
      // of it, but closing off a whole neighbourhood would leave a detour
      // nowhere to go.
      final r = rect(avoidAreasBody([rotonda]), 0);
      final sw = r['southWestCorner'] as Map, ne = r['northEastCorner'] as Map;
      const d = Distance();
      final width = d.as(
        LengthUnit.Meter,
        LatLng(sw['latitude'] as double, sw['longitude'] as double),
        LatLng(sw['latitude'] as double, ne['longitude'] as double),
      );
      final height = d.as(
        LengthUnit.Meter,
        LatLng(sw['latitude'] as double, sw['longitude'] as double),
        LatLng(ne['latitude'] as double, sw['longitude'] as double),
      );
      // Square on the ground, not just in degrees.
      expect(width, closeTo(140, 3));
      expect(height, closeTo(140, 3));
    });

    test('caps the number of areas sent', () {
      final many = [
        for (var i = 0; i < 25; i++) LatLng(14.95 + i * 0.002, 120.90),
      ];
      final rects =
          (avoidAreasBody(many)['avoidAreas'] as Map)['rectangles'] as List;
      expect(rects, hasLength(kMaxAvoidAreas));
    });

    test('keeps the worst first when capping', () {
      // Callers sort by severity; the cap must drop from the end, never the
      // road closure at the front.
      final many = [
        rotonda,
        for (var i = 1; i < 25; i++) LatLng(14.95 + i * 0.002, 120.90),
      ];
      final first = rect(avoidAreasBody(many), 0);
      final sw = first['southWestCorner'] as Map;
      expect(sw['latitude'] as double, closeTo(rotonda.latitude, 0.001));
    });

    test('nothing to avoid sends no areas', () {
      final rects =
          (avoidAreasBody(const [])['avoidAreas'] as Map)['rectangles'] as List;
      expect(rects, isEmpty);
    });
  });
}

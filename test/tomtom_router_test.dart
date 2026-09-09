/// Tests for the TomTom routing parser.
///
/// The fixtures below are hand-built to the shape TomTom documents for
/// Calculate Route: routes[].summary.{lengthInMeters, travelTimeInSeconds,
/// trafficDelayInSeconds} and routes[].legs[].points[].{latitude, longitude}.
///
/// They are NOT captured from the live service — that needs an API key, which
/// this project does not have yet. So these prove the parser handles the
/// documented shape and degrades safely on anything else; they do not prove
/// the live response matches the documentation. That check belongs on the
/// first real call.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:toda_equeue_plus/core/models/navigation_state.dart';
import 'package:toda_equeue_plus/core/models/road_report.dart';
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

    test('routing is off until a key is configured', () {
      // The app ships with an empty key and stays on OSRM.
      expect(TomTomRouter.isConfigured, isFalse);
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

    test('a traffic report is ignored on a traffic-aware route', () {
      // TomTom already measured this congestion; adding the app's estimate
      // of the same jam on top would count it twice.
      final score = scoreRoute(
        lineOf('tomtom'),
        [reportOf(ReportType.trafficHeavy)],
        now: now,
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
}

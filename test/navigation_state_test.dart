import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:toda_equeue_plus/core/models/navigation_state.dart';
import 'package:toda_equeue_plus/core/models/road_report.dart';
import 'package:toda_equeue_plus/core/models/trip_state.dart';
import 'package:toda_equeue_plus/core/services/navigation_router.dart';

/// A straight east–west route through Baliwag, ~1.1 km, node every ~110 m.
NavRoute _route({double durationSeconds = 600}) => NavRoute(
  points: [
    for (var i = 0; i <= 10; i++) LatLng(14.9540, 120.9010 + i * 0.001),
  ],
  distanceMeters: 1075,
  durationSeconds: durationSeconds,
);

const _onRoute = LatLng(14.9540, 120.9060);

RoadReport _report({
  String id = 'r1',
  ReportType type = ReportType.trafficHeavy,
  LatLng at = _onRoute,
  int confirmations = 0,
  IncidentStatus? storedStatus,
  DateTime? expiresAt,
  DateTime? createdAt,
  bool cleared = false,
}) => RoadReport(
  id: id,
  type: type,
  location: at,
  reportedBy: 'uid',
  reporterName: 'Test',
  reporterRole: 'driver',
  confirmations: confirmations,
  storedStatus: storedStatus,
  createdAt: createdAt ?? DateTime(2026, 9, 9, 12),
  expiresAt: expiresAt ?? DateTime(2026, 9, 9, 13),
  cleared: cleared,
);

void main() {
  final now = DateTime(2026, 9, 9, 12, 5);

  group('navigation phase follows the trip state machine', () {
    test('maps each trip status to a leg', () {
      expect(
        NavigationPhase.forTrip(TripStatus.driverOnTheWay),
        NavigationPhase.toPickup,
      );
      expect(
        NavigationPhase.forTrip(TripStatus.driverArrived),
        NavigationPhase.atPickup,
      );
      expect(
        NavigationPhase.forTrip(TripStatus.readyToStart),
        NavigationPhase.atPickup,
      );
      expect(
        NavigationPhase.forTrip(TripStatus.tripInProgress),
        NavigationPhase.toDestination,
      );
    });

    test('navigation stops when the trip ends', () {
      for (final s in [TripStatus.tripCompleted, TripStatus.cancelled]) {
        expect(NavigationPhase.forTrip(s), NavigationPhase.idle, reason: s.name);
        expect(NavigationPhase.forTrip(s).isNavigating, isFalse);
      }
    });

    test('navigation continues past pickup rather than ending there', () {
      // The spec is explicit that reaching the pickup is not the end of
      // navigation; the destination leg follows.
      expect(
        NavigationPhase.forTrip(TripStatus.tripInProgress).isNavigating,
        isTrue,
      );
    });

    test('every trip status maps to some phase', () {
      for (final s in TripStatus.values) {
        expect(() => NavigationPhase.forTrip(s), returnsNormally);
      }
    });
  });

  group('incidents on a route', () {
    test('a report on the line is picked up', () {
      final found = incidentsOn(_route(), [_report()], now: now);
      expect(found, hasLength(1));
    });

    test('a report on a parallel street is not', () {
      // ~220 m north of the route.
      final off = LatLng(_onRoute.latitude + 0.002, _onRoute.longitude);
      expect(incidentsOn(_route(), [_report(at: off)], now: now), isEmpty);
    });

    test('an expired report is ignored', () {
      final stale = _report(expiresAt: now.subtract(const Duration(minutes: 1)));
      expect(incidentsOn(_route(), [stale], now: now), isEmpty);
    });

    test('an admin-rejected report is ignored', () {
      final rejected = _report(storedStatus: IncidentStatus.rejected);
      expect(incidentsOn(_route(), [rejected], now: now), isEmpty);
    });

    test('judges reports against the given time, not the wall clock', () {
      // A deliberately historic window: by the real clock this report is
      // long expired, but relative to the instant being asked about it is
      // live. Reading DateTime.now() anywhere in here makes this fail, and
      // it fails every run rather than only after the fixtures happen to
      // age past their expiry.
      final past = DateTime(2020, 1, 1, 12);
      final report = _report(
        createdAt: past,
        expiresAt: past.add(const Duration(hours: 1)),
      );

      expect(
        incidentsOn(_route(), [report], now: past.add(const Duration(minutes: 5))),
        hasLength(1),
      );
      expect(
        incidentsOn(_route(), [report], now: past.add(const Duration(hours: 2))),
        isEmpty,
      );
    });

    test('scoring and blocking also honour the given time', () {
      final past = DateTime(2020, 1, 1, 12);
      final closure = _report(
        type: ReportType.roadClosure,
        createdAt: past,
        expiresAt: past.add(const Duration(hours: 1)),
      );

      final during = scoreRoute(
        _route(),
        [closure],
        now: past.add(const Duration(minutes: 5)),
      );
      expect(during.isBlocked, isTrue);
      expect(during.penaltySeconds, greaterThan(0));

      final after = scoreRoute(
        _route(),
        [closure],
        now: past.add(const Duration(hours: 2)),
      );
      expect(after.isBlocked, isFalse);
      expect(after.penaltySeconds, 0);
    });
  });

  group('route scoring', () {
    test('a clear route carries no penalty and is not an estimate', () {
      final score = scoreRoute(_route(), const [], now: now);
      expect(score.penaltySeconds, 0);
      expect(score.adjustedSeconds, 600);
      expect(score.isEstimate, isFalse);
    });

    test('a reported delay lengthens the estimate', () {
      final score = scoreRoute(_route(), [_report()], now: now);
      expect(score.adjustedSeconds, greaterThan(600));
      expect(score.isEstimate, isTrue);
    });

    test('corroboration increases the penalty', () {
      final lone = scoreRoute(_route(), [_report()], now: now);
      final backed = scoreRoute(
        _route(),
        [_report(confirmations: 4)],
        now: now,
      );
      expect(backed.penaltySeconds, greaterThan(lone.penaltySeconds));
    });

    test('a worse incident type costs more than a milder one', () {
      final moderate = scoreRoute(
        _route(),
        [_report(type: ReportType.trafficModerate)],
        now: now,
      );
      final accident = scoreRoute(
        _route(),
        [_report(type: ReportType.accident)],
        now: now,
      );
      expect(accident.penaltySeconds, greaterThan(moderate.penaltySeconds));
    });

    test('a reported closure marks the route blocked', () {
      final score = scoreRoute(
        _route(),
        [_report(type: ReportType.roadClosure)],
        now: now,
      );
      expect(score.isBlocked, isTrue);
    });
  });

  group('choosing a route', () {
    test('prefers the lower adjusted time, not the shorter road', () {
      // The spec's example: longer but quicker should win.
      final shortSlow = RouteScore(
        route: NavRoute(
          points: _route().points,
          distanceMeters: 2400,
          durationSeconds: 720,
        ),
        incidentsOnRoute: const [],
        penaltySeconds: 0,
      );
      final longFast = RouteScore(
        route: NavRoute(
          points: _route().points,
          distanceMeters: 3100,
          durationSeconds: 600,
        ),
        incidentsOnRoute: const [],
        penaltySeconds: 0,
      );
      expect(chooseBest([shortSlow, longFast])?.route.distanceMeters, 3100);
    });

    test('a blocked route loses to a usable one even when quicker', () {
      final blocked = scoreRoute(
        _route(durationSeconds: 300),
        [_report(type: ReportType.roadClosure)],
        now: now,
      );
      final open = scoreRoute(_route(durationSeconds: 900), const [], now: now);
      expect(chooseBest([blocked, open]), open);
    });

    test('falls back to a blocked route when nothing else exists', () {
      // Better to show the driver the closure than to show nothing.
      final blocked = scoreRoute(
        _route(),
        [_report(type: ReportType.roadClosure)],
        now: now,
      );
      expect(chooseBest([blocked]), blocked);
    });

    test('no candidates yields no route', () {
      expect(chooseBest(const []), isNull);
    });
  });

  group('reroute decision', () {
    RouteScore plain(double seconds) => RouteScore(
      route: _route(durationSeconds: seconds),
      incidentsOnRoute: const [],
      penaltySeconds: 0,
    );

    test('does not reroute for a trivial saving', () {
      // 30 s off a 10 min route: real, but not worth switching for.
      expect(
        rerouteDecision(current: plain(600), candidate: plain(570)),
        RerouteReason.none,
      );
    });

    test('does not reroute when the saving is large but proportionally tiny', () {
      // 150 s off a 2 hr route clears the absolute bar but not the 15% one.
      expect(
        rerouteDecision(current: plain(7200), candidate: plain(7050)),
        RerouteReason.none,
      );
    });

    test('reroutes for a meaningful saving', () {
      expect(
        rerouteDecision(current: plain(900), candidate: plain(600)),
        RerouteReason.fasterRoute,
      );
    });

    test('never reroutes onto a blocked road', () {
      final blocked = scoreRoute(
        _route(durationSeconds: 60),
        [_report(type: ReportType.roadClosure)],
        now: now,
      );
      expect(
        rerouteDecision(current: plain(900), candidate: blocked),
        RerouteReason.none,
      );
    });

    test('escapes a closure even when the detour is slower', () {
      final blocked = scoreRoute(
        _route(durationSeconds: 300),
        [_report(type: ReportType.roadClosure)],
        now: now,
      );
      expect(
        rerouteDecision(current: blocked, candidate: plain(1200)),
        RerouteReason.roadBlocked,
      );
    });

    test('leaving the route recalculates regardless of timings', () {
      expect(
        rerouteDecision(
          current: plain(600),
          candidate: plain(600),
          driverIsOffRoute: true,
        ),
        RerouteReason.offRoute,
      );
    });

    test('every reason a driver is shown says something specific', () {
      for (final r in RerouteReason.values) {
        if (r == RerouteReason.none) continue;
        expect(r.message, isNotEmpty, reason: r.name);
      }
    });
  });

  group('off-route detection', () {
    test('a driver on the road is never off-route', () {
      final d = OffRouteDetector();
      for (var i = 0; i < 10; i++) {
        expect(d.update(_route(), _onRoute), isFalse);
      }
    });

    test('a single stray fix does not trigger a reroute', () {
      // This is the GPS-jitter case; reacting to it makes navigation
      // twitchy and untrustworthy.
      final d = OffRouteDetector();
      final far = LatLng(_onRoute.latitude + 0.002, _onRoute.longitude);
      expect(d.update(_route(), far), isFalse);
      expect(d.update(_route(), _onRoute), isFalse);
      expect(d.update(_route(), far), isFalse);
    });

    test('sustained deviation does trigger one', () {
      final d = OffRouteDetector();
      final far = LatLng(_onRoute.latitude + 0.002, _onRoute.longitude);
      expect(d.update(_route(), far), isFalse);
      expect(d.update(_route(), far), isFalse);
      expect(d.update(_route(), far), isTrue);
    });

    test('it rearms after firing rather than firing every fix', () {
      final d = OffRouteDetector();
      final far = LatLng(_onRoute.latitude + 0.002, _onRoute.longitude);
      for (var i = 0; i < 3; i++) {
        d.update(_route(), far);
      }
      expect(d.update(_route(), far), isFalse);
    });
  });

  group('progress and ETA', () {
    test('remaining distance shrinks as the driver advances', () {
      final start = remainingMeters(_route(), _route().points.first);
      final middle = remainingMeters(_route(), _onRoute);
      final end = remainingMeters(_route(), _route().points.last);
      expect(middle, lessThan(start));
      expect(end, lessThan(middle));
    });

    test('ETA shrinks with remaining distance', () {
      final score = scoreRoute(_route(), const [], now: now);
      final atStart = remainingDuration(score, _route().points.first);
      final halfway = remainingDuration(score, _onRoute);
      expect(halfway, lessThan(atStart));
    });

    test('a congestion penalty carries into the ETA', () {
      final clear = scoreRoute(_route(), const [], now: now);
      final busy = scoreRoute(_route(), [_report()], now: now);
      expect(
        remainingDuration(busy, _route().points.first),
        greaterThan(remainingDuration(clear, _route().points.first)),
      );
    });

    test('ETA reads the way a driver expects', () {
      expect(formatEta(const Duration(seconds: 30)), '1 min');
      expect(formatEta(const Duration(minutes: 4)), '4 min');
      expect(formatEta(const Duration(minutes: 60)), '1 hr');
      expect(formatEta(const Duration(minutes: 70)), '1 hr 10 min');
    });

    test('distance reads the way a driver expects', () {
      expect(formatDistance(450), '450 m');
      expect(formatDistance(2400), '2.4 km');
    });

    test('arrival is now plus the remaining time', () {
      final from = DateTime(2026, 9, 9, 12);
      expect(
        arrivalTime(const Duration(minutes: 8), from: from),
        DateTime(2026, 9, 9, 12, 8),
      );
    });
  });

  group('arrival', () {
    test('detects arrival within the threshold', () {
      expect(hasArrived(_onRoute, _onRoute), isTrue);
    });

    test('does not claim arrival from a block away', () {
      final away = LatLng(_onRoute.latitude + 0.002, _onRoute.longitude);
      expect(hasArrived(away, _onRoute), isFalse);
    });
  });

  group('turn instructions', () {
    test('describes the common manoeuvres', () {
      expect(
        const NavStep(
          road: 'A. Mabini Street',
          maneuver: 'turn',
          modifier: 'left',
          distanceMeters: 100,
        ).instruction,
        'Turn left onto A. Mabini Street',
      );
      expect(
        const NavStep(road: '', maneuver: 'arrive', distanceMeters: 0)
            .instruction,
        'You have arrived',
      );
    });

    test('copes with the unnamed roads OSM is full of here', () {
      // Several steps on the captured Baliwag route have no name at all.
      final step = const NavStep(
        road: '',
        maneuver: 'turn',
        modifier: 'right',
        distanceMeters: 50,
      );
      expect(step.instruction, 'Turn right');
      expect(step.instruction, isNot(contains('onto')));
    });
  });

  group('straight-line fallback', () {
    test('is flagged as not a real route', () {
      final fallback = NavRoute.straightLine(
        const LatLng(14.954, 120.901),
        const LatLng(14.955, 120.902),
      );
      expect(fallback.isRealRoute, isFalse);
      expect(fallback.source, 'straight-line');
    });

    test('a routed result is flagged as real', () {
      expect(_route().isRealRoute, isTrue);
    });
  });

  group('OSRM parsing, against a real captured response', () {
    final body = File(
      'test/fixtures/osrm_baliwag_route.json',
    ).readAsStringSync();

    test('reads the route Baliwag actually returned', () {
      final route = parseOsrmRoute(body)!;
      expect(route.points, hasLength(105));
      expect(route.distanceMeters, closeTo(3460, 40));
      expect(route.durationSeconds, closeTo(336, 30));
      expect(route.isRealRoute, isTrue);
    });

    test('reads the turn steps with their street names', () {
      final route = parseOsrmRoute(body)!;
      expect(route.steps, hasLength(7));
      expect(
        route.steps.map((s) => s.road),
        contains('Dr. Gonzales Street'),
      );
      expect(route.steps.last.maneuver, 'arrive');
      expect(route.nextStep!.maneuver, 'depart');
    });

    test('every step produces a usable instruction', () {
      for (final step in parseOsrmRoute(body)!.steps) {
        expect(step.instruction, isNotEmpty, reason: step.maneuver);
      }
    });

    test('a failed or junk response yields no route, never an exception', () {
      expect(parseOsrmRoute('{"code":"NoRoute","routes":[]}'), isNull);
      expect(parseOsrmRoute('<html>502 Bad Gateway</html>'), isNull);
      expect(parseOsrmRoute(body.substring(0, 120)), isNull);
      expect(parseOsrmRoute('{"code":"Ok"}'), isNull);
    });
  });
}

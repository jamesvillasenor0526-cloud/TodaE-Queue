/// Tests for the moving-start-point geometry, driven along routes TomTom
/// actually returned over Baliwag (test/fixtures/tomtom_baliwag_route.json):
/// three complete alternatives, 9.5, 9.0 and 8.3 km.
///
/// "Driving" here means feeding the route's own points in order, the way GPS
/// readings arrive from a phone on that road — the geometry is real, only
/// the sequence of readings is replayed.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:toda_equeue_plus/core/models/live_route.dart';
import 'package:toda_equeue_plus/core/models/navigation_state.dart';
import 'package:toda_equeue_plus/core/models/traffic_segment.dart'
    show nearestOnWay;
import 'package:toda_equeue_plus/core/services/tomtom_router.dart';

void main() {
  final routes = parseTomTomRoutes(
    File('test/fixtures/tomtom_baliwag_route.json').readAsStringSync(),
  );
  final main = routes[0];
  final cum = cumulativeMeters(main.points);
  const distance = Distance();

  /// A reading [meters] to the side of point [i] — GPS never sits exactly on
  /// the centreline.
  LatLng beside(int i, double meters) {
    final a = main.points[i];
    final b = main.points[math.min(i + 1, main.points.length - 1)];
    final bearing = bearingDegrees(a, b) + 90;
    return distance.offset(a, meters, bearing);
  }

  test('the fixture is three complete routes, as captured', () {
    expect(routes, hasLength(3));
    for (final r in routes) {
      // Every alternative runs the whole way, start to destination.
      expect(distance.as(LengthUnit.Meter, r.points.first, main.points.first),
          lessThan(50));
      expect(distance.as(LengthUnit.Meter, r.points.last, main.points.last),
          lessThan(50));
    }
  });

  group('where the driver is along the road', () {
    test('at the start, nothing is travelled', () {
      final p = progressAlong(main.points, main.points.first)!;
      expect(p.travelledMeters, closeTo(0, 1));
      expect(p.remainingMeters, closeTo(cum.last, 1));
    });

    test('the geometry is the length TomTom reported', () {
      // Within 1%: step distances are scaled to it, so it has to be right.
      expect(cum.last, closeTo(main.distanceMeters, main.distanceMeters * 0.01));
    });

    test('driving along it, what is left only ever shrinks', () {
      int? hint;
      var last = double.infinity;
      for (var i = 0; i < main.points.length; i += 3) {
        final p = progressAlong(
          main.points,
          beside(i, 6),
          hint: hint,
          cumulative: cum,
        )!;
        expect(p.remainingMeters, lessThanOrEqualTo(last + 1), reason: 'at $i');
        expect(p.offRouteMeters, lessThan(10), reason: 'at $i');
        last = p.remainingMeters;
        hint = p.segment;
      }
      expect(last, lessThan(60));
    });

    test('a reading well off to the side is off the route', () {
      final p = progressAlong(main.points, beside(80, 150), cumulative: cum)!;
      expect(p.offRouteMeters, greaterThan(kOffRouteMeters));
    });

    test('the hint keeps progress continuous where a route doubles back', () {
      // Out along a street and back on a parallel one 20 m away: a reading on
      // the way back is nearest, globally, to either leg.
      final hairpin = [
        for (var i = 0; i <= 10; i++) LatLng(14.95, 120.90 + i * 0.001),
        for (var i = 10; i >= 0; i--) LatLng(14.9502, 120.90 + i * 0.001),
      ];
      final hc = cumulativeMeters(hairpin);
      final onTheWayBack = LatLng(14.95015, 120.905);
      final p = progressAlong(hairpin, onTheWayBack, hint: 16, cumulative: hc)!;
      expect(p.segment, greaterThanOrEqualTo(11));
      expect(p.travelledMeters, greaterThan(hc.last / 2));
    });
  });

  group('where the arrow is drawn', () {
    test('close to the road, on the road', () {
      // GPS 15 m off the centreline: the arrow sits on the road, where the
      // line starts, rather than floating beside it.
      final gps = beside(100, 15);
      final p = progressAlong(main.points, gps, cumulative: cum)!;
      expect(displayPosition(gps, p), p.snapped);
    });

    test('far from the road, where the GPS actually is', () {
      // Well off the route, the driver may really have left it; drawing
      // them on the road would hide that.
      final gps = beside(100, 80);
      final p = progressAlong(main.points, gps, cumulative: cum)!;
      expect(displayPosition(gps, p), gps);
    });

    test('with no route yet, where the GPS is', () {
      final gps = beside(100, 5);
      expect(displayPosition(gps, null), gps);
    });
  });

  group('the line that is drawn', () {
    test('starts under the driver and ends at the destination', () {
      final p = progressAlong(main.points, beside(100, 5), cumulative: cum)!;
      final line = remainingLine(main.points, p);
      expect(line.first, p.snapped);
      expect(line.last, main.points.last);
    });

    test('shortens as the driver goes', () {
      final early = remainingLine(
        main.points,
        progressAlong(main.points, main.points[20], cumulative: cum)!,
      );
      final later = remainingLine(
        main.points,
        progressAlong(main.points, main.points[150], cumulative: cum)!,
      );
      expect(later.length, lessThan(early.length));
      final left = cumulativeMeters(later).last;
      expect(left, closeTo(cum.last - cum[150], 5));
    });
  });

  group('the next turn, counting down live', () {
    test('from the start it is the first real turn, not "depart"', () {
      final up = upcomingAt(main, 0, geometryMeters: cum.last)!;
      expect(up.step.maneuver, isNot('depart'));
      expect(up.step.instruction, contains('Turn left'));
      // TomTom put it 1851 m along the route.
      expect(up.metersAway, closeTo(1851, 1851 * 0.02));
    });

    test('the distance to it falls as the driver closes on it', () {
      final at500 = upcomingAt(main, 500, geometryMeters: cum.last)!;
      final at1500 = upcomingAt(main, 1500, geometryMeters: cum.last)!;
      expect(at500.key, at1500.key);
      expect(at1500.metersAway, lessThan(at500.metersAway));
      expect(at500.metersAway - at1500.metersAway, closeTo(1000, 5));
    });

    test('once past it, the next turn takes over', () {
      final first = upcomingAt(main, 0, geometryMeters: cum.last)!;
      final past = upcomingAt(
        main,
        first.metersAway + kTurnPassedMeters + 5,
        geometryMeters: cum.last,
      )!;
      expect(past.key, isNot(first.key));
      expect(past.step.instruction, contains('Turn right'));
    });

    test('just past a turn it is still shown, while the driver is turning', () {
      final first = upcomingAt(main, 0, geometryMeters: cum.last)!;
      final turning = upcomingAt(
        main,
        first.metersAway + 5,
        geometryMeters: cum.last,
      )!;
      expect(turning.key, first.key);
      expect(turning.metersAway, 0);
    });

    test('near the end it is the arrival', () {
      final up = upcomingAt(main, cum.last - 30, geometryMeters: cum.last)!;
      expect(up.isArrival, isTrue);
    });
  });

  group('labelling the alternatives', () {
    test('the label sits on the alternative\'s own road', () {
      for (final alt in routes.skip(1)) {
        final at = labelAnchor(alt.points, main.points)!;
        // Clear of the fastest route, so it cannot be mistaken for it…
        expect(
          nearestOnWay(main.points, at)!.distanceMeters,
          greaterThanOrEqualTo(40),
        );
        // …and on the line it describes.
        expect(nearestOnWay(alt.points, at)!.distanceMeters, lessThan(5));
      }
    });

    test('two alternatives get labels in different places', () {
      // Each placed where its own route goes its own way, so the two labels
      // never stack on a road the alternatives share.
      final a = labelAnchor(routes[1].points, main.points, others: [routes[2].points])!;
      final b = labelAnchor(routes[2].points, main.points, others: [routes[1].points])!;
      expect(distance.as(LengthUnit.Meter, a, b), greaterThan(200));
      expect(nearestOnWay(routes[2].points, a)!.distanceMeters, greaterThanOrEqualTo(40));
      expect(nearestOnWay(routes[1].points, b)!.distanceMeters, greaterThanOrEqualTo(40));
    });

    test('no label when the two routes never separate', () {
      expect(labelAnchor(main.points, main.points), isNull);
    });

    test('says the real difference in time', () {
      expect(
        timeDifferenceLabel(alternativeSeconds: 720, activeSeconds: 600),
        '2 min slower',
      );
      expect(
        timeDifferenceLabel(alternativeSeconds: 900, activeSeconds: 600),
        '5 min slower',
      );
    });

    test('against a slower chosen route, the others are faster', () {
      expect(
        timeDifferenceLabel(alternativeSeconds: 600, activeSeconds: 720),
        '2 min faster',
      );
    });

    test('under half a minute apart is similar, not "0 min slower"', () {
      expect(
        timeDifferenceLabel(alternativeSeconds: 620, activeSeconds: 600),
        'Similar time',
      );
    });

    test('an estimated time says so', () {
      expect(
        timeDifferenceLabel(
          alternativeSeconds: 900,
          activeSeconds: 600,
          estimate: true,
        ),
        '≈5 min slower',
      );
    });

    test('labels for the real captured routes match their times', () {
      // TomTom: 1590 s fastest-by-traffic, then 1789 s and 1626 s.
      final byTime = [...routes]
        ..sort((a, b) => a.durationSeconds.compareTo(b.durationSeconds));
      final fastest = byTime.first.durationSeconds;
      expect(
        timeDifferenceLabel(
          alternativeSeconds: byTime[1].durationSeconds,
          activeSeconds: fastest,
        ),
        '1 min slower',
      );
      expect(
        timeDifferenceLabel(
          alternativeSeconds: byTime[2].durationSeconds,
          activeSeconds: fastest,
        ),
        '3 min slower',
      );
    });
  });

  group('which way the arrow points', () {
    test('bearings are compass bearings', () {
      const a = LatLng(14.95, 120.90);
      expect(bearingDegrees(a, const LatLng(14.96, 120.90)), closeTo(0, 0.5));
      expect(bearingDegrees(a, const LatLng(14.95, 120.91)), closeTo(90, 0.5));
      expect(bearingDegrees(a, const LatLng(14.94, 120.90)), closeTo(180, 0.5));
    });

    test('moving, it follows the GPS heading', () {
      expect(
        displayHeading(
          gpsHeading: 135,
          speedMetersPerSecond: 6,
          roadBearing: 90,
        ),
        135,
      );
    });

    test('stopped, it follows the road rather than GPS noise', () {
      expect(
        displayHeading(
          gpsHeading: 311,
          speedMetersPerSecond: 0.2,
          roadBearing: 90,
        ),
        90,
      );
    });

    test('an invalid GPS heading is ignored', () {
      expect(
        displayHeading(
          gpsHeading: -1,
          speedMetersPerSecond: 8,
          roadBearing: 45,
        ),
        45,
      );
    });

    test('turns the short way round', () {
      expect(shortestTurn(350, 10), closeTo(20, 1e-9));
      expect(shortestTurn(10, 350), closeTo(-20, 1e-9));
      expect(shortestTurn(90, 270).abs(), closeTo(180, 1e-9));
    });
  });

  group('several complete routes on offer', () {
    RouteScore plain(double seconds) => RouteScore(
      route: NavRoute(
        points: main.points,
        distanceMeters: main.distanceMeters,
        durationSeconds: seconds,
      ),
      incidentsOnRoute: const [],
      penaltySeconds: 0,
    );

    test('the fastest plus two slower ones, quickest first', () {
      // An 18-minute trip with routes 2 and 5 minutes slower, as in the
      // spec's example.
      final choices = buildChoices([plain(1380), plain(1080), plain(1200)])!;
      expect(choices.recommended.route.durationSeconds, 1080);
      expect(
        choices.alternatives.map((a) => a.route.durationSeconds),
        [1200, 1380],
      );
      expect(choices.all, hasLength(3));
    });

    test('a detour half again as long is still not offered', () {
      // The existing rule against absurd loops holds with more alternatives.
      final choices = buildChoices([plain(600), plain(720), plain(900)])!;
      expect(
        choices.alternatives.map((a) => a.route.durationSeconds),
        [720],
      );
    });

    test('no more than two alternatives', () {
      final choices = buildChoices([
        plain(600),
        plain(660),
        plain(720),
        plain(780),
      ])!;
      expect(choices.alternatives, hasLength(kMaxAlternatives));
    });
  });

  group('a way round that goes up a side street and back', () {
    // The real route published to a live trip going round a confirmed
    // accident: OSRM, forced through a point, went 141 m up a side street
    // and back about 900 m in.
    final captured = File('test/fixtures/osrm_detour_with_loop.json');
    final looped = [
      for (final p in (jsonDecode(captured.readAsStringSync())['points'] as List))
        LatLng((p as List)[0] as double, p[1] as double),
    ];

    test('is caught whole, not just its middle', () {
      // Every point going up the side street sits beside one coming back, so
      // a detector that stops at the first pair finds only part of it. The
      // whole of it wastes 470 m: up the side street and back, plus 68 m of
      // the road it came in on, retraced. (The fixture starts 514 m into the
      // trip, so the loop sits 319–789 m in here; on the phone it was
      // 832–1303 m.)
      final loop = findLoop(looped)!;
      final cum = cumulativeMeters(looped);
      expect(cum[loop.start], closeTo(319, 5));
      expect(cum[loop.end], closeTo(789, 5));
      expect(loop.wastedMeters, closeTo(470, 5));
    });

    test('the retry point is on the road the route rejoins, past the spur', () {
      final loop = findLoop(looped)!;
      final through = throughPointAfter(looped, loop)!;
      final cum = cumulativeMeters(looped);
      // Looked up after the loop: a loop passes the same spot twice, so the
      // first match by value would be the way out.
      final at = [
        for (var k = loop.end + 1; k < looped.length; k++) k,
      ].firstWhere((k) => looped[k] == through);
      expect(cum[at] - cum[loop.end], greaterThanOrEqualTo(80));
    });

    test('routes a router chose itself have no such loop', () {
      // TomTom's three complete Baliwag routes: none comes back on itself.
      for (final r in routes) {
        expect(findLoop(r.points), isNull);
      }
    });

    test('a short U-turn at a junction is not mistaken for one', () {
      // Out 60 m and back: under the length that counts as a loop.
      final uTurn = [
        for (var i = 0; i <= 6; i++) LatLng(14.95, 120.90 + i * 0.0001),
        for (var i = 5; i >= 0; i--) LatLng(14.95, 120.90 + i * 0.0001),
      ];
      expect(findLoop(uTurn), isNull);
    });
  });

  group('alternatives that are a different way, not the main way again', () {
    RouteScore scored(NavRoute r) =>
        RouteScore(route: r, incidentsOnRoute: const [], penaltySeconds: 0);

    test('measures how much of a route runs on another', () {
      expect(sharedFraction(main.points, main.points), closeTo(1, 0.01));
      // TomTom's third route follows the fastest for three-quarters of its
      // length; the second takes a different way for more than half.
      expect(sharedFraction(routes[2].points, main.points), closeTo(0.76, 0.02));
      expect(sharedFraction(routes[1].points, main.points), closeTo(0.46, 0.02));
    });

    test('the main way with a variation is not offered as another way', () {
      final choices = buildChoices(
        routes.map(scored).toList(),
        maxShared: kMaxSharedWithRecommended,
      )!;
      expect(choices.recommended.route.sameRouteAs(main), isTrue);
      // Route 1, which goes a different way, is offered; route 2, which is
      // the fastest route again for 76% of it, is not.
      expect(choices.alternatives, hasLength(1));
      expect(choices.alternatives.single.route.sameRouteAs(routes[1]), isTrue);
    });

    test('without the check, both would have been offered', () {
      final choices = buildChoices(routes.map(scored).toList())!;
      expect(choices.alternatives, hasLength(2));
    });
  });

  group('the road being driven, fetched again', () {
    test('is the same road, though its endpoints differ', () {
      // Re-fetched from 1 km further on, the route starts somewhere else, so
      // comparing endpoints says it is a different route — and the panel
      // ticked neither option and offered Use on both. Judged by the road,
      // it is the one being driven.
      final p = progressAlong(
        main.points,
        main.points[cum.indexWhere((c) => c >= 1000)],
        cumulative: cum,
      )!;
      final fetchedAgain = trimRouteTo(main, p);
      expect(fetchedAgain.sameRouteAs(main), isFalse);
      expect(
        sharedFraction(fetchedAgain.points, main.points),
        greaterThanOrEqualTo(kSameRoadFraction),
      );
    });

    test('a genuinely different way is not mistaken for it', () {
      expect(
        sharedFraction(routes[1].points, main.points),
        lessThan(kSameRoadFraction),
      );
    });
  });

  group('reusing a route found a minute ago', () {
    test('it starts where the driver is now', () {
      final p = progressAlong(main.points, main.points[80], cumulative: cum)!;
      final trimmed = trimRouteTo(main, p);
      expect(trimmed.points.first, p.snapped);
      expect(trimmed.points.last, main.points.last);
      expect(trimmed.distanceMeters, closeTo(p.remainingMeters, 1));
    });

    test('its time no longer includes the road already driven', () {
      final p = progressAlong(main.points, main.points[110], cumulative: cum)!;
      final trimmed = trimRouteTo(main, p);
      expect(
        trimmed.durationSeconds,
        closeTo(main.durationSeconds * p.remainingFraction, 1),
      );
      expect(trimmed.durationSeconds, lessThan(main.durationSeconds));
    });

    test('its next turn is the same turn, the same distance away', () {
      // Trimmed at 1000 m, the next turn is the one TomTom put at 1851 m —
      // about 850 m from here, whichever way it is worked out.
      final p = progressAlong(
        main.points,
        main.points[cum.indexWhere((c) => c >= 1000)],
        cumulative: cum,
      )!;
      final trimmed = trimRouteTo(main, p);
      final fromTrimmed = upcomingAt(trimmed, 0)!;
      final fromOriginal = upcomingAt(
        main,
        p.travelledMeters,
        geometryMeters: cum.last,
      )!;
      expect(fromTrimmed.key, fromOriginal.key);
      expect(fromTrimmed.metersAway, closeTo(fromOriginal.metersAway, 5));
    });

    test('turns already passed are dropped', () {
      final p = progressAlong(
        main.points,
        main.points[cum.indexWhere((c) => c >= 2500)],
        cumulative: cum,
      )!;
      final trimmed = trimRouteTo(main, p);
      expect(trimmed.steps.first.maneuver, 'depart');
      expect(trimmed.steps.length, lessThan(main.steps.length));
    });
  });
}

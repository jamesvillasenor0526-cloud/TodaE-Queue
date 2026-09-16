/// Tests for carrying a vehicle forward between position readings — the
/// difference between a marker that hops every couple of seconds and one
/// that drives.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:toda_equeue_plus/core/models/live_route.dart';
import 'package:toda_equeue_plus/core/models/motion.dart';

const distance = Distance();

/// A kilometre of straight road running east, a point every 100 m.
final straight = [
  for (var i = 0; i <= 10; i++) LatLng(14.95, 120.90 + i * 0.000931),
];

/// A right-angle bend: 500 m east, then 500 m north.
final corner = [
  for (var i = 0; i <= 5; i++) LatLng(14.95, 120.90 + i * 0.000931),
  for (var i = 1; i <= 5; i++) LatLng(14.95 + i * 0.000899, 120.904655),
];

void main() {
  group('a point along a road', () {
    test('at the start, and at the end', () {
      expect(alongRoute(straight, 0)!.at, straight.first);
      expect(alongRoute(straight, 99999)!.at, straight.last);
    });

    test('halfway is halfway', () {
      final total = cumulativeMeters(straight).last;
      final middle = alongRoute(straight, total / 2)!;
      expect(
        distance.as(LengthUnit.Meter, middle.at, straight[5]),
        lessThan(15),
      );
    });

    test('carries the bearing of the road there', () {
      // East along the first leg, north after the bend.
      expect(alongRoute(corner, 200)!.heading, closeTo(90, 3));
      expect(alongRoute(corner, 800)!.heading, closeTo(0, 3));
    });

    test('a road that is not a road gives nothing', () {
      expect(alongRoute(const [], 10), isNull);
      expect(alongRoute([straight.first], 10), isNull);
    });
  });

  group('joining the line to the vehicle', () {
    // The line and the marker used to be worked out from different
    // positions — the marker from the eased carried-forward one, the line
    // from the last raw fix — so the line kept detaching from the tricycle
    // and snapping back. Now the line begins exactly where the marker is.
    test('the line starts at the vehicle, not at the nearest road point', () {
      // 8 m to the side of the road, as GPS always is.
      final beside = distance.offset(straight[3], 8, 0);
      final line = lineFromVehicle(straight, beside);
      expect(line.first, beside);
      expect(line.last, straight.last);
    });

    test('a vehicle already on the line adds no duplicate point', () {
      final onIt = lineAhead(straight, straight[3]).first;
      final line = lineFromVehicle(straight, onIt);
      expect(line.first, onIt);
      expect(
        distance.as(LengthUnit.Meter, line[0], line[1]),
        greaterThan(1),
        reason: 'no zero-length first segment',
      );
    });

    test('off the route, the join shows the way back to it', () {
      // Half a kilometre off: the line runs from the vehicle to the road it
      // should be on, rather than floating unattached.
      final away = distance.offset(straight[2], 500, 0);
      final line = lineFromVehicle(straight, away);
      expect(line.first, away);
      expect(line.length, straight.length + 1);
    });

    test('with no position, the whole route is drawn unchanged', () {
      expect(lineFromVehicle(straight, null), straight);
    });

    test('nothing to draw stays nothing', () {
      expect(lineFromVehicle(const [], straight.first), isEmpty);
    });
  });

  group('carrying a vehicle forward', () {
    test('a stopped vehicle stays where it is', () {
      // GPS speed jitters while parked; projecting it would have a standing
      // tricycle creeping down the road.
      final held = carriedForward(
        lastFix: straight[2],
        sinceFix: const Duration(seconds: 3),
        speed: 0.4,
        route: straight,
      );
      expect(held.at, straight[2]);
    });

    test('a moving one is drawn ahead of its last reading', () {
      // 8 m/s for 2 s is about 16 m further along the road.
      final moved = carriedForward(
        lastFix: straight[2],
        sinceFix: const Duration(seconds: 2),
        speed: 8,
        route: straight,
      );
      expect(
        distance.as(LengthUnit.Meter, moved.at, straight[2]),
        closeTo(16, 3),
      );
    });

    test('it follows the road round a bend, not across it', () {
      // 490 m along, 20 s at 8 m/s: past the corner and heading north. Cut
      // straight it would end up in the fields inside the corner.
      final start = alongRoute(corner, 490)!.at;
      final after = carriedForward(
        lastFix: start,
        sinceFix: const Duration(seconds: 20),
        speed: 8,
        route: corner,
      );
      final onRoad = progressAlong(corner, after.at)!;
      expect(onRoad.offRouteMeters, lessThan(10), reason: 'stays on the road');
      expect(after.heading, closeTo(0, 10), reason: 'now heading north');
    });

    test('it is never carried further than a few seconds', () {
      // A phone that stops reporting must not sail off down the road.
      final far = carriedForward(
        lastFix: straight.first,
        sinceFix: const Duration(minutes: 5),
        speed: 8,
        route: straight,
      );
      final capped = 8.0 * kMaxCarryForward.inSeconds;
      expect(
        distance.as(LengthUnit.Meter, far.at, straight.first),
        lessThan(capped + 10),
      );
    });

    test('it never runs off the end of the route', () {
      final past = carriedForward(
        lastFix: straight[9],
        sinceFix: const Duration(seconds: 5),
        speed: 40,
        route: straight,
      );
      expect(past.at, straight.last);
    });

    test('a vehicle off the route is drawn where it actually is', () {
      // Half a kilometre away: there is no road here to carry it along, and
      // guessing would put it on a road it has left.
      final away = distance.offset(straight[3], 500, 0);
      final drawn = carriedForward(
        lastFix: away,
        sinceFix: const Duration(seconds: 2),
        speed: 8,
        route: straight,
      );
      expect(drawn.at, away);
    });

    test('with no route there is nothing to carry it along', () {
      final drawn = carriedForward(
        lastFix: straight[1],
        sinceFix: const Duration(seconds: 2),
        speed: 8,
      );
      expect(drawn.at, straight[1]);
    });

    test('a reading from the future moves nothing', () {
      final drawn = carriedForward(
        lastFix: straight[1],
        sinceFix: const Duration(seconds: -4),
        speed: 8,
        route: straight,
      );
      expect(drawn.at, straight[1]);
    });

    test('the longer the wait, the further along — until the cap', () {
      double after(int seconds) => distance.as(
        LengthUnit.Meter,
        straight.first,
        carriedForward(
          lastFix: straight.first,
          sinceFix: Duration(seconds: seconds),
          speed: 8,
          route: straight,
        ).at,
      );
      expect(after(1), lessThan(after(2)));
      expect(after(2), lessThan(after(4)));
      expect(after(30), closeTo(after(kMaxCarryForward.inSeconds), 1));
    });
  });
}

/// Tests for routes that start behind the driver, and for driving against
/// the route — the recorded drive north along B.S. Aquino Avenue, where the
/// line trailed behind the arrow and took 25 s to catch up.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:toda_equeue_plus/core/models/navigation_state.dart';

/// A straight road north from [start], a point every ~22 m.
NavRoute northFrom(LatLng start) => NavRoute(
  points: [
    for (var i = 0; i <= 20; i++)
      LatLng(start.latitude + i * 0.0002, start.longitude),
  ],
  distanceMeters: 445,
  durationSeconds: 90,
);

/// The same road, southbound.
NavRoute southFrom(LatLng start) => NavRoute(
  points: [
    for (var i = 0; i <= 20; i++)
      LatLng(start.latitude - i * 0.0002, start.longitude),
  ],
  distanceMeters: 445,
  durationSeconds: 60,
);

const here = LatLng(14.9802666, 120.8933643);
const driving = 8.0; // m/s, about 29 km/h

void main() {
  group('which way a route sets off', () {
    test('north and south', () {
      expect(setOffBearing(northFrom(here)), closeTo(0, 1));
      expect(setOffBearing(southFrom(here)), closeTo(180, 1));
    });
  });

  group('travelling against the route', () {
    test('heading north on a southbound road is against it', () {
      expect(
        isAgainstRoute(heading: 5, speed: driving, roadBearing: 180),
        isTrue,
      );
    });

    test('a bend in the road is not the wrong way', () {
      expect(
        isAgainstRoute(heading: 90, speed: driving, roadBearing: 0),
        isFalse,
      );
    });

    test('a slow or stopped phone is never judged by its course', () {
      // GPS course wanders at walking pace and means nothing when still.
      expect(isAgainstRoute(heading: 5, speed: 1, roadBearing: 180), isFalse);
      expect(
        isAgainstRoute(heading: null, speed: driving, roadBearing: 180),
        isFalse,
      );
    });
  });

  group('routes that set off behind the driver', () {
    test('are dropped while the driver is moving', () {
      final kept = keepThoseAhead(
        [southFrom(here), northFrom(here)],
        (r) => r,
        heading: 2,
        speed: driving,
      );
      expect(kept.length, 1);
      expect(setOffBearing(kept.single), closeTo(0, 1));
    });

    test('are kept when there is nothing else — a U-turn beats no route', () {
      final kept = keepThoseAhead(
        [southFrom(here)],
        (r) => r,
        heading: 2,
        speed: driving,
      );
      expect(kept.length, 1);
    });

    test('are all fine for a driver standing still', () {
      // Waiting at the pickup, any direction is a fair start.
      final kept = keepThoseAhead(
        [southFrom(here), northFrom(here)],
        (r) => r,
        heading: 2,
        speed: 0,
      );
      expect(kept.length, 2);
    });
  });

  group('a driver who takes a different road', () {
    // The route runs north. The driver turns onto the next street over —
    // 40 m to the east, well inside the 60 m the detector calls "on the
    // route" — and drives north along that instead. By distance alone they
    // never left it, so the map went on showing the first way while they
    // drove another. What gives them away is that they stop getting any
    // closer to the end of the route they are supposed to be on.
    const distance = Distance();

    test('is noticed, even while within the on-route distance', () {
      final route = northFrom(here);
      final detector = OffRouteDetector();

      // Setting off along the route proper, for reference.
      expect(detector.update(route, here, heading: 0, speed: driving), isFalse);

      // Now on the parallel street, heading the same way, 40 m to the side.
      var left = false;
      for (var i = 1; i <= 8; i++) {
        final on = LatLng(here.latitude + i * 0.0002, here.longitude);
        final beside = distance.offset(on, 40, 90);
        if (detector.update(route, beside, heading: 0, speed: driving)) {
          left = true;
          break;
        }
      }
      expect(left, isTrue, reason: 'never noticed the driver had turned off');
    });

    test('a driver following the route is left alone', () {
      final route = northFrom(here);
      final detector = OffRouteDetector();
      for (var i = 0; i <= 15; i++) {
        // Along the line, with the few metres of GPS scatter any phone has.
        final on = LatLng(here.latitude + i * 0.0002, here.longitude);
        final scattered = distance.offset(on, 6, i.isEven ? 90 : 270);
        expect(
          detector.update(route, scattered, heading: 0, speed: driving),
          isFalse,
          reason: 'reading $i',
        );
      }
    });

    test('sitting in traffic on the route is not leaving it', () {
      // Stopped at a junction: no progress, but no travel either, so there
      // is nothing to judge and nothing to recalculate.
      final route = northFrom(here);
      final detector = OffRouteDetector();
      for (var i = 0; i < 20; i++) {
        expect(
          detector.update(route, here, heading: 0, speed: 0),
          isFalse,
          reason: 'reading $i',
        );
      }
    });
  });

  group('the off-route detector', () {
    test('driving against the route on its own road counts as leaving it', () {
      // On the line — 0 m off — but going the other way.
      final route = southFrom(here);
      final detector = OffRouteDetector();
      final results = [
        for (var i = 0; i < kOffRouteFixes; i++)
          detector.update(route, here, heading: 0, speed: driving),
      ];
      expect(results.last, isTrue);
    });

    test('following the route on its road does not', () {
      final route = northFrom(here);
      final detector = OffRouteDetector();
      for (var i = 0; i < kOffRouteFixes + 2; i++) {
        expect(
          detector.update(route, here, heading: 2, speed: driving),
          isFalse,
        );
      }
    });

    test('one reading against it is not enough', () {
      final route = southFrom(here);
      final detector = OffRouteDetector();
      expect(detector.update(route, here, heading: 0, speed: driving), isFalse);
      // Back on course: the count starts again.
      expect(
        detector.update(route, here, heading: 180, speed: driving),
        isFalse,
      );
      expect(detector.update(route, here, heading: 0, speed: driving), isFalse);
    });
  });
}

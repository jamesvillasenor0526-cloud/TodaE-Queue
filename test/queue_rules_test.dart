/// Tests for keeping and losing a place in the queue.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:toda_equeue_plus/core/models/queue_rules.dart';

/// A terminal about 40 m across, the shape the database stores (4 corners).
const terminal = [
  LatLng(14.9540, 120.9010),
  LatLng(14.9540, 120.9014),
  LatLng(14.9544, 120.9014),
  LatLng(14.9544, 120.9010),
];

/// [meters] north of the terminal's northern edge.
LatLng north(double meters) => LatLng(14.9544 + meters / 111320.0, 120.9012);

void main() {
  group('how far outside the terminal', () {
    test('inside is zero', () {
      expect(
        metersOutsideBoundary(const LatLng(14.9542, 120.9012), terminal),
        0,
      );
    });

    test('just outside is a few metres, not a jump', () {
      expect(metersOutsideBoundary(north(10), terminal), closeTo(10, 2));
    });

    test('a street away is a hundred metres or so', () {
      expect(metersOutsideBoundary(north(120), terminal), closeTo(120, 3));
    });

    test('a terminal with no usable boundary never ejects anyone', () {
      // Some records could have fewer than three corners; losing your place
      // over bad data would be worse than keeping it.
      expect(metersOutsideBoundary(north(500), const []), 0);
      expect(
        metersOutsideBoundary(north(500), const [LatLng(14.95, 120.90)]),
        0,
      );
    });
  });

  group('leaving the queue', () {
    test('drifting at the edge does not cost a place', () {
      expect(leavesQueue(metersOutside: 30, consecutiveOutside: 9), isFalse);
    });

    test('one stray reading does not either', () {
      expect(leavesQueue(metersOutside: 300, consecutiveOutside: 1), isFalse);
    });

    test('driving away does', () {
      expect(
        leavesQueue(metersOutside: 300, consecutiveOutside: kQueueExitFixes),
        isTrue,
      );
    });
  });

  group('a driver who does not answer', () {
    test('is given a minute and a half', () {
      expect(waitedLongEnoughToReassign(const Duration(seconds: 30)), isFalse);
      expect(waitedLongEnoughToReassign(const Duration(seconds: 89)), isFalse);
      expect(waitedLongEnoughToReassign(kAcceptWindow), isTrue);
      expect(waitedLongEnoughToReassign(const Duration(minutes: 5)), isTrue);
    });
  });

  group('giving up a place for leaving the terminal', () {
    test('a waiting driver who drives away loses their place', () {
      expect(mayGiveUpPlace('waiting'), isTrue);
    });

    test(
      'a dispatched driver never does — they are going to the passenger',
      () {
        // This stranded a real booking: the entry was cancelled seconds after
        // dispatch, the booking stayed REQUESTED against a cancelled entry,
        // and the trip never appeared on the driver's screen.
        expect(mayGiveUpPlace('dispatched'), isFalse);
        expect(mayGiveUpPlace('accepted'), isFalse);
      },
    );

    test('an entry that is already finished is left alone', () {
      expect(mayGiveUpPlace('completed'), isFalse);
      expect(mayGiveUpPlace('cancelled'), isFalse);
      expect(mayGiveUpPlace(null), isFalse);
      expect(mayGiveUpPlace('something new'), isFalse);
    });
  });

  group('who is offered a trip that has been refused', () {
    // Drivers in queue order, front first.
    const queue = ['mang-tony', 'boy', 'jun'];
    String idOf(String d) => d;

    test('the front of the queue, when nobody has refused', () {
      expect(firstNotDeclined(queue, const {}, idOf), 'mang-tony');
    });

    test('the next one, when the front has refused', () {
      expect(firstNotDeclined(queue, const {'mang-tony'}, idOf), 'boy');
    });

    test('never someone who already said no', () {
      expect(firstNotDeclined(queue, const {'mang-tony', 'boy'}, idOf), 'jun');
    });

    test('nobody, when everyone waiting has refused', () {
      expect(
        firstNotDeclined(queue, const {'mang-tony', 'boy', 'jun'}, idOf),
        isNull,
      );
    });

    test('nobody, when the terminal is empty', () {
      expect(firstNotDeclined(const <String>[], const {'boy'}, idOf), isNull);
    });

    test('queue order is kept, not the order they refused in', () {
      expect(firstNotDeclined(queue, const {'boy'}, idOf), 'mang-tony');
    });
  });
}

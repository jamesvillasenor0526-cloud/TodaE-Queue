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
LatLng north(double meters) =>
    LatLng(14.9544 + meters / 111320.0, 120.9012);

void main() {
  group('how far outside the terminal', () {
    test('inside is zero', () {
      expect(metersOutsideBoundary(const LatLng(14.9542, 120.9012), terminal), 0);
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
}

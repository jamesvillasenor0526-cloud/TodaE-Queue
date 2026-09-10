/// Tests for deciding whether a position is fresh enough to report from.
///
/// Found on the emulator: moved, then reported straight away, the sheet
/// showed the previous spot 3 km away. Filed, the report would have landed
/// on the wrong road and been merged into the reporter's own earlier one.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:toda_equeue_plus/core/models/location_fix.dart';

void main() {
  final now = DateTime(2026, 9, 10, 19, 0);

  group('is a reading fresh enough to report from', () {
    test('a reading from moments ago is fresh', () {
      expect(isStaleFix(now.subtract(const Duration(seconds: 3)), now), isFalse);
    });

    test('a cached reading from before the driver moved is stale', () {
      expect(isStaleFix(now.subtract(const Duration(minutes: 2)), now), isTrue);
    });

    test('the line sits at ten seconds', () {
      // About 55 m at tricycle speed — roughly the stretch a report covers.
      expect(isStaleFix(now.subtract(const Duration(seconds: 10)), now), isFalse);
      expect(isStaleFix(now.subtract(const Duration(seconds: 11)), now), isTrue);
    });

    test('a clock slightly ahead of the fix is not stale', () {
      expect(isStaleFix(now.add(const Duration(seconds: 2)), now), isFalse);
    });
  });

  group('saying how old the location is', () {
    test('reads naturally', () {
      expect(fixAgeLabel(const Duration(seconds: 5)), 'just now');
      expect(fixAgeLabel(const Duration(seconds: 40)), '40 s ago');
      expect(fixAgeLabel(const Duration(minutes: 3)), '3 min ago');
      expect(fixAgeLabel(const Duration(hours: 2)), 'over an hour ago');
    });

    test('never reports a negative age', () {
      final fix = LocationFix(
        at: const LatLng(14.95, 120.9),
        takenAt: now.add(const Duration(seconds: 5)),
      );
      expect(fix.ageAt(now), Duration.zero);
      expect(fix.isStaleAt(now), isFalse);
    });
  });
}

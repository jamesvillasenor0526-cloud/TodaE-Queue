/// Tests for gliding markers between location readings.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:toda_equeue_plus/core/models/glide.dart';

const a = LatLng(14.9540, 120.9010);

/// [meters] north of [a].
LatLng north(double meters) =>
    LatLng(a.latitude + meters / 111320.0, a.longitude);

void main() {
  group('how long a glide takes', () {
    test('about the time since the last reading', () {
      // Arriving as the next reading does keeps the marker always moving.
      expect(
        glideDuration(
          from: a,
          to: north(15),
          sinceLastReading: const Duration(seconds: 3),
        ),
        const Duration(seconds: 3),
      );
    });

    test('never a snap, even when readings come close together', () {
      expect(
        glideDuration(
          from: a,
          to: north(2),
          sinceLastReading: const Duration(milliseconds: 50),
        ),
        kMinGlide,
      );
    });

    test('never a crawl after a long gap', () {
      expect(
        glideDuration(
          from: a,
          to: north(40),
          sinceLastReading: const Duration(minutes: 2),
        ),
        kMaxGlide,
      );
    });

    test('a big jump is jumped, not drawn as a journey', () {
      // GPS coming back after a tunnel or a dead phone: gliding would draw a
      // route through buildings that nobody drove.
      expect(
        glideDuration(
          from: a,
          to: north(500),
          sinceLastReading: const Duration(seconds: 3),
        ),
        Duration.zero,
      );
    });
  });

  group('the point along the way', () {
    test('starts at the old reading and ends at the new one', () {
      final b = north(20);
      expect(lerpLatLng(a, b, 0), a);
      expect(lerpLatLng(a, b, 1), b);
    });

    test('halfway is halfway', () {
      final mid = lerpLatLng(a, north(20), 0.5);
      expect(const Distance().as(LengthUnit.Meter, a, mid), closeTo(10, 0.5));
    });

    test('never overshoots the latest reading', () {
      // The marker may lag what is known; it must never run ahead of it.
      final b = north(20);
      expect(lerpLatLng(a, b, 1.7), b);
      expect(lerpLatLng(a, b, -0.3), a);
    });
  });
}

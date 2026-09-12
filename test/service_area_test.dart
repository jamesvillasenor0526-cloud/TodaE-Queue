/// Tests for the service area: what counts as out of town, what it costs,
/// and the terminals that sit on the boundary.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:toda_equeue_plus/core/models/service_area.dart';
import 'package:toda_equeue_plus/core/services/fare_service.dart';
import 'package:toda_equeue_plus/core/services/service_area_service.dart';

/// Baliwag's own outline, as bundled with the app.
final baliwag = ServiceArea.fromJson(
  File('assets/baliwag_boundary.json').readAsStringSync(),
);

const poblacion = LatLng(14.9540, 120.9010); // town centre
const market = LatLng(14.9526801, 120.9013686);

void main() {
  group('the outline the app actually loads', () {
    // Without the asset declared in pubspec.yaml this silently returns an
    // empty outline and every trip is charged as local, so it is worth
    // checking the app can read its own asset — not just the file on disk.
    testWidgets('comes from the bundled asset', (tester) async {
      final loaded = await ServiceAreaService.instance.load();
      expect(
        loaded.isUsable,
        isTrue,
        reason: 'is ${ServiceAreaService.assetPath} declared in pubspec.yaml?',
      );
      expect(loaded.contains(poblacion), isTrue);
    });
  });

  group('the bundled outline of Baliwag', () {
    test('loads and is usable', () {
      expect(baliwag.name, 'Baliwag');
      expect(baliwag.isUsable, isTrue);
      expect(baliwag.outline.length, greaterThan(100));
    });

    test('the town centre and the market are inside it', () {
      expect(baliwag.contains(poblacion), isTrue);
      expect(baliwag.contains(market), isTrue);
      expect(baliwag.metersOutside(poblacion), 0);
    });

    test('neighbouring towns are outside it', () {
      // Plaridel poblacion, Malolos, and Manila.
      expect(baliwag.contains(const LatLng(14.8869, 120.8556)), isFalse);
      expect(baliwag.contains(const LatLng(14.8433, 120.8114)), isFalse);
      expect(baliwag.contains(const LatLng(14.5995, 120.9842)), isFalse);
    });

    test('a broken or missing outline never makes a trip out of town', () {
      // A fare must not rise because an asset failed to load.
      final broken = ServiceArea.fromJson('{"name":"x"}');
      expect(broken.isUsable, isFalse);
      final result = outOfTownFor(
        area: broken,
        destination: const LatLng(14.5995, 120.9842), // Manila
        terminal: poblacion,
      );
      expect(result.outside, isFalse);
      expect(result.charged, isFalse);
      expect(result.kmOutside, 0);
    });
  });

  group('a trip within Baliwag', () {
    test('is never out of town', () {
      final result = outOfTownFor(
        area: baliwag,
        destination: market,
        terminal: poblacion,
      );
      expect(result.outside, isFalse);
      expect(result.charged, isFalse);
    });
  });

  group('a trip that crosses the boundary', () {
    test('close to the terminal is charged as local', () {
      // The houses immediately across the line from an edge terminal.
      const justOutside = LatLng(14.9067, 120.8790); // south edge, ~100 m out
      final result = outOfTownFor(
        area: baliwag,
        destination: justOutside,
        terminal: justOutside, // the terminal is right there
      );
      expect(result.charged, isFalse, reason: 'within 2 km of the terminal');
    });

    test('far from the terminal is charged', () {
      const malolos = LatLng(14.8433, 120.8114);
      final result = outOfTownFor(
        area: baliwag,
        destination: malolos,
        terminal: poblacion,
      );
      expect(result.outside, isTrue);
      expect(result.charged, isTrue);
      expect(result.kmOutside, greaterThan(1));
      expect(result.metersFromTerminal, greaterThan(kLocalNearTerminalMeters));
    });

    test('the boundary decides how much is charged, not the whole trip', () {
      // A place just beyond the line adds little; one far beyond adds more.
      final near = outOfTownFor(
        area: baliwag,
        destination: const LatLng(14.8869, 120.8556), // Plaridel poblacion
        terminal: poblacion,
      );
      final far = outOfTownFor(
        area: baliwag,
        destination: const LatLng(14.5995, 120.9842), // Manila
        terminal: poblacion,
      );
      expect(near.kmOutside, lessThan(far.kmOutside));
    });
  });

  group('what it adds to the fare', () {
    final fare = FareService.instance;

    test('nothing for a trip inside town', () {
      expect(fare.outOfTownExtra(0), 0);
      expect(fare.fareWithReturn(distanceInKm: 3), 55);
    });

    test('the kilometres outside are charged a second time', () {
      // 3 km out of town: ₱10/km again for the driver's return.
      expect(fare.outOfTownExtra(3), 30);
      // A 6 km trip (₱85) with 3 km beyond the line: ₱85 + ₱30.
      expect(fare.fareWithReturn(distanceInKm: 6, kmOutside: 3), 115);
    });

    test('a negative or silly value adds nothing', () {
      expect(fare.outOfTownExtra(-5), 0);
    });
  });
}

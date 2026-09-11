/// Tests for merging what each part of the app needs from the one GPS stream.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:toda_equeue_plus/core/models/location_need.dart';

const home = LocationNeed(interval: Duration(seconds: 2), distanceFilter: 3);
const navigation = LocationNeed(
  interval: Duration(seconds: 1),
  distanceFilter: 2,
  accuracy: LocationAccuracy.bestForNavigation,
);

void main() {
  test('navigation gets its reading a second even when home asked first', () {
    // The recorded drive: home's request came first and navigation's was
    // ignored, so the arrow stepped every 5 s.
    final merged = LocationNeed.merge([home, navigation]);
    expect(merged.interval, const Duration(seconds: 1));
    expect(merged.distanceFilter, 2);
    expect(merged.accuracy, LocationAccuracy.bestForNavigation);
  });

  test('order does not matter', () {
    expect(
      LocationNeed.merge([home, navigation]),
      LocationNeed.merge([navigation, home]),
    );
  });

  test('when navigation ends, the stream relaxes to what is left', () {
    expect(LocationNeed.merge([home]), home);
  });

  test('the finest of each setting, even from different parts', () {
    const reports = LocationNeed(
      interval: Duration(seconds: 1),
      distanceFilter: 0,
      accuracy: LocationAccuracy.high,
    );
    final merged = LocationNeed.merge([home, reports]);
    expect(merged.interval, const Duration(seconds: 1));
    expect(merged.distanceFilter, 0);
    expect(merged.accuracy, LocationAccuracy.high);
  });

  test('approximate location never wins over a precise one', () {
    const rough = LocationNeed(
      interval: Duration(seconds: 10),
      distanceFilter: 50,
      accuracy: LocationAccuracy.reduced,
    );
    expect(LocationNeed.merge([rough, home]).accuracy, LocationAccuracy.high);
  });
}

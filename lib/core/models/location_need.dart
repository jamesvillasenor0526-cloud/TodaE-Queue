/// How often, how finely and how accurately one part of the app needs the
/// phone's location — and the one setting that satisfies everyone at once.
///
/// The location plugin runs a single stream per app and ignores the settings
/// of every request after the first. The driver home screen asked first, for
/// Android's default of a reading every 5 s, so navigation — which asked for
/// one a second — got one every 5 s too: the arrow moved in 5-second steps
/// on a real drive (0:04.8, 0:09.9, 0:14.9… in the recording). Every part of
/// the app now states its need, and the one shared stream runs at the finest
/// of them, changing as needs come and go.
///
/// Pure, so the merging is tested without a device.
library;

import 'package:geolocator/geolocator.dart';

class LocationNeed {
  const LocationNeed({
    required this.interval,
    required this.distanceFilter,
    this.accuracy = LocationAccuracy.high,
  });

  /// At least this often, while moving.
  final Duration interval;

  /// After at least this many metres of movement.
  final int distanceFilter;
  final LocationAccuracy accuracy;

  /// The finest of [needs]: the shortest interval, the smallest distance and
  /// the best accuracy any of them asks for. Everyone gets every reading;
  /// anyone wanting fewer throttles for themselves.
  static LocationNeed merge(Iterable<LocationNeed> needs) {
    final list = needs.toList();
    if (list.isEmpty) {
      throw ArgumentError('Nothing to merge: no part of the app needs GPS.');
    }
    return LocationNeed(
      interval: list.map((n) => n.interval).reduce((a, b) => a < b ? a : b),
      distanceFilter: list
          .map((n) => n.distanceFilter)
          .reduce((a, b) => a < b ? a : b),
      accuracy: list
          .map((n) => n.accuracy)
          .reduce((a, b) => _rank(a) >= _rank(b) ? a : b),
    );
  }

  /// Better accuracy ranks higher. `reduced` is iOS's approximate location,
  /// the coarsest of all.
  static int _rank(LocationAccuracy a) => switch (a) {
    LocationAccuracy.reduced => 0,
    LocationAccuracy.lowest => 1,
    LocationAccuracy.low => 2,
    LocationAccuracy.medium => 3,
    LocationAccuracy.high => 4,
    LocationAccuracy.best => 5,
    LocationAccuracy.bestForNavigation => 6,
  };

  @override
  bool operator ==(Object other) =>
      other is LocationNeed &&
      other.interval == interval &&
      other.distanceFilter == distanceFilter &&
      other.accuracy == accuracy;

  @override
  int get hashCode => Object.hash(interval, distanceFilter, accuracy);

  @override
  String toString() =>
      'LocationNeed(${interval.inMilliseconds} ms, $distanceFilter m, '
      '${accuracy.name})';
}

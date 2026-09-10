/// A position reading and when it was taken.
///
/// Kept separate from the location plugin so the freshness rules can be
/// tested without a device.
library;

import 'package:latlong2/latlong.dart';

/// Older than this, a reading is not trusted to be where the driver is now.
///
/// A tricycle at 20 km/h covers about 55 m in ten seconds — around the width
/// of the stretch a report is snapped to. Much older and the report can land
/// on a different road.
const Duration kMaxFixAge = Duration(seconds: 10);

class LocationFix {
  final LatLng at;
  final DateTime takenAt;

  const LocationFix({required this.at, required this.takenAt});

  Duration ageAt(DateTime now) {
    final age = now.difference(takenAt);
    // A device clock slightly ahead of the fix's can make this negative.
    return age.isNegative ? Duration.zero : age;
  }

  bool isStaleAt(DateTime now) => isStaleFix(takenAt, now);
}

/// Whether a reading taken at [takenAt] is too old to report from at [now].
bool isStaleFix(DateTime takenAt, DateTime now, {Duration maxAge = kMaxFixAge}) =>
    now.difference(takenAt) > maxAge;

/// "just now", "40 s ago", "3 min ago" — how old the location is, for a
/// driver deciding whether to trust it.
String fixAgeLabel(Duration age) {
  if (age < const Duration(seconds: 15)) return 'just now';
  if (age < const Duration(minutes: 1)) return '${age.inSeconds} s ago';
  if (age < const Duration(hours: 1)) return '${age.inMinutes} min ago';
  return 'over an hour ago';
}

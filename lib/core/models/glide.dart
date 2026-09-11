/// Moving a marker smoothly from one location reading to the next.
///
/// A phone reports where it is every few seconds. Drawn as-is, the marker
/// jumps between readings — the passenger's tricycle hopped ten or twenty
/// metres at a time. Glided over about the gap between readings instead, it
/// arrives as the next reading does: always moving, never more than one
/// reading behind, and never ahead of what is actually known. Nothing is
/// predicted; the marker only travels between two real positions.
///
/// Pure, so the rules are tested without a device.
library;

import 'package:latlong2/latlong.dart';

/// The shortest glide. Readings closer together than this still move the
/// marker smoothly rather than in a snap.
const Duration kMinGlide = Duration(milliseconds: 300);

/// The longest glide. After a long gap the marker should not crawl for half
/// a minute toward a position that is already old.
const Duration kMaxGlide = Duration(seconds: 4);

/// Beyond this a new reading is jumped to, not glided to. A jump that big is
/// GPS returning after a gap or a first fix, not movement, and gliding it
/// would draw a journey through buildings that never happened.
const double kMaxGlideMeters = 300;

/// A driver's reading older than this is flagged: their phone has stopped
/// reporting — no signal, app closed, or the phone is off.
const Duration kDriverLocationStale = Duration(minutes: 1);

/// How long to take moving from [from] to [to], given that the previous
/// reading arrived [sinceLastReading] ago. Zero means jump.
Duration glideDuration({
  required LatLng from,
  required LatLng to,
  required Duration sinceLastReading,
}) {
  if (const Distance().as(LengthUnit.Meter, from, to) > kMaxGlideMeters) {
    return Duration.zero;
  }
  if (sinceLastReading < kMinGlide) return kMinGlide;
  if (sinceLastReading > kMaxGlide) return kMaxGlide;
  return sinceLastReading;
}

/// The point [t] of the way from [a] to [b]. Straight-line interpolation is
/// right at these distances: a few metres to a few tens of metres.
LatLng lerpLatLng(LatLng a, LatLng b, double t) {
  final k = t.clamp(0.0, 1.0);
  return LatLng(
    a.latitude + (b.latitude - a.latitude) * k,
    a.longitude + (b.longitude - a.longitude) * k,
  );
}

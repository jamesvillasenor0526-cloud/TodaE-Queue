/// Where the app serves, and what a trip out of town costs.
///
/// Trips are meant to stay in Baliwag: a passenger could book a tricycle to
/// the next province at the town fare, and a driver would come back empty
/// for nothing. Out-of-town trips are still allowed, but the part of the
/// ride beyond the town boundary is charged twice — once as distance, once
/// for the driver's return.
///
/// The boundary is not the whole story. Several terminals sit right at the
/// edge of Baliwag — Sto. Cristo, Tarcan, Subic, Sabang — and the nearest
/// houses and shops across the line belong to Plaridel, Bustos, Pulilan or
/// San Rafael. A one-kilometre ride that happens to cross the boundary is an
/// ordinary short trip, so anything within [kLocalNearTerminalMeters] of the
/// terminal the trip starts from is charged as local.
///
/// Pure. The outline itself is Baliwag's own, from OpenStreetMap, bundled
/// with the app (assets/baliwag_boundary.json) so this works offline.
library;

import 'dart:convert';

import 'package:latlong2/latlong.dart';

import 'boundary.dart';

/// Outside the town but within this distance of the starting terminal is
/// still a local trip.
const double kLocalNearTerminalMeters = 2000;

/// The mapped outline of the area served.
class ServiceArea {
  final String name;
  final List<LatLng> outline;

  const ServiceArea({required this.name, required this.outline});

  bool get isUsable => outline.length >= 3;

  bool contains(LatLng point) => insideBoundary(point, outline);

  /// How far [point] is beyond the outline; zero inside it.
  double metersOutside(LatLng point) => metersOutsideBoundary(point, outline);

  /// Reads the bundled outline: `{"name": …, "polygon": [[lat, lng], …]}`.
  static ServiceArea fromJson(String body) {
    final decoded = json.decode(body);
    if (decoded is! Map) return const ServiceArea(name: '', outline: []);
    final raw = decoded['polygon'];
    final points = <LatLng>[];
    if (raw is List) {
      for (final pair in raw) {
        if (pair is! List || pair.length < 2) continue;
        final lat = (pair[0] as num?)?.toDouble();
        final lng = (pair[1] as num?)?.toDouble();
        if (lat == null || lng == null) continue;
        if (!lat.isFinite || !lng.isFinite) continue;
        points.add(LatLng(lat, lng));
      }
    }
    return ServiceArea(
      name: (decoded['name'] as String?) ?? 'Service area',
      outline: points,
    );
  }
}

/// What an out-of-town trip adds to the fare, and why.
class OutOfTown {
  /// Beyond the service area at all.
  final bool outside;

  /// …and far enough from the starting terminal to be charged for.
  final bool charged;

  /// Road kilometres reckoned to be beyond the boundary.
  final double kmOutside;

  /// How far the destination is from the terminal the trip starts at.
  final double metersFromTerminal;

  const OutOfTown({
    required this.outside,
    required this.charged,
    required this.kmOutside,
    required this.metersFromTerminal,
  });

  static const OutOfTown none = OutOfTown(
    outside: false,
    charged: false,
    kmOutside: 0,
    metersFromTerminal: 0,
  );
}

/// How far a road runs for a given straight-line distance in town. Streets
/// wind, so the crow-flies gap under-states the ride.
const double kOutOfTownWindingFactor = 1.3;

/// Whether [destination] counts as an out-of-town trip from [terminal], and
/// how much of it lies beyond the boundary.
///
/// [area] being unusable — a missing or broken outline — means no trip is
/// ever treated as out of town: a fare must not rise because an asset
/// failed to load.
OutOfTown outOfTownFor({
  required ServiceArea area,
  required LatLng destination,
  required LatLng terminal,
}) {
  if (!area.isUsable) return OutOfTown.none;
  final metersOutside = area.metersOutside(destination);
  if (metersOutside == 0) return OutOfTown.none;

  final fromTerminal = const Distance().as(
    LengthUnit.Meter,
    terminal,
    destination,
  );
  final kmOutside = (metersOutside / 1000) * kOutOfTownWindingFactor;
  return OutOfTown(
    outside: true,
    charged: fromTerminal > kLocalNearTerminalMeters,
    kmOutside: double.parse(kmOutside.toStringAsFixed(3)),
    metersFromTerminal: fromTerminal,
  );
}

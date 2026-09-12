/// Places a passenger can search for when setting a pick-up or destination.
///
/// Until now both map pickers only took a tap: to send a tricycle to the
/// market, or to a Jollibee branch, the passenger had to know where it was
/// on the map and find it by panning.
///
/// Results come from OpenStreetMap's search (Nominatim), the same map the
/// app draws. They are biased towards Bulacan and then ordered by how close
/// they are to where the passenger is looking, because a search for "sto
/// nino" should offer the barangay up the road before the one in Marikina.
///
/// Pure — parsing and ordering are tested against a real saved response.
library;

import 'dart:convert';

import 'package:latlong2/latlong.dart';

/// One place someone can pick.
class PlaceHit {
  /// What it is called: "Baliwag Public Market", "Jollibee".
  final String name;

  /// Where it is, in words: "Poblacion, Baliwag, Bulacan".
  final String where;
  final LatLng at;

  const PlaceHit({required this.name, required this.where, required this.at});

  @override
  bool operator ==(Object other) =>
      other is PlaceHit &&
      other.name == name &&
      other.where == where &&
      other.at == at;

  @override
  int get hashCode => Object.hash(name, where, at);

  @override
  String toString() => '$name ($where)';
}

/// The box searched in: Bulacan and its surroundings, as
/// `left,top,right,bottom` for Nominatim's viewbox.
const String kSearchViewbox = '120.70,15.15,121.10,14.75';

/// Shortest sensible query. One or two letters match half the country and
/// would spend the search allowance on nothing useful.
const int kMinQueryLength = 3;

/// Places from a Nominatim search response.
///
/// A place with no usable coordinates is dropped rather than offered as
/// something that cannot be picked.
List<PlaceHit> parsePlaceSearch(String body) {
  final decoded = json.decode(body);
  if (decoded is! List) return const [];
  final out = <PlaceHit>[];
  for (final raw in decoded) {
    if (raw is! Map) continue;
    final lat = double.tryParse('${raw['lat']}');
    final lng = double.tryParse('${raw['lon']}');
    if (lat == null || lng == null) continue;
    if (!lat.isFinite || !lng.isFinite) continue;

    final display = (raw['display_name'] as String?)?.trim() ?? '';
    final parts = display
        .split(',')
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    final named = (raw['name'] as String?)?.trim();
    final name = (named == null || named.isEmpty)
        ? (parts.isEmpty ? 'Place' : parts.first)
        : named;
    // The rest of the address, minus the country and any postcode, and
    // minus a first part that only repeats the name.
    final rest = [
      for (final p in parts.skip(
        parts.isNotEmpty && parts.first == name ? 1 : 0,
      ))
        if (p != 'Philippines' && !RegExp(r'^\d{4}$').hasMatch(p)) p,
    ];
    out.add(
      PlaceHit(
        name: name,
        where: rest.take(3).join(', '),
        at: LatLng(lat, lng),
      ),
    );
  }
  return out;
}

/// Places from a TomTom search response.
///
/// TomTom knows local businesses by name — "Jollibee Baliuag Junction", "SM
/// City Baliuag" — which is what a passenger searches for. Its search needs
/// `view=Unified` passed explicitly: this project's key carries an invalid
/// default view ('PH'), which made every search fail until it was given one.
List<PlaceHit> parseTomTomPlaces(String body) {
  final decoded = json.decode(body);
  if (decoded is! Map || decoded['results'] is! List) return const [];
  final out = <PlaceHit>[];
  for (final raw in decoded['results'] as List) {
    if (raw is! Map) continue;
    final position = raw['position'];
    if (position is! Map) continue;
    final lat = (position['lat'] as num?)?.toDouble();
    final lng = (position['lon'] as num?)?.toDouble();
    if (lat == null || lng == null || !lat.isFinite || !lng.isFinite) continue;

    final address = raw['address'] is Map
        ? (raw['address'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final full = (address['freeformAddress'] as String?)?.trim() ?? '';
    // The postcode is noise to someone picking a place off a map.
    final parts = [
      for (final p in full.split(','))
        if (p.trim().isNotEmpty && !RegExp(r'^\d{4}$').hasMatch(p.trim()))
          p.trim(),
    ];

    final poi = raw['poi'] is Map
        ? (raw['poi'] as Map)['name'] as String?
        : null;
    final name = (poi != null && poi.trim().isNotEmpty)
        ? poi.trim()
        : (address['streetName'] as String?)?.trim() ??
              (parts.isEmpty ? 'Place' : parts.first);
    final rest = parts.where((p) => p != name).take(3).join(', ');
    out.add(PlaceHit(name: name, where: rest, at: LatLng(lat, lng)));
  }
  return out;
}

/// [hits] with the places nearest [near] first.
///
/// Nominatim orders by how well known a place is, so without this a search
/// for a barangay name offers the famous one in Metro Manila before the one
/// a kilometre away.
List<PlaceHit> nearestFirst(List<PlaceHit> hits, LatLng near) {
  const distance = Distance();
  final sorted = [...hits];
  sorted.sort(
    (a, b) => distance
        .as(LengthUnit.Meter, near, a.at)
        .compareTo(distance.as(LengthUnit.Meter, near, b.at)),
  );
  return sorted;
}

/// Whether [query] is worth searching for.
bool worthSearching(String query) => query.trim().length >= kMinQueryLength;

/// When the best place found is this far from where the passenger is
/// looking, the other map's search is worth asking as well.
///
/// TomTom is strong on businesses but answered "sto nino" with shops 15 km
/// away, while OpenStreetMap knew the barangay up the road.
const double kFarResultMeters = 8000;

/// How far the nearest of [hits] is from [near]; infinite when there are
/// none.
double nearestMeters(List<PlaceHit> hits, LatLng near) {
  const distance = Distance();
  var best = double.infinity;
  for (final hit in hits) {
    final d = distance.as(LengthUnit.Meter, near, hit.at);
    if (d < best) best = d;
  }
  return best;
}

/// [first] then [second], without offering the same place twice.
///
/// The two maps name things differently, so sameness is judged by position
/// — within about 25 m — rather than by name.
List<PlaceHit> mergePlaces(List<PlaceHit> first, List<PlaceHit> second) {
  const distance = Distance();
  final out = [...first];
  for (final candidate in second) {
    final already = out.any(
      (kept) => distance.as(LengthUnit.Meter, kept.at, candidate.at) < 25,
    );
    if (!already) out.add(candidate);
  }
  return out;
}

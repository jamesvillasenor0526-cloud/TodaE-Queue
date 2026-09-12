/// Tests for searching places on the pick-up and destination maps, against
/// a real saved OpenStreetMap search response.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:toda_equeue_plus/core/models/place_search.dart';

String get _jollibee =>
    File('test/fixtures/nominatim_search_jollibee.json').readAsStringSync();

String get _tomTomJollibee =>
    File('test/fixtures/tomtom_search_jollibee.json').readAsStringSync();

void main() {
  group('reading a real TomTom search for "jollibee baliwag"', () {
    test('local branches come back by name', () {
      final hits = parseTomTomPlaces(_tomTomJollibee);
      expect(hits, hasLength(greaterThanOrEqualTo(3)));
      expect(hits.first.name, 'Jollibee Baliuag Bayan');
      expect(hits.map((h) => h.name), contains('Jollibee SM City Baliuag'));
      expect(hits.first.at.latitude, closeTo(14.95, 0.1));
    });

    test('the address says where it is, without the postcode', () {
      final hits = parseTomTomPlaces(_tomTomJollibee);
      expect(hits.first.where, contains('Baliwag'));
      for (final hit in hits) {
        expect(hit.where, isNot(matches(RegExp(r'\b\d{4}\b'))));
        expect(hit.where, isNot(contains(hit.name)));
      }
    });

    test('a broken answer gives no places rather than throwing', () {
      expect(parseTomTomPlaces('{"errorText":"not a valid view"}'), isEmpty);
      expect(parseTomTomPlaces('{"results":[]}'), isEmpty);
      expect(
        parseTomTomPlaces('{"results":[{"poi":{"name":"No position"}}]}'),
        isEmpty,
      );
    });
  });

  group('reading a real search for "jollibee baliwag"', () {
    test('every branch comes back with a name and a place', () {
      final hits = parsePlaceSearch(_jollibee);
      expect(hits, hasLength(5));
      expect(hits.first.name, 'Jollibee');
      expect(hits.first.where, isNotEmpty);
      // Somewhere in Baliwag, not on the other side of the world.
      expect(hits.first.at.latitude, closeTo(14.95, 0.1));
      expect(hits.first.at.longitude, closeTo(120.9, 0.2));
    });

    test('the country and postcode are left out of the address', () {
      for (final hit in parsePlaceSearch(_jollibee)) {
        expect(hit.where, isNot(contains('Philippines')));
        expect(hit.where, isNot(matches(RegExp(r'\b\d{4}\b'))));
      }
    });

    test('the address does not simply repeat the name', () {
      for (final hit in parsePlaceSearch(_jollibee)) {
        expect(hit.where.startsWith('${hit.name},'), isFalse);
        expect(hit.where, isNot(hit.name));
      }
    });
  });

  group('ordering', () {
    const market = PlaceHit(
      name: 'Baliwag Public Market',
      where: 'Poblacion, Baliwag',
      at: LatLng(14.9526801, 120.9013686),
    );
    const marikina = PlaceHit(
      name: 'Santo Niño',
      where: 'Marikina',
      at: LatLng(14.6400567, 121.0968384),
    );
    const nearby = PlaceHit(
      name: 'Santo Niño',
      where: 'Baliwag, Bulacan',
      at: LatLng(14.9681746, 120.8961868),
    );

    test('the nearest place comes first', () {
      // A search for a barangay name used to offer the famous one in Metro
      // Manila first, because the map service ranks by fame.
      final ordered = nearestFirst([
        marikina,
        nearby,
        market,
      ], const LatLng(14.954, 120.901));
      expect(ordered.first, market);
      expect(ordered[1], nearby);
      expect(ordered.last, marikina);
    });

    test('ordering nothing is not an error', () {
      expect(nearestFirst(const [], const LatLng(14.954, 120.901)), isEmpty);
    });
  });

  group('asking both maps', () {
    const near = LatLng(14.954, 120.901);
    const close = PlaceHit(
      name: 'SM City Baliwag',
      where: 'Concepcion, Baliwag',
      at: LatLng(14.95976, 120.89091),
    );
    const far = PlaceHit(
      name: 'PNB Malolos City-Sto Nino',
      where: 'Malolos City',
      at: LatLng(14.84, 120.81),
    );

    test('a nearby answer is enough on its own', () {
      expect(nearestMeters(const [close], near), lessThan(kFarResultMeters));
    });

    test('only far answers means the other map is worth asking', () {
      // "sto nino" came back from one map as shops 15 km away.
      expect(nearestMeters(const [far], near), greaterThan(kFarResultMeters));
      expect(nearestMeters(const [], near), double.infinity);
    });

    test('merging keeps both maps but not the same place twice', () {
      const alsoSm = PlaceHit(
        name: 'SM City Baliuag',
        where: 'Baliwag, Bulacan',
        at: LatLng(14.95977, 120.89092), // metres away, same mall
      );
      const barangay = PlaceHit(
        name: 'Santo Niño',
        where: 'Baliwag, Bulacan',
        at: LatLng(14.968, 120.896),
      );
      final merged = mergePlaces(const [close], const [alsoSm, barangay]);
      expect(merged.map((p) => p.name), ['SM City Baliwag', 'Santo Niño']);
    });
  });

  group('what is worth searching', () {
    test('one or two letters are not', () {
      expect(worthSearching('j'), isFalse);
      expect(worthSearching('jo'), isFalse);
      expect(worthSearching('  '), isFalse);
      expect(worthSearching('jol'), isTrue);
      expect(worthSearching('  market '), isTrue);
    });
  });

  group('bad answers do not break the search', () {
    test('an error object, or nonsense, gives no places', () {
      expect(parsePlaceSearch('{"error":"Unable to geocode"}'), isEmpty);
      expect(parsePlaceSearch('[]'), isEmpty);
    });

    test('an entry without usable coordinates is dropped', () {
      const body = '''
      [{"lat":"abc","lon":"120.9","display_name":"Broken, Baliwag"},
       {"lat":"14.95","lon":"120.90","name":"Good","display_name":"Good, Baliwag, Bulacan, Philippines"}]
      ''';
      final hits = parsePlaceSearch(body);
      expect(hits, hasLength(1));
      expect(hits.single.name, 'Good');
      expect(hits.single.where, 'Baliwag, Bulacan');
    });
  });
}

/// Tests for searching places on the pick-up and destination maps, against
/// a real saved OpenStreetMap search response.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:toda_equeue_plus/core/models/place_search.dart';

String get _jollibee =>
    File('test/fixtures/nominatim_search_jollibee.json').readAsStringSync();

void main() {
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

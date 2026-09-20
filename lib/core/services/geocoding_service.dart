import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../../config/api_keys.dart';
import '../models/place_search.dart';
import 'tomtom_router.dart';

class GeocodingService {
  static final GeocodingService instance = GeocodingService._();
  GeocodingService._();

  /// OpenStreetMap's search — the fallback — allows about one request a
  /// second, so those are queued a second apart. TomTom needs no queue.
  /// Either way each answer is remembered, so the same query is not asked
  /// twice.
  static const Duration _searchGap = Duration(milliseconds: 1100);
  final Map<String, List<PlaceHit>> _searched = {};
  DateTime _nextOsmSearch = DateTime.fromMillisecondsSinceEpoch(0);

  /// Places matching [query], nearest [near] first. Empty when there is
  /// nothing to search for, nothing found, or no search can be reached.
  ///
  /// TomTom first: it knows local businesses by name, which is what a
  /// passenger types. OpenStreetMap answers when TomTom has no key, fails,
  /// or finds nothing — it is stronger on barangays and small landmarks.
  Future<List<PlaceHit>> searchPlaces(
    String query, {
    required LatLng near,
  }) async {
    final trimmed = query.trim();
    if (!worthSearching(trimmed)) return const [];
    final key = trimmed.toLowerCase();
    final remembered = _searched[key];
    if (remembered != null) return nearestFirst(remembered, near);

    var hits = await _searchTomTom(trimmed, near);
    // Ask the other map too when TomTom found nothing, or nothing nearby:
    // it is the one that knows barangays and small landmarks.
    if (nearestMeters(hits, near) > kFarResultMeters) {
      hits = mergePlaces(hits, await _searchOpenStreetMap(trimmed));
    }
    if (hits.isEmpty) return const [];

    if (_searched.length > 60) _searched.clear();
    _searched[key] = hits;
    return nearestFirst(hits, near);
  }

  Future<List<PlaceHit>> _searchTomTom(String query, LatLng near) async {
    if (!TomTomRouter.isConfigured) return const [];
    final uri = Uri.https(
      'api.tomtom.com',
      '/search/2/search/${Uri.encodeComponent(query)}.json',
      {
        'key': ApiKeys.tomTom,
        // Must be given: this key carries a default geopolitical view of
        // 'PH', which TomTom itself rejects as invalid, so every search
        // failed with "'PH' is not a valid view" until one was passed.
        'view': 'Unified',
        'limit': '6',
        // Around where the passenger is looking, not the whole country.
        'lat': '${near.latitude}',
        'lon': '${near.longitude}',
        'radius': '40000',
        'typeahead': 'true',
      },
    );
    try {
      final response = await http.get(uri).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) {
        debugPrint('TomTom place search returned ${response.statusCode}');
        return const [];
      }
      return parseTomTomPlaces(response.body);
    } catch (e) {
      debugPrint('TomTom place search unavailable: $e');
      return const [];
    }
  }

  Future<List<PlaceHit>> _searchOpenStreetMap(String query) async {
    final wait = _nextOsmSearch.difference(DateTime.now());
    _nextOsmSearch = DateTime.now().add(
      wait.isNegative ? _searchGap : wait + _searchGap,
    );
    if (!wait.isNegative) await Future<void>.delayed(wait);

    final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
      'format': 'jsonv2',
      'q': query,
      'limit': '6',
      'countrycodes': 'ph',
      // A bias, not a fence: a hard boundary hid places whose records sit
      // just outside it, such as "sto nino".
      'viewbox': kSearchViewbox,
      'addressdetails': '1',
    });

    try {
      final response = await http
          .get(uri, headers: const {'User-Agent': 'TODA-EQueue/1.0'})
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) {
        debugPrint('Place search returned ${response.statusCode}');
        return const [];
      }
      return parsePlaceSearch(response.body);
    } catch (e) {
      debugPrint('Place search unavailable: $e');
      return const [];
    }
  }

  Future<String> getPlaceName(double lat, double lng) async {
    try {
      final url =
          'https://nominatim.openstreetmap.org/reverse'
          '?lat=$lat&lon=$lng&format=json';

      debugPrint('Fetching place name for: $lat, $lng');

      // Timed out rather than left open: a reverse lookup that never
      // returns leaves "Loading..." as a place name for the whole trip.
      final response = await http
          .get(Uri.parse(url), headers: {'User-Agent': 'TODA-EQueue/1.0'})
          .timeout(const Duration(seconds: 8));

      debugPrint('Response status: ${response.statusCode}');

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        debugPrint('Response data: ${data['display_name']}');

        final displayName = data['display_name'] as String?;
        if (displayName != null) {
          final parts = displayName.split(',');
          return parts.take(3).join(',').trim();
        }
      }
    } catch (e) {
      debugPrint('Nominatim error: $e');
    }
    return 'Location';
  }
}

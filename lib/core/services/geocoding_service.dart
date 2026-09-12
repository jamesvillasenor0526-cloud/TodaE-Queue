import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../models/place_search.dart';

class GeocodingService {
  static final GeocodingService instance = GeocodingService._();
  GeocodingService._();

  /// OpenStreetMap's search allows about one request a second and asks that
  /// answers be reused, so searches queue a second apart and each query is
  /// remembered. TomTom's search would need no queue, but this project's key
  /// is refused by their search endpoints (an account "view" setting), while
  /// their routing works — so the map's own search is used.
  static const Duration _searchGap = Duration(milliseconds: 1100);
  final Map<String, List<PlaceHit>> _searched = {};
  DateTime _nextSearch = DateTime.fromMillisecondsSinceEpoch(0);

  /// Places matching [query], nearest [near] first. Empty when there is
  /// nothing to search for, nothing found, or the search cannot be reached.
  Future<List<PlaceHit>> searchPlaces(
    String query, {
    required LatLng near,
  }) async {
    final trimmed = query.trim();
    if (!worthSearching(trimmed)) return const [];
    final key = trimmed.toLowerCase();
    final remembered = _searched[key];
    if (remembered != null) return nearestFirst(remembered, near);

    final wait = _nextSearch.difference(DateTime.now());
    _nextSearch = DateTime.now().add(
      wait.isNegative ? _searchGap : wait + _searchGap,
    );
    if (!wait.isNegative) await Future<void>.delayed(wait);

    final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
      'format': 'jsonv2',
      'q': trimmed,
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
      final hits = parsePlaceSearch(response.body);
      if (_searched.length > 60) _searched.clear();
      _searched[key] = hits;
      return nearestFirst(hits, near);
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

      debugPrint('🔍 Fetching place name for: $lat, $lng');

      final response = await http.get(
        Uri.parse(url),
        headers: {'User-Agent': 'TODA-EQueue/1.0'},
      );

      debugPrint('🔍 Response status: ${response.statusCode}');

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        debugPrint('🔍 Response data: ${data['display_name']}');

        final displayName = data['display_name'] as String?;
        if (displayName != null) {
          final parts = displayName.split(',');
          return parts.take(3).join(',').trim();
        }
      }
    } catch (e) {
      debugPrint('❌ Nominatim error: $e');
    }
    return 'Location';
  }
}

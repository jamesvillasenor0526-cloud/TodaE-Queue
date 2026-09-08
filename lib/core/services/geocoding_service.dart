import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class GeocodingService {
  static final GeocodingService instance = GeocodingService._();
  GeocodingService._();

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

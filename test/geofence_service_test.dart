import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:toda_equeue_plus/core/services/geofence_service.dart';

void main() {
  final geofenceService = GeofenceService.instance;

  final square = [
    const LatLng(14.9500, 120.9000),
    const LatLng(14.9500, 120.9100),
    const LatLng(14.9600, 120.9100),
    const LatLng(14.9600, 120.9000),
  ];

  group('isPointInPolygon', () {
    test('returns true for a point inside the boundary', () {
      const inside = LatLng(14.9550, 120.9050);
      expect(geofenceService.isPointInPolygon(inside, square), isTrue);
    });

    test('returns false for a point outside the boundary', () {
      const outside = LatLng(14.9700, 120.9200);
      expect(geofenceService.isPointInPolygon(outside, square), isFalse);
    });

    test('returns false when the polygon has fewer than 3 points', () {
      const point = LatLng(14.9550, 120.9050);
      final degenerate = [square[0], square[1]];
      expect(geofenceService.isPointInPolygon(point, degenerate), isFalse);
    });
  });
}

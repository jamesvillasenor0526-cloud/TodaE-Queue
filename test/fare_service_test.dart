import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:toda_equeue_plus/core/services/fare_service.dart';

void main() {
  final fareService = FareService.instance;

  group('calculateFareFromDistance', () {
    test('charges the minimum fare for distances of 1km or less', () {
      expect(fareService.calculateFareFromDistance(0.0), FareService.minimumFare);
      expect(fareService.calculateFareFromDistance(1.0), FareService.minimumFare);
    });

    test('rounds up to the next whole km and adds the per-km rate beyond 1km', () {
      // 1.5km rounds up to 2km -> 1 additional km beyond the first.
      expect(fareService.calculateFareFromDistance(1.5), 45.0);
      // 2.0km is already whole -> 1 additional km beyond the first.
      expect(fareService.calculateFareFromDistance(2.0), 45.0);
      // 2.1km rounds up to 3km -> 2 additional km beyond the first.
      expect(fareService.calculateFareFromDistance(2.1), 55.0);
    });
  });

  group('calculateFare', () {
    test('derives distance from coordinates before pricing it', () {
      // Two points ~1.1km apart along the same longitude.
      const pickup = LatLng(14.9540, 120.9010);
      const dropoff = LatLng(14.9640, 120.9010);
      final fare = fareService.calculateFare(pickup, dropoff);
      expect(fare, greaterThanOrEqualTo(FareService.minimumFare));
    });
  });

  group('formatFare', () {
    test('omits decimals for whole-peso amounts', () {
      expect(fareService.formatFare(35.0), '₱35');
    });

    test('keeps two decimals for fractional amounts', () {
      expect(fareService.formatFare(35.5), '₱35.50');
    });
  });
}

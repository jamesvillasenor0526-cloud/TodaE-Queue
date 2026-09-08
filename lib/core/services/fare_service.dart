import 'package:latlong2/latlong.dart';

class FareService {
  static final FareService instance = FareService._();
  FareService._();

  static const double minimumFare = 35.0;
  static const double ratePerKm = 10.0;
  static const double pickupFee = 15.0;

  double calculateFare(LatLng pickup, LatLng dropoff) {
    final distanceInKm = calculateDistance(pickup, dropoff);
    return calculateFareFromDistance(distanceInKm);
  }

  double calculateFareFromDistance(double distanceInKm) {
    if (distanceInKm <= 1.0) {
      return minimumFare;
    }

    // Round up to next whole km
    final roundedKm = distanceInKm.ceilToDouble();
    final additionalKm = roundedKm - 1.0;
    final fare = minimumFare + (additionalKm * ratePerKm);

    return double.parse(fare.toStringAsFixed(2));
  }

  double calculateDistance(LatLng pickup, LatLng dropoff) {
    return const Distance().as(LengthUnit.Kilometer, pickup, dropoff);
  }

  String formatFare(double fare) {
    if (fare == fare.roundToDouble()) {
      return '₱${fare.toStringAsFixed(0)}';
    }
    return '₱${fare.toStringAsFixed(2)}';
  }
}

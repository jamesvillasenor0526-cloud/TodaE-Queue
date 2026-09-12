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

  /// What an out-of-town trip adds: the kilometres beyond the town boundary
  /// charged a second time, for the driver's empty return. Those kilometres
  /// are already in the trip's distance, so adding [ratePerKm] once more
  /// makes them double rate.
  double outOfTownExtra(double kmOutside) {
    if (kmOutside <= 0) return 0;
    return double.parse((kmOutside * ratePerKm).toStringAsFixed(2));
  }

  /// The whole fare for a trip of [distanceInKm], of which [kmOutside] lies
  /// beyond the town boundary.
  double fareWithReturn({required double distanceInKm, double kmOutside = 0}) =>
      calculateFareFromDistance(distanceInKm) + outOfTownExtra(kmOutside);

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

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import '../models/fare_rates.dart';

/// What a ride costs, from the rates currently in force.
///
/// The rates are no longer constants: they are set from the dashboard and
/// loaded by [FareSettingsService], because fares move with fuel prices and
/// with the local ordinance. Until they load — first run, no signal — the
/// built-in defaults apply, so a fare is always quotable.
class FareService {
  static final FareService instance = FareService._();
  FareService._();

  /// The rates in force, for screens that show them. A screen listening here
  /// redraws the moment an admin saves new rates — the Fare Matrix used to
  /// print ₱35 and ₱10/km as fixed text, so a change never reached it.
  final ValueNotifier<FareRates> ratesListenable = ValueNotifier(
    FareRates.defaults,
  );

  /// The rates in force. Replaced by [FareSettingsService] when the saved
  /// rates arrive; never left in an unusable state.
  FareRates get rates => ratesListenable.value;
  set rates(FareRates value) => ratesListenable.value = value;

  /// The fare policy in two lines, at the rates in force — for the terms
  /// every user agrees to, which used to state fixed amounts.
  String get policyLines =>
      '• Minimum fare: ${formatFare(currentMinimumFare)} (first 1 kilometer)\n'
      '• Additional: ${formatFare(currentRatePerKm)} per succeeding kilometer';

  /// The rates as they were before they could be set, kept for reading old
  /// receipts that recorded no rates of their own.
  static const double minimumFare = 35.0;
  static const double ratePerKm = 10.0;

  double get currentMinimumFare => rates.minimumFare;
  double get currentRatePerKm => rates.ratePerKm;

  double calculateFare(LatLng pickup, LatLng dropoff) {
    final distanceInKm = calculateDistance(pickup, dropoff);
    return calculateFareFromDistance(distanceInKm);
  }

  /// What an out-of-town trip adds: the kilometres beyond the town boundary
  /// charged a second time, for the driver's empty return. Those kilometres
  /// are already in the trip's distance, so adding the per-km rate once more
  /// makes them double rate.
  double outOfTownExtra(double kmOutside) {
    if (kmOutside <= 0) return 0;
    return double.parse((kmOutside * currentRatePerKm).toStringAsFixed(2));
  }

  /// The whole fare for a trip of [distanceInKm], of which [kmOutside] lies
  /// beyond the town boundary.
  double fareWithReturn({required double distanceInKm, double kmOutside = 0}) =>
      calculateFareFromDistance(distanceInKm) + outOfTownExtra(kmOutside);

  double calculateFareFromDistance(double distanceInKm) {
    if (distanceInKm <= 1.0) {
      return currentMinimumFare;
    }

    // Round up to next whole km
    final roundedKm = distanceInKm.ceilToDouble();
    final additionalKm = roundedKm - 1.0;
    final fare = currentMinimumFare + (additionalKm * currentRatePerKm);

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

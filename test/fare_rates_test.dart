/// Tests for adjustable fare rates: what may be set, and what a ride costs
/// once it is.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:toda_equeue_plus/core/models/fare_rates.dart';
import 'package:toda_equeue_plus/core/services/fare_service.dart';

void main() {
  final fare = FareService.instance;

  // Every test starts from the rates the app ships with.
  setUp(() => fare.rates = FareRates.defaults);
  tearDown(() => fare.rates = FareRates.defaults);

  group('what may be set as a rate', () {
    test('the defaults are the rates the app has always charged', () {
      expect(FareRates.defaults.minimumFare, 35);
      expect(FareRates.defaults.ratePerKm, 10);
      expect(FareRates.defaults.pickupFee, 15);
      expect(FareRates.defaults.isUsable, isTrue);
    });

    test('an ordinary change is read as given', () {
      final rates = FareRates.fromMap({
        'minimumFare': 40,
        'ratePerKm': 12.5,
        'pickupFee': 20,
      });
      expect(rates.minimumFare, 40);
      expect(rates.ratePerKm, 12.5);
      expect(rates.pickupFee, 20);
    });

    test('a mistyped rate falls back, and only that one', () {
      // A ₱1,000 base fare must never reach a passenger's screen — but one
      // bad field should not throw away the other two.
      final rates = FareRates.fromMap({
        'minimumFare': 1000,
        'ratePerKm': 12,
        'pickupFee': 20,
      });
      expect(rates.minimumFare, FareRates.defaults.minimumFare);
      expect(rates.ratePerKm, 12);
      expect(rates.pickupFee, 20);
    });

    test('missing, null and non-numeric fields fall back', () {
      final rates = FareRates.fromMap({
        'ratePerKm': 'twelve',
        'pickupFee': null,
      });
      expect(rates, FareRates.defaults);
      expect(FareRates.fromMap(null), FareRates.defaults);
      expect(FareRates.fromMap(const {}), FareRates.defaults);
    });

    test('a free pick-up is allowed; a negative one is not', () {
      expect(FareRates.fromMap({'pickupFee': 0}).pickupFee, 0);
      expect(
        FareRates.fromMap({'pickupFee': -5}).pickupFee,
        FareRates.defaults.pickupFee,
      );
    });

    test('infinity and NaN are refused', () {
      expect(
        FareRates.fromMap({'ratePerKm': double.infinity}).ratePerKm,
        FareRates.defaults.ratePerKm,
      );
      expect(
        FareRates.fromMap({'ratePerKm': double.nan}).ratePerKm,
        FareRates.defaults.ratePerKm,
      );
    });

    test('a round trip through a map keeps the rates', () {
      const set = FareRates(minimumFare: 45, ratePerKm: 13, pickupFee: 18);
      expect(FareRates.fromMap(set.toMap()), set);
    });
  });

  group('what a ride costs at the rates in force', () {
    test('the defaults charge what they always did', () {
      expect(fare.calculateFareFromDistance(0.5), 35);
      expect(fare.calculateFareFromDistance(3), 55);
    });

    test('raising the rates raises the fare at once', () {
      fare.rates = const FareRates(
        minimumFare: 40,
        ratePerKm: 12,
        pickupFee: 18,
      );
      expect(fare.calculateFareFromDistance(0.5), 40);
      // 40 + two whole kilometres at 12.
      expect(fare.calculateFareFromDistance(3), 64);
      expect(fare.currentPickupFee, 18);
    });

    test('the out-of-town charge follows the per-km rate too', () {
      expect(fare.outOfTownExtra(3), 30);
      fare.rates = const FareRates(
        minimumFare: 35,
        ratePerKm: 15,
        pickupFee: 15,
      );
      expect(fare.outOfTownExtra(3), 45);
      // A 6 km trip (35 + 5×15 = 110) with 3 km beyond the line.
      expect(fare.fareWithReturn(distanceInKm: 6, kmOutside: 3), 155);
    });

    test(
      'the rates the app shipped with are still readable, for old receipts',
      () {
        // Receipts written before rates could be set recorded no rates of
        // their own; they were charged at these.
        expect(FareService.minimumFare, 35);
        expect(FareService.pickupFee, 15);
      },
    );
  });
}

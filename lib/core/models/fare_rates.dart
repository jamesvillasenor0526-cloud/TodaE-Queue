/// The rates a fare is worked out from, and what may be set as one.
///
/// These used to be constants compiled into the app, so a fuel price rise or
/// a new fare ordinance meant a new build on every phone. They are now set
/// once from the dashboard and read by both apps.
///
/// Two things are deliberate. A trip keeps the fare it was booked at — the
/// fare is written onto the booking, so nothing here can re-price a ride
/// that already happened. And a rate outside [kFareLimits] is refused rather
/// than used: a mistyped ₱1,000 base fare must never reach a passenger's
/// screen, and the security rules refuse the same values the app does.
///
/// Pure — no Firebase — so the limits are tested without a device.
library;

/// What a rate may be. Wide enough for any plausible ordinance, narrow
/// enough that a typo or a corrupted document cannot charge a fortune.
class FareLimit {
  final double min;
  final double max;
  const FareLimit(this.min, this.max);

  bool allows(double v) => v.isFinite && v >= min && v <= max;
}

class _Limits {
  const _Limits();
  FareLimit get minimumFare => const FareLimit(5, 200);
  FareLimit get ratePerKm => const FareLimit(1, 100);
  FareLimit get pickupFee => const FareLimit(0, 100);
}

const kFareLimits = _Limits();

/// What a tricycle ride costs: a minimum that covers the first kilometre,
/// a rate for each kilometre after it, and the fee for fetching a passenger
/// from where they are rather than from the terminal.
class FareRates {
  final double minimumFare;
  final double ratePerKm;
  final double pickupFee;

  const FareRates({
    required this.minimumFare,
    required this.ratePerKm,
    required this.pickupFee,
  });

  /// What the app charged before rates could be set, and what it falls back
  /// to when nothing has been saved or the saved document is unusable.
  static const FareRates defaults = FareRates(
    minimumFare: 35,
    ratePerKm: 10,
    pickupFee: 15,
  );

  /// Every rate is within its limit.
  bool get isUsable =>
      kFareLimits.minimumFare.allows(minimumFare) &&
      kFareLimits.ratePerKm.allows(ratePerKm) &&
      kFareLimits.pickupFee.allows(pickupFee);

  Map<String, dynamic> toMap() => {
    'minimumFare': minimumFare,
    'ratePerKm': ratePerKm,
    'pickupFee': pickupFee,
  };

  /// Reads a saved document. Anything missing, non-numeric or outside its
  /// limit falls back to [fallback] for that rate alone — one bad field
  /// should not throw away the other two.
  static FareRates fromMap(
    Map<String, dynamic>? data, {
    FareRates fallback = defaults,
  }) {
    double rate(String key, FareLimit limit, double fallbackValue) {
      // Tested, not cast: a document holding "twelve" where a number belongs
      // must fall back, not throw and take every fare down with it.
      final value = data?[key];
      if (value is! num) return fallbackValue;
      final raw = value.toDouble();
      if (!limit.allows(raw)) return fallbackValue;
      return raw;
    }

    return FareRates(
      minimumFare: rate(
        'minimumFare',
        kFareLimits.minimumFare,
        fallback.minimumFare,
      ),
      ratePerKm: rate('ratePerKm', kFareLimits.ratePerKm, fallback.ratePerKm),
      pickupFee: rate('pickupFee', kFareLimits.pickupFee, fallback.pickupFee),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FareRates &&
      other.minimumFare == minimumFare &&
      other.ratePerKm == ratePerKm &&
      other.pickupFee == pickupFee;

  @override
  int get hashCode => Object.hash(minimumFare, ratePerKm, pickupFee);

  @override
  String toString() =>
      'FareRates(min: $minimumFare, perKm: $ratePerKm, pickup: $pickupFee)';
}

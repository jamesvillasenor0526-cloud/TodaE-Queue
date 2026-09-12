/// Single source of truth for the driver/passenger trip lifecycle.
///
/// Both roles read these same values out of the one `bookings/{id}` document,
/// so neither app ever invents its own local status. The backend document is
/// authoritative; the UIs are just two views of it.
///
/// Two independent lifecycles are tracked, because a trip's progress and its
/// payment are different concerns: a driver can be `driverArrived` while
/// payment is still `unpaid`.
library;

/// Where the trip itself has got to.
enum TripStatus {
  requested('REQUESTED'),
  driverAccepted('DRIVER_ACCEPTED'),
  driverOnTheWay('DRIVER_ON_THE_WAY'),
  driverArrived('DRIVER_ARRIVED'),
  readyToStart('READY_TO_START'),
  tripInProgress('TRIP_IN_PROGRESS'),
  tripCompleted('TRIP_COMPLETED'),
  cancelled('CANCELLED');

  const TripStatus(this.wire);

  /// Value stored in Firestore under `tripStatus`.
  final String wire;

  static TripStatus? fromWire(String? value) {
    if (value == null) return null;
    for (final s in TripStatus.values) {
      if (s.wire == value) return s;
    }
    return null;
  }

  bool get isTerminal =>
      this == TripStatus.tripCompleted || this == TripStatus.cancelled;

  /// What the passenger is told.
  String get passengerLabel => switch (this) {
    TripStatus.requested => 'Finding a driver…',
    TripStatus.driverAccepted => 'Driver accepted your request',
    TripStatus.driverOnTheWay => 'Driver is on the way',
    TripStatus.driverArrived => 'Your driver has arrived',
    TripStatus.readyToStart => 'Ready to start your trip',
    TripStatus.tripInProgress => 'Trip in progress',
    TripStatus.tripCompleted => 'Trip completed',
    TripStatus.cancelled => 'Trip cancelled',
  };

  /// What the driver is told.
  String get driverLabel => switch (this) {
    TripStatus.requested => 'New ride request',
    TripStatus.driverAccepted => 'Ride accepted',
    TripStatus.driverOnTheWay => 'Heading to passenger',
    TripStatus.driverArrived => 'Waiting for passenger',
    TripStatus.readyToStart => 'Ready to start trip',
    TripStatus.tripInProgress => 'Trip in progress',
    TripStatus.tripCompleted => 'Trip completed',
    TripStatus.cancelled => 'Trip cancelled',
  };

  /// Legacy `status` value kept in sync so the admin dashboard — which
  /// hard-codes 'waiting'/'dispatched'/'accepted'/'completed'/'cancelled' —
  /// keeps working against the same documents.
  String get legacyStatus => switch (this) {
    TripStatus.requested => 'assigned',
    TripStatus.driverAccepted ||
    TripStatus.driverOnTheWay ||
    TripStatus.driverArrived ||
    TripStatus.readyToStart ||
    TripStatus.tripInProgress => 'accepted',
    TripStatus.tripCompleted => 'completed',
    TripStatus.cancelled => 'cancelled',
  };

  /// Best-effort reading of a pre-migration booking that only has the legacy
  /// `status` field, so old trips still render correctly in history.
  static TripStatus fromLegacy(String? legacy) => switch (legacy) {
    'assigned' || 'dispatched' => TripStatus.requested,
    'accepted' => TripStatus.driverAccepted,
    'completed' => TripStatus.tripCompleted,
    'cancelled' => TripStatus.cancelled,
    _ => TripStatus.requested,
  };
}

/// Where payment for the trip has got to. Deliberately separate from
/// [TripStatus] — payment is not a trip stage.
enum PaymentState {
  unpaid('UNPAID'),
  paymentSubmitted('PAYMENT_SUBMITTED'),
  paymentVerifying('PAYMENT_VERIFYING'),
  paymentConfirmed('PAYMENT_CONFIRMED'),
  paymentRejected('PAYMENT_REJECTED');

  const PaymentState(this.wire);

  /// Value stored in Firestore under `paymentState`. Note this is a *new*
  /// field: the legacy `paymentStatus` field keeps its 'pending'/'paid'
  /// vocabulary for the admin dashboard.
  final String wire;

  static PaymentState? fromWire(String? value) {
    if (value == null) return null;
    for (final s in PaymentState.values) {
      if (s.wire == value) return s;
    }
    return null;
  }

  bool get isSettled => this == PaymentState.paymentConfirmed;

  String get passengerLabel => switch (this) {
    PaymentState.unpaid => 'Payment due',
    PaymentState.paymentSubmitted => 'Waiting for driver verification',
    PaymentState.paymentVerifying => 'Driver is verifying your payment…',
    PaymentState.paymentConfirmed => 'Payment confirmed',
    PaymentState.paymentRejected =>
      'Driver could not verify your payment. Please try again.',
  };

  String get driverLabel => switch (this) {
    PaymentState.unpaid => 'Waiting for payment',
    PaymentState.paymentSubmitted => 'Payment verification required',
    PaymentState.paymentVerifying => 'Verify passenger payment',
    PaymentState.paymentConfirmed => 'Payment confirmed',
    PaymentState.paymentRejected => 'Payment rejected',
  };

  /// Legacy `paymentStatus` mirror for the admin dashboard.
  String get legacyPaymentStatus =>
      this == PaymentState.paymentConfirmed ? 'paid' : 'pending';

  static PaymentState fromLegacy(String? legacy) =>
      legacy == 'paid' ? PaymentState.paymentConfirmed : PaymentState.unpaid;
}

/// Who is attempting a transition. Used to keep each side from driving the
/// other's part of the flow.
enum TripRole { passenger, driver }

/// The allowed trip transitions, and who may perform each.
///
/// Anything not listed here is rejected, so a bad button or a stale screen
/// can't push a trip into an impossible state (e.g. verifying → completed).
const Map<TripStatus, Map<TripStatus, Set<TripRole>>> kTripTransitions = {
  TripStatus.requested: {
    TripStatus.driverAccepted: {TripRole.driver},
    TripStatus.cancelled: {TripRole.passenger, TripRole.driver},
  },
  TripStatus.driverAccepted: {
    TripStatus.driverOnTheWay: {TripRole.driver},
    TripStatus.cancelled: {TripRole.passenger, TripRole.driver},
  },
  TripStatus.driverOnTheWay: {
    TripStatus.driverArrived: {TripRole.driver},
    TripStatus.cancelled: {TripRole.passenger, TripRole.driver},
  },
  TripStatus.driverArrived: {
    // Only reachable once payment is confirmed — enforced in TripService.
    TripStatus.readyToStart: {TripRole.driver},
    TripStatus.cancelled: {TripRole.passenger, TripRole.driver},
  },
  TripStatus.readyToStart: {
    TripStatus.tripInProgress: {TripRole.driver},
    TripStatus.cancelled: {TripRole.driver},
  },
  TripStatus.tripInProgress: {
    TripStatus.tripCompleted: {TripRole.driver},
  },
  TripStatus.tripCompleted: {},
  TripStatus.cancelled: {},
};

/// The allowed payment transitions, and who may perform each.
const Map<PaymentState, Map<PaymentState, Set<TripRole>>> kPaymentTransitions =
    {
      PaymentState.unpaid: {
        PaymentState.paymentSubmitted: {TripRole.passenger},
      },
      PaymentState.paymentSubmitted: {
        PaymentState.paymentVerifying: {TripRole.driver},
      },
      PaymentState.paymentVerifying: {
        PaymentState.paymentConfirmed: {TripRole.driver},
        PaymentState.paymentRejected: {TripRole.driver},
      },
      // A rejected payment goes back to the passenger to re-submit.
      PaymentState.paymentRejected: {
        PaymentState.paymentSubmitted: {TripRole.passenger},
      },
      PaymentState.paymentConfirmed: {},
    };

bool canTransitionTrip(TripStatus from, TripStatus to, TripRole by) =>
    kTripTransitions[from]?[to]?.contains(by) ?? false;

bool canTransitionPayment(PaymentState from, PaymentState to, TripRole by) =>
    kPaymentTransitions[from]?[to]?.contains(by) ?? false;

/// Full rule check for a trip move, including the rules that depend on
/// payment. Returns a user-facing reason for refusal, or null if allowed.
///
/// Kept pure and outside the Firestore transaction so the business rules can
/// be tested without a device or a network.
String? validateTripMove({
  required TripStatus from,
  required TripStatus to,
  required PaymentState payment,
  required TripRole by,
  bool payLater = false,
}) {
  if (from == to) return null; // already applied; treated as a no-op
  if (!canTransitionTrip(from, to, by)) {
    return 'Can\'t go from "${from.wire}" to "${to.wire}" right now.';
  }
  // A trip may only start once payment has been confirmed — unless the
  // driver has agreed to be paid at the end of the ride, which is how a
  // tricycle fare is usually settled. Only the driver can agree to that
  // ([payLater] is their answer, not the passenger's request), because it
  // is the driver who carries the risk of not being paid.
  if (to == TripStatus.tripInProgress &&
      payment != PaymentState.paymentConfirmed &&
      !payLater) {
    return 'Payment must be confirmed before the trip can start.';
  }
  if (to == TripStatus.readyToStart &&
      payment != PaymentState.paymentConfirmed &&
      !payLater) {
    return 'Confirm the passenger\'s payment first.';
  }
  return null;
}

/// Full rule check for a payment move. Returns a user-facing reason for
/// refusal, or null if allowed.
String? validatePaymentMove({
  required PaymentState from,
  required PaymentState to,
  required TripRole by,
}) {
  if (from == to) return null; // already applied
  if (!canTransitionPayment(from, to, by)) {
    return 'Can\'t move payment from "${from.wire}" to "${to.wire}" right now.';
  }
  return null;
}

/// An immutable snapshot of the one shared trip record.
class TripState {
  final String bookingId;
  final TripStatus trip;
  final PaymentState payment;
  final String? paymentMethod;
  final double fare;
  final String? driverId;
  final String? driverName;
  final String? passengerId;
  final String? passengerName;
  final String? terminalName;
  final String? receiptNumber;

  /// The passenger has asked to pay at the end of the ride.
  final bool payAfterRequested;

  /// …and the driver has agreed, which is what lets the trip start unpaid.
  final bool payAfterAgreed;

  const TripState({
    required this.bookingId,
    required this.trip,
    required this.payment,
    required this.fare,
    this.paymentMethod,
    this.driverId,
    this.driverName,
    this.passengerId,
    this.passengerName,
    this.terminalName,
    this.receiptNumber,
    this.payAfterRequested = false,
    this.payAfterAgreed = false,
  });

  /// Reads a booking document, preferring the new fields and falling back to
  /// the legacy ones so bookings created before this change still work.
  factory TripState.fromMap(String bookingId, Map<String, dynamic> data) {
    final trip =
        TripStatus.fromWire(data['tripStatus'] as String?) ??
        TripStatus.fromLegacy(data['status'] as String?);
    final payment =
        PaymentState.fromWire(data['paymentState'] as String?) ??
        PaymentState.fromLegacy(data['paymentStatus'] as String?);

    return TripState(
      bookingId: bookingId,
      trip: trip,
      payment: payment,
      paymentMethod: data['paymentMethod'] as String?,
      fare: (data['fare'] as num?)?.toDouble() ?? 0,
      driverId: data['driverId'] as String?,
      driverName: data['driverName'] as String?,
      passengerId: data['passengerId'] as String?,
      passengerName: data['passengerName'] as String?,
      terminalName: data['terminalName'] as String?,
      receiptNumber: data['receiptNumber'] as String?,
      // Only a real true counts, so a stray value never starts a trip unpaid.
      payAfterRequested: data['payAfterRequested'] == true,
      payAfterAgreed: data['payAfterAgreed'] == true,
    );
  }

  /// True once the driver is with the passenger and payment hasn't settled —
  /// the window in which the passenger is expected to pay.
  bool get awaitingPayment =>
      trip == TripStatus.driverArrived && !payment.isSettled;

  /// The ride is over and the fare is still owed — the driver agreed to be
  /// paid at the end, or the trip was completed before payment settled.
  bool get awaitingPaymentAfterRide =>
      trip == TripStatus.tripCompleted && !payment.isSettled;

  /// The passenger is asking to pay at the end and the driver has not
  /// answered yet.
  bool get payAfterPending => payAfterRequested && !payAfterAgreed;

  bool get isActive => !trip.isTerminal;
}

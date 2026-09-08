import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/trip_state.dart';
import 'notification_service.dart';

/// Raised when a transition is refused. The message is safe to show a user.
class TripTransitionException implements Exception {
  final String message;
  TripTransitionException(this.message);
  @override
  String toString() => message;
}

/// Owns every change to the shared trip record.
///
/// Both the driver and passenger screens go through here rather than writing
/// booking fields directly, so that:
///  * every transition is checked against the state machine,
///  * the write is atomic and re-checks the current state inside the
///    transaction (a double-tap or a stale screen can't apply twice),
///  * the legacy `status`/`paymentStatus` fields stay mirrored for the admin
///    dashboard, which still reads the old vocabulary.
class TripService {
  TripService._();
  static final TripService instance = TripService._();

  final _firestore = FirebaseFirestore.instance;

  DocumentReference<Map<String, dynamic>> _ref(String bookingId) =>
      _firestore.collection('bookings').doc(bookingId);

  /// Live view of one trip. Both roles subscribe to this, which is what keeps
  /// the two screens in step without any manual refresh.
  Stream<TripState> watch(String bookingId) => _ref(bookingId).snapshots().map(
    (snap) => TripState.fromMap(bookingId, snap.data() ?? const {}),
  );

  /// One-shot read, used when an app resumes and needs to catch up to
  /// whatever happened while it was closed.
  Future<TripState?> read(String bookingId) async {
    final snap = await _ref(bookingId).get();
    if (!snap.exists) return null;
    return TripState.fromMap(bookingId, snap.data() ?? const {});
  }

  /// Moves the trip to [to] on behalf of [by].
  ///
  /// Returns normally if the trip is already in [to] (idempotent), so a
  /// double-tap is a no-op rather than an error or a duplicate write.
  Future<void> moveTrip({
    required String bookingId,
    required TripStatus to,
    required TripRole by,
  }) async {
    await _firestore.runTransaction((tx) async {
      final ref = _ref(bookingId);
      final snap = await tx.get(ref);
      if (!snap.exists) {
        throw TripTransitionException('This trip no longer exists.');
      }
      final current = TripState.fromMap(bookingId, snap.data() ?? const {});

      if (current.trip == to) return; // already applied

      final refusal = validateTripMove(
        from: current.trip,
        to: to,
        payment: current.payment,
        by: by,
      );
      if (refusal != null) throw TripTransitionException(refusal);

      tx.update(ref, {
        'tripStatus': to.wire,
        // Legacy mirror — the admin dashboard reads this field.
        'status': to.legacyStatus,
        'updatedAt': FieldValue.serverTimestamp(),
        ..._tripTimestamps(to),
      });
    });

    await _notifyTrip(to);
  }

  /// Moves the payment lifecycle to [to] on behalf of [by].
  ///
  /// When payment reaches confirmed, the trip is advanced to
  /// [TripStatus.readyToStart] in the *same* transaction — payment
  /// confirmation and trip start stay separate events, but the trip must not
  /// be left sitting in `driverArrived` with a settled payment.
  Future<void> movePayment({
    required String bookingId,
    required PaymentState to,
    required TripRole by,
    String? method,
  }) async {
    await _firestore.runTransaction((tx) async {
      final ref = _ref(bookingId);
      final snap = await tx.get(ref);
      if (!snap.exists) {
        throw TripTransitionException('This trip no longer exists.');
      }
      final current = TripState.fromMap(bookingId, snap.data() ?? const {});

      if (current.payment == to) return; // already applied

      final refusal = validatePaymentMove(
        from: current.payment,
        to: to,
        by: by,
      );
      if (refusal != null) throw TripTransitionException(refusal);

      final update = <String, dynamic>{
        'paymentState': to.wire,
        // Legacy mirror — the admin dashboard reads 'paid'/'pending'.
        'paymentStatus': to.legacyPaymentStatus,
        'updatedAt': FieldValue.serverTimestamp(),
      };
      if (method != null) update['paymentMethod'] = method;

      if (to == PaymentState.paymentSubmitted) {
        update['paymentSubmittedAt'] = FieldValue.serverTimestamp();
      }
      if (to == PaymentState.paymentConfirmed) {
        update['paidAt'] = FieldValue.serverTimestamp();
        update['driverConfirmedPayment'] = true;
        // Payment settled ⇒ the trip is ready to start (but not started).
        if (current.trip == TripStatus.driverArrived) {
          update['tripStatus'] = TripStatus.readyToStart.wire;
          update['status'] = TripStatus.readyToStart.legacyStatus;
        }
      }

      tx.update(ref, update);
    });

    await _notifyPayment(to);
  }

  /// Records which method the passenger intends to use without yet claiming
  /// they've paid. Kept separate from [movePayment] so choosing a method
  /// isn't itself a payment submission.
  Future<void> setPaymentMethod({
    required String bookingId,
    required String method,
  }) async {
    await _ref(bookingId).update({
      'paymentMethod': method,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Map<String, dynamic> _tripTimestamps(TripStatus to) => switch (to) {
    TripStatus.driverAccepted => {'acceptedAt': FieldValue.serverTimestamp()},
    TripStatus.driverOnTheWay => {'onTheWayAt': FieldValue.serverTimestamp()},
    TripStatus.driverArrived => {'arrivedAt': FieldValue.serverTimestamp()},
    TripStatus.tripInProgress => {'startedAt': FieldValue.serverTimestamp()},
    TripStatus.tripCompleted => {'completedAt': FieldValue.serverTimestamp()},
    TripStatus.cancelled => {'cancelledAt': FieldValue.serverTimestamp()},
    _ => const {},
  };

  // Notifications are fired off the committed state change, not off the
  // button press, so they only ever reflect what the backend actually stored.
  Future<void> _notifyTrip(TripStatus to) async {
    final text = switch (to) {
      TripStatus.driverAccepted => 'Your driver has accepted the request.',
      TripStatus.driverOnTheWay => 'Your driver is on the way.',
      TripStatus.driverArrived => 'Your driver has arrived.',
      TripStatus.tripInProgress => 'Your trip has started.',
      TripStatus.tripCompleted => 'Your trip has been completed.',
      TripStatus.cancelled => 'This trip was cancelled.',
      _ => null,
    };
    if (text == null) return;
    try {
      await NotificationService.instance.showNotification(
        title: 'TODA E-QUEUE+',
        body: text,
      );
    } catch (_) {
      // A failed local notification must never fail the transition.
    }
  }

  Future<void> _notifyPayment(PaymentState to) async {
    final text = switch (to) {
      PaymentState.paymentSubmitted => 'Payment verification required.',
      PaymentState.paymentConfirmed =>
        'Payment confirmed. Your driver is ready to start.',
      PaymentState.paymentRejected =>
        'Your payment could not be verified. Please try again.',
      _ => null,
    };
    if (text == null) return;
    try {
      await NotificationService.instance.showNotification(
        title: 'TODA E-QUEUE+',
        body: text,
      );
    } catch (_) {}
  }
}

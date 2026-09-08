import 'package:flutter_test/flutter_test.dart';
import 'package:toda_equeue_plus/core/models/trip_state.dart';

void main() {
  group('trip transitions', () {
    test('follows the intended happy path', () {
      expect(
        canTransitionTrip(
          TripStatus.requested,
          TripStatus.driverAccepted,
          TripRole.driver,
        ),
        isTrue,
      );
      expect(
        canTransitionTrip(
          TripStatus.driverAccepted,
          TripStatus.driverOnTheWay,
          TripRole.driver,
        ),
        isTrue,
      );
      expect(
        canTransitionTrip(
          TripStatus.driverOnTheWay,
          TripStatus.driverArrived,
          TripRole.driver,
        ),
        isTrue,
      );
      expect(
        canTransitionTrip(
          TripStatus.readyToStart,
          TripStatus.tripInProgress,
          TripRole.driver,
        ),
        isTrue,
      );
      expect(
        canTransitionTrip(
          TripStatus.tripInProgress,
          TripStatus.tripCompleted,
          TripRole.driver,
        ),
        isTrue,
      );
    });

    test('a trip cannot be completed without being started', () {
      expect(
        canTransitionTrip(
          TripStatus.driverArrived,
          TripStatus.tripCompleted,
          TripRole.driver,
        ),
        isFalse,
      );
      expect(
        canTransitionTrip(
          TripStatus.readyToStart,
          TripStatus.tripCompleted,
          TripRole.driver,
        ),
        isFalse,
      );
    });

    test('the driver cannot skip ahead to arrived', () {
      expect(
        canTransitionTrip(
          TripStatus.driverAccepted,
          TripStatus.driverArrived,
          TripRole.driver,
        ),
        isFalse,
      );
    });

    test('a passenger cannot drive the trip forward', () {
      expect(
        canTransitionTrip(
          TripStatus.requested,
          TripStatus.driverAccepted,
          TripRole.passenger,
        ),
        isFalse,
      );
      expect(
        canTransitionTrip(
          TripStatus.readyToStart,
          TripStatus.tripInProgress,
          TripRole.passenger,
        ),
        isFalse,
      );
    });

    test('a passenger may cancel before the trip starts, but not after', () {
      expect(
        canTransitionTrip(
          TripStatus.driverOnTheWay,
          TripStatus.cancelled,
          TripRole.passenger,
        ),
        isTrue,
      );
      expect(
        canTransitionTrip(
          TripStatus.tripInProgress,
          TripStatus.cancelled,
          TripRole.passenger,
        ),
        isFalse,
      );
    });

    test('terminal states admit no further transitions', () {
      expect(kTripTransitions[TripStatus.tripCompleted], isEmpty);
      expect(kTripTransitions[TripStatus.cancelled], isEmpty);
      expect(TripStatus.tripCompleted.isTerminal, isTrue);
      expect(TripStatus.driverArrived.isTerminal, isFalse);
    });
  });

  group('payment transitions', () {
    test('follows submit → verify → confirm', () {
      expect(
        canTransitionPayment(
          PaymentState.unpaid,
          PaymentState.paymentSubmitted,
          TripRole.passenger,
        ),
        isTrue,
      );
      expect(
        canTransitionPayment(
          PaymentState.paymentSubmitted,
          PaymentState.paymentVerifying,
          TripRole.driver,
        ),
        isTrue,
      );
      expect(
        canTransitionPayment(
          PaymentState.paymentVerifying,
          PaymentState.paymentConfirmed,
          TripRole.driver,
        ),
        isTrue,
      );
    });

    test('a passenger cannot confirm their own payment', () {
      expect(
        canTransitionPayment(
          PaymentState.paymentVerifying,
          PaymentState.paymentConfirmed,
          TripRole.passenger,
        ),
        isFalse,
      );
    });

    test('payment cannot jump straight from unpaid to confirmed', () {
      expect(
        canTransitionPayment(
          PaymentState.unpaid,
          PaymentState.paymentConfirmed,
          TripRole.driver,
        ),
        isFalse,
      );
    });

    test('a rejected payment can be re-submitted by the passenger', () {
      expect(
        canTransitionPayment(
          PaymentState.paymentVerifying,
          PaymentState.paymentRejected,
          TripRole.driver,
        ),
        isTrue,
      );
      expect(
        canTransitionPayment(
          PaymentState.paymentRejected,
          PaymentState.paymentSubmitted,
          TripRole.passenger,
        ),
        isTrue,
      );
    });

    test('confirmed payment is terminal', () {
      expect(kPaymentTransitions[PaymentState.paymentConfirmed], isEmpty);
      expect(PaymentState.paymentConfirmed.isSettled, isTrue);
    });
  });

  group('legacy compatibility', () {
    test('legacy mirrors match the values the admin dashboard compares', () {
      // The admin hard-codes these strings; they must not drift.
      expect(TripStatus.tripCompleted.legacyStatus, 'completed');
      expect(TripStatus.cancelled.legacyStatus, 'cancelled');
      expect(TripStatus.driverOnTheWay.legacyStatus, 'accepted');
      expect(PaymentState.paymentConfirmed.legacyPaymentStatus, 'paid');
      expect(PaymentState.paymentVerifying.legacyPaymentStatus, 'pending');
      expect(PaymentState.unpaid.legacyPaymentStatus, 'pending');
    });

    test('a pre-migration booking still reads correctly', () {
      final state = TripState.fromMap('b1', {
        'status': 'completed',
        'paymentStatus': 'paid',
        'fare': 45,
      });
      expect(state.trip, TripStatus.tripCompleted);
      expect(state.payment, PaymentState.paymentConfirmed);
      expect(state.fare, 45);
    });

    test('new fields win over legacy ones when both are present', () {
      final state = TripState.fromMap('b1', {
        'status': 'accepted',
        'tripStatus': 'DRIVER_ARRIVED',
        'paymentStatus': 'pending',
        'paymentState': 'PAYMENT_VERIFYING',
      });
      expect(state.trip, TripStatus.driverArrived);
      expect(state.payment, PaymentState.paymentVerifying);
    });

    test('awaitingPayment marks the pay-at-pickup window', () {
      final arrived = TripState.fromMap('b1', {
        'tripStatus': 'DRIVER_ARRIVED',
        'paymentState': 'UNPAID',
      });
      expect(arrived.awaitingPayment, isTrue);

      final started = TripState.fromMap('b1', {
        'tripStatus': 'TRIP_IN_PROGRESS',
        'paymentState': 'PAYMENT_CONFIRMED',
      });
      expect(started.awaitingPayment, isFalse);
    });
  });


  group('payment gating (the rules that block a premature trip start)', () {
    test('the trip cannot start while payment is unconfirmed', () {
      for (final p in [
        PaymentState.unpaid,
        PaymentState.paymentSubmitted,
        PaymentState.paymentVerifying,
        PaymentState.paymentRejected,
      ]) {
        expect(
          validateTripMove(
            from: TripStatus.readyToStart,
            to: TripStatus.tripInProgress,
            payment: p,
            by: TripRole.driver,
          ),
          isNotNull,
          reason: 'payment $p must not allow the trip to start',
        );
      }
    });

    test('the trip starts once payment is confirmed', () {
      expect(
        validateTripMove(
          from: TripStatus.readyToStart,
          to: TripStatus.tripInProgress,
          payment: PaymentState.paymentConfirmed,
          by: TripRole.driver,
        ),
        isNull,
      );
    });

    test('cannot become ready-to-start before payment is confirmed', () {
      expect(
        validateTripMove(
          from: TripStatus.driverArrived,
          to: TripStatus.readyToStart,
          payment: PaymentState.paymentVerifying,
          by: TripRole.driver,
        ),
        isNotNull,
      );
      expect(
        validateTripMove(
          from: TripStatus.driverArrived,
          to: TripStatus.readyToStart,
          payment: PaymentState.paymentConfirmed,
          by: TripRole.driver,
        ),
        isNull,
      );
    });

    test('re-applying the current state is a no-op, not an error', () {
      expect(
        validateTripMove(
          from: TripStatus.tripInProgress,
          to: TripStatus.tripInProgress,
          payment: PaymentState.unpaid,
          by: TripRole.driver,
        ),
        isNull,
        reason: 'double-tap must be idempotent',
      );
      expect(
        validatePaymentMove(
          from: PaymentState.paymentConfirmed,
          to: PaymentState.paymentConfirmed,
          by: TripRole.driver,
        ),
        isNull,
      );
    });
  });

  group('payment rejection loop', () {
    test('driver rejects, passenger re-submits, driver confirms', () {
      // Driver rejects a payment being verified.
      expect(
        validatePaymentMove(
          from: PaymentState.paymentVerifying,
          to: PaymentState.paymentRejected,
          by: TripRole.driver,
        ),
        isNull,
      );
      // Passenger submits again.
      expect(
        validatePaymentMove(
          from: PaymentState.paymentRejected,
          to: PaymentState.paymentSubmitted,
          by: TripRole.passenger,
        ),
        isNull,
      );
      // Driver verifies then confirms the retry.
      expect(
        validatePaymentMove(
          from: PaymentState.paymentSubmitted,
          to: PaymentState.paymentVerifying,
          by: TripRole.driver,
        ),
        isNull,
      );
      expect(
        validatePaymentMove(
          from: PaymentState.paymentVerifying,
          to: PaymentState.paymentConfirmed,
          by: TripRole.driver,
        ),
        isNull,
      );
    });

    test('a rejected payment cannot jump straight to confirmed', () {
      expect(
        validatePaymentMove(
          from: PaymentState.paymentRejected,
          to: PaymentState.paymentConfirmed,
          by: TripRole.driver,
        ),
        isNotNull,
      );
    });

    test('the driver cannot re-submit on the passenger\'s behalf', () {
      expect(
        validatePaymentMove(
          from: PaymentState.paymentRejected,
          to: PaymentState.paymentSubmitted,
          by: TripRole.driver,
        ),
        isNotNull,
      );
    });
  });

  group('cancellation', () {
    test('either side may cancel before the trip starts', () {
      for (final from in [
        TripStatus.requested,
        TripStatus.driverAccepted,
        TripStatus.driverOnTheWay,
        TripStatus.driverArrived,
      ]) {
        for (final who in TripRole.values) {
          expect(
            validateTripMove(
              from: from,
              to: TripStatus.cancelled,
              payment: PaymentState.unpaid,
              by: who,
            ),
            isNull,
            reason: '$who should be able to cancel from $from',
          );
        }
      }
    });

    test('a passenger cannot cancel once the trip is under way', () {
      expect(
        validateTripMove(
          from: TripStatus.tripInProgress,
          to: TripStatus.cancelled,
          payment: PaymentState.paymentConfirmed,
          by: TripRole.passenger,
        ),
        isNotNull,
      );
    });

    test('a completed trip cannot be cancelled', () {
      expect(
        validateTripMove(
          from: TripStatus.tripCompleted,
          to: TripStatus.cancelled,
          payment: PaymentState.paymentConfirmed,
          by: TripRole.driver,
        ),
        isNotNull,
      );
    });

    test('a cancelled trip cannot be revived', () {
      for (final to in TripStatus.values) {
        if (to == TripStatus.cancelled) continue;
        expect(
          validateTripMove(
            from: TripStatus.cancelled,
            to: to,
            payment: PaymentState.unpaid,
            by: TripRole.driver,
          ),
          isNotNull,
          reason: 'cancelled must not move to $to',
        );
      }
    });
  });
}

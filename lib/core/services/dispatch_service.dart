import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../models/queue_rules.dart';
import '../models/trip_state.dart';
import 'contact_service.dart';
import 'fare_service.dart';
import 'receipt_service.dart';

/// Result of attempting to dispatch a driver to a passenger.
class DispatchResult {
  final bool success;
  final String? driverId;
  final String? driverName;
  final String? bookingId;
  final String? message;

  DispatchResult.success({
    required this.driverId,
    required this.driverName,
    required this.bookingId,
  }) : success = true,
       message = null;

  DispatchResult.failure(this.message)
    : success = false,
      driverId = null,
      driverName = null,
      bookingId = null;
}

/// Handles matching a waiting passenger with the driver at the front of a
/// terminal's FIFO queue.
class DispatchService {
  DispatchService._();
  static final DispatchService instance = DispatchService._();

  final _firestore = FirebaseFirestore.instance;

  /// Dispatches the driver at the front of [terminalId]'s waiting queue to
  /// [passengerId].
  ///
  /// The Flutter Firestore SDK's transactions only support reading single
  /// documents, not queries, so we find the front-of-queue candidate with a
  /// normal query first, then use a transaction to re-check and claim that
  /// *specific* document atomically. If another booking claimed it first
  /// (race condition), we retry with the next candidate.
  Future<DispatchResult> dispatchNextDriver({
    required String terminalId,
    required String passengerId,
    double? pickupLatitude,
    double? pickupLongitude,
    double? destinationLatitude,
    double? destinationLongitude,
    double? distance,
    double? fare,
    bool outsideServiceArea = false,
    double outOfTownFee = 0,
    double outOfTownKm = 0,
    Set<String> declinedBy = const {},
  }) async {
    const maxAttempts = 5;

    // One trip at a time. Nothing stopped a passenger booking again while a
    // trip was running, which took a second driver out of the queue for a
    // ride nobody was going to take.
    final running = await activeBookingFor(passengerId);
    if (running != null) {
      return DispatchResult.failure(
        'You already have a trip in progress. Finish or cancel it first.',
      );
    }

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final candidateSnap = await _firestore
          .collection('queueEntries')
          .where('terminalId', isEqualTo: terminalId)
          .where('status', isEqualTo: 'waiting')
          .orderBy('checkedInAt')
          .orderBy('driverId')
          // Enough to look past the drivers who have already said no to this
          // trip; still the front of the queue among those who have not.
          .limit(1 + declinedBy.length)
          .get();

      // A driver who turned down an out-of-town trip keeps their place but
      // is not offered the same trip again.
      final candidate = firstNotDeclined(
        candidateSnap.docs,
        declinedBy,
        (d) => (d.data()['driverId'] ?? '').toString(),
      );

      if (candidate == null) {
        return DispatchResult.failure(
          declinedBy.isEmpty
              ? 'No drivers are currently waiting at this terminal.'
              : 'No other driver at this terminal is free right now.',
        );
      }

      final passengerDoc = await _firestore
          .collection('users')
          .doc(passengerId)
          .get();
      final passengerName = passengerDoc.data()?['name'] ?? 'Passenger';

      final candidateDoc = candidate;
      final candidateRef = candidateDoc.reference;
      final bookingRef = _firestore.collection('bookings').doc();

      // The passenger's own number, put on the booking so the driver can
      // reach them. Their own — nobody reads anyone else's contact details
      // any more; the driver adds theirs when they accept.
      final passengerPhone = (await ContactService.instance.mine()).phone;

      try {
        final claimed = await _firestore.runTransaction<bool>((tx) async {
          final freshSnap = await tx.get(candidateRef);
          if (!freshSnap.exists) return false;

          final data = freshSnap.data() as Map<String, dynamic>;
          if (data['status'] != 'waiting') {
            // Someone else claimed this driver between our query and now.
            return false;
          }

          tx.update(candidateRef, {
            'status': 'dispatched',
            'dispatchedAt': FieldValue.serverTimestamp(),
            'bookingId': bookingRef.id,
            'passengerId': passengerId,
            'passengerName': null,
          });

          tx.set(bookingRef, {
            'passengerId': passengerId,
            'driverId': data['driverId'],
            'driverName': data['driverName'],
            'terminalId': terminalId,
            'terminalName': data['terminalName'],
            'queueEntryId': candidateRef.id,
            // Authoritative state for both apps. The legacy `status` /
            // `paymentStatus` fields below are mirrors kept for the admin
            // dashboard, which still compares the old vocabulary.
            'tripStatus': TripStatus.requested.wire,
            'paymentState': PaymentState.unpaid.wire,
            'status': TripStatus.requested.legacyStatus,
            'createdAt': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
            'driverLatitude': null,
            'driverLongitude': null,
            'pickupLatitude': pickupLatitude,
            'pickupLongitude': pickupLongitude,
            'dispatchTime': FieldValue.serverTimestamp(),
            'passengerName': passengerName,
            'destinationLatitude': destinationLatitude,
            'destinationLongitude': destinationLongitude,
            'distance': distance,
            'fare': fare,
            // The rate in force when the trip was booked, written onto the
            // booking: a later change to the setting must not re-price a
            // ride that has already happened.
            'baseFare': FareService.instance.currentMinimumFare,
            // Out-of-town trips: the driver has to agree to them, and the
            // fare already includes the return charge.
            'outsideServiceArea': outsideServiceArea,
            'outOfTownFee': outOfTownFee,
            'outOfTownKm': outOfTownKm,
            'outOfTownAcceptedAt': null,
            // Carried forward so a driver who refused this trip is not
            // offered it again by a later re-dispatch.
            'declinedBy': declinedBy.toList(),
            'paymentMethod': null,
            'paymentStatus': PaymentState.unpaid.legacyPaymentStatus,
            // The driver adds their own number when they accept; until
            // then Call is unavailable, which is the price of no longer
            // letting anyone read the user directory.
            'driverPhone': null,
            'passengerPhone': passengerPhone,
          });

          return true;
        });

        if (claimed) {
          final data = candidateDoc.data();
          return DispatchResult.success(
            driverId: data['driverId'],
            driverName: (data['driverName'] ?? 'Your driver').toString(),
            bookingId: bookingRef.id,
          );
        }
        // Fall through and retry with the next candidate.
      } catch (e) {
        return DispatchResult.failure('Dispatch failed: $e');
      }
    }

    return DispatchResult.failure(
      'Could not dispatch a driver right now — please try again.',
    );
  }

  /// The id of [passengerId]'s trip that is still running, if any.
  Future<String?> activeBookingFor(String passengerId) async {
    final snap = await _firestore
        .collection('bookings')
        .where('passengerId', isEqualTo: passengerId)
        .where('status', whereIn: ['assigned', 'dispatched', 'accepted'])
        .get();
    for (final d in snap.docs) {
      if (TripState.fromMap(d.id, d.data()).isActive) return d.id;
    }
    return null;
  }

  /// Puts a driver back where they were in the queue.
  ///
  /// For a passenger cancelling: the driver was waiting their turn and did
  /// nothing wrong, so their check-in time is left alone and they keep their
  /// place. Their entry used to be cancelled outright, which sent them to
  /// the back of the queue — or out of it.
  Future<void> returnDriverToQueue(String queueEntryId) async {
    await _firestore.collection('queueEntries').doc(queueEntryId).update({
      'status': 'waiting',
      'bookingId': FieldValue.delete(),
      'passengerId': FieldValue.delete(),
      'dispatchedAt': FieldValue.delete(),
    });
  }

  /// Gives up on a driver who has not answered and dispatches the next one.
  ///
  /// The unanswered booking is cancelled and the driver goes to the *back*
  /// of their terminal's queue — they were offered the trip and left the
  /// passenger waiting. Refuses if the driver has accepted in the meantime,
  /// so a passenger tapping just as the driver accepts cannot cancel the
  /// trip from under them.
  Future<DispatchResult> findAnotherDriver(String bookingId) async {
    final bookingRef = _firestore.collection('bookings').doc(bookingId);

    final released = await _firestore.runTransaction<Map<String, dynamic>?>((
      tx,
    ) async {
      final snap = await tx.get(bookingRef);
      final data = snap.data();
      if (data == null) return null;
      final state = TripState.fromMap(bookingId, data);
      if (state.trip != TripStatus.requested) return null; // already accepted

      tx.update(bookingRef, {
        'tripStatus': TripStatus.cancelled.wire,
        'status': TripStatus.cancelled.legacyStatus,
        'cancelledAt': FieldValue.serverTimestamp(),
        'cancelledReason': 'Driver did not respond',
        'updatedAt': FieldValue.serverTimestamp(),
      });
      return data;
    });

    if (released == null) {
      return DispatchResult.failure(
        'Your driver has just accepted — hold on a moment.',
      );
    }

    final entryId = released['queueEntryId'] as String?;
    if (entryId != null) {
      try {
        await _firestore.collection('queueEntries').doc(entryId).update({
          'status': 'waiting',
          // To the back: the passenger waited on them.
          'checkedInAt': FieldValue.serverTimestamp(),
          'bookingId': FieldValue.delete(),
          'passengerId': FieldValue.delete(),
          'dispatchedAt': FieldValue.delete(),
        });
      } catch (e) {
        // Their entry is no longer ours to move; the next dispatch simply
        // skips it if it is not waiting.
        debugPrint('Could not requeue the unresponsive driver: $e');
      }
    }

    double? number(String key) => (released[key] as num?)?.toDouble();
    return dispatchNextDriver(
      terminalId: released['terminalId'] as String? ?? '',
      passengerId: released['passengerId'] as String? ?? '',
      pickupLatitude: number('pickupLatitude'),
      pickupLongitude: number('pickupLongitude'),
      destinationLatitude: number('destinationLatitude'),
      destinationLongitude: number('destinationLongitude'),
      distance: number('distance'),
      fare: number('fare'),
      outsideServiceArea: released['outsideServiceArea'] == true,
      outOfTownFee: number('outOfTownFee') ?? 0,
      outOfTownKm: number('outOfTownKm') ?? 0,
      declinedBy: {...?(released['declinedBy'] as List?)?.whereType<String>()},
    );
  }

  /// A driver turning down a trip that leaves town.
  ///
  /// Refusing an out-of-town trip is their right, so they keep their place in
  /// the queue — but they are not offered this same trip again, and the
  /// passenger is passed to the next driver who has not refused it. The
  /// passenger keeps the same booking only in spirit: a fresh one is created
  /// for the new driver, as with an unanswered dispatch.
  Future<DispatchResult> declineOutOfTown(String bookingId) async {
    final bookingRef = _firestore.collection('bookings').doc(bookingId);

    final released = await _firestore.runTransaction<Map<String, dynamic>?>((
      tx,
    ) async {
      final snap = await tx.get(bookingRef);
      final data = snap.data();
      if (data == null) return null;
      final state = TripState.fromMap(bookingId, data);
      // Only while it is still just an offer.
      if (state.trip != TripStatus.requested) return null;

      tx.update(bookingRef, {
        'tripStatus': TripStatus.cancelled.wire,
        'status': TripStatus.cancelled.legacyStatus,
        'cancelledAt': FieldValue.serverTimestamp(),
        'cancelledReason': 'Driver declined the out-of-town trip',
        'updatedAt': FieldValue.serverTimestamp(),
      });
      return data;
    });

    if (released == null) {
      return DispatchResult.failure(
        'This trip has already moved on — nothing to decline.',
      );
    }

    // Their place is kept: check-in time untouched.
    final entryId = released['queueEntryId'] as String?;
    if (entryId != null) {
      try {
        await returnDriverToQueue(entryId);
      } catch (e) {
        debugPrint('Could not return the declining driver to the queue: $e');
      }
    }

    final declinedDriver = released['driverId'] as String?;
    double? number(String key) => (released[key] as num?)?.toDouble();
    return dispatchNextDriver(
      terminalId: released['terminalId'] as String? ?? '',
      passengerId: released['passengerId'] as String? ?? '',
      pickupLatitude: number('pickupLatitude'),
      pickupLongitude: number('pickupLongitude'),
      destinationLatitude: number('destinationLatitude'),
      destinationLongitude: number('destinationLongitude'),
      distance: number('distance'),
      fare: number('fare'),
      outsideServiceArea: released['outsideServiceArea'] == true,
      outOfTownFee: number('outOfTownFee') ?? 0,
      outOfTownKm: number('outOfTownKm') ?? 0,
      // Everyone who has refused this trip so far, so the passenger is not
      // handed back to a driver who already said no.
      declinedBy: {
        ...?(released['declinedBy'] as List?)?.whereType<String>(),
        ?declinedDriver,
      },
    );
  }

  /// Marks a dispatched queue entry (and its linked booking, if any) as
  /// completed. Payment is handled separately, after the trip ends — see
  /// [confirmPayment].
  Future<void> completeTrip({
    required String queueEntryId,
    String? bookingId,
  }) async {
    final batch = _firestore.batch();

    final entryRef = _firestore.collection('queueEntries').doc(queueEntryId);
    batch.update(entryRef, {
      'status': 'completed',
      'completedAt': FieldValue.serverTimestamp(),
    });

    if (bookingId != null) {
      final bookingRef = _firestore.collection('bookings').doc(bookingId);
      batch.update(bookingRef, {
        'status': 'completed',
        'completedAt': FieldValue.serverTimestamp(),
      });
    }

    await batch.commit();
  }

  /// Records that [bookingId] was paid via [paymentMethod] ('cash' or
  /// 'gcash') and generates its receipt. Called once payment is settled —
  /// by the passenger for GCash, or by the driver confirming cash received
  /// in person — which happens after the trip is marked completed.
  Future<void> confirmPayment({
    required String bookingId,
    required String paymentMethod,
  }) async {
    final bookingRef = _firestore.collection('bookings').doc(bookingId);
    final bookingSnap = await bookingRef.get();
    final bookingData = bookingSnap.data() ?? {};

    // Both fields, always. Writing only the legacy `paymentStatus` left
    // `paymentState` behind at UNPAID, and TripState prefers the new field —
    // so a payment confirmed here showed as paid on the admin dashboard
    // while the app still considered it unpaid and refused to let the trip
    // start.
    final trip = TripState.fromMap(bookingId, bookingData);

    await bookingRef.update({
      'paymentMethod': paymentMethod,
      'paymentState': PaymentState.paymentConfirmed.wire,
      'paymentStatus': PaymentState.paymentConfirmed.legacyPaymentStatus,
      'paidAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
      if (paymentMethod == 'cash') 'driverConfirmedPayment': true,
      if (paymentMethod == 'cash')
        'driverConfirmedAt': FieldValue.serverTimestamp(),
      // Settled payment means the trip is ready to start — but not started.
      // Mirrors what TripService.movePayment does, so both routes to a
      // confirmed payment leave the record in the same shape.
      if (trip.trip == TripStatus.driverArrived) ...{
        'tripStatus': TripStatus.readyToStart.wire,
        'status': TripStatus.readyToStart.legacyStatus,
      },
    });

    // The receipt is read back off the booking this writes, so it is made
    // from one place for every way a payment can settle. A receipt that
    // cannot be made must not report the payment as failed: it went through.
    await ReceiptService.instance.ensureReceiptQuietly(bookingId);
  }
}

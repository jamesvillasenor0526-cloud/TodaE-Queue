import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/trip_state.dart';
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
  }) async {
    const maxAttempts = 5;

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final candidateSnap = await _firestore
          .collection('queueEntries')
          .where('terminalId', isEqualTo: terminalId)
          .where('status', isEqualTo: 'waiting')
          .orderBy('checkedInAt')
          .orderBy('driverId')
          .limit(1)
          .get();

      if (candidateSnap.docs.isEmpty) {
        return DispatchResult.failure(
          'No drivers are currently waiting at this terminal.',
        );
      }

      final passengerDoc = await _firestore
          .collection('users')
          .doc(passengerId)
          .get();
      final passengerName = passengerDoc.data()?['name'] ?? 'Passenger';

      final candidateDoc = candidateSnap.docs.first;
      final candidateRef = candidateDoc.reference;
      final bookingRef = _firestore.collection('bookings').doc();

      final driverDoc = await _firestore
          .collection('users')
          .doc(candidateDoc.data()['driverId'])
          .get();
      final driverPhone = driverDoc.data()?['phone'] ?? '';

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
            'pickupFee': FareService.pickupFee,
            'paymentMethod': null,
            'paymentStatus': PaymentState.unpaid.legacyPaymentStatus,
            'driverPhone': driverPhone,
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

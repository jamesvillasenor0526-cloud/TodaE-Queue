import 'package:cloud_firestore/cloud_firestore.dart';

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
  }) async {
    const maxAttempts = 5;

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final candidateSnap = await _firestore
          .collection('queueEntries')
          .where('terminalId', isEqualTo: terminalId)
          .where('status', isEqualTo: 'waiting')
          .orderBy('checkedInAt')
          .limit(1)
          .get();

      if (candidateSnap.docs.isEmpty) {
        return DispatchResult.failure(
          'No drivers are currently waiting at this terminal.',
        );
      }

      final candidateDoc = candidateSnap.docs.first;
      final candidateRef = candidateDoc.reference;
      final bookingRef = _firestore.collection('bookings').doc();

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
          });

          tx.set(bookingRef, {
            'passengerId': passengerId,
            'driverId': data['driverId'],
            'driverName': data['driverName'],
            'terminalId': terminalId,
            'terminalName': data['terminalName'],
            'queueEntryId': candidateRef.id,
            'status': 'assigned',
            'createdAt': FieldValue.serverTimestamp(),
            'driverLatitude': null,
            'driverLongitude': null,
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
  /// completed, freeing the driver up to check in elsewhere.
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
}

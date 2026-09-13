/// Receipts for paid trips.
///
/// One receipt per trip, whoever settles the payment and however often this
/// is called: the receipt's id is the booking's, and it is written in the
/// same transaction as the booking's receipt number, so nothing can leave a
/// paid trip without a receipt. Two ways in used to miss:
///
///   * cash settled through the driver's trip panel never made one at all,
///     so the passenger's "View Receipt" never appeared;
///   * making the receipt and stamping the booking were separate writes, and
///     a failure between them left the trip paid with no receipt number —
///     three trips in the database are in exactly that state.
library;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../models/trip_state.dart';
import 'fare_service.dart';

class ReceiptService {
  static final ReceiptService instance = ReceiptService._();
  ReceiptService._();

  /// "TODA-20260912-8F3K2A" — the date it was paid and the trip it belongs
  /// to. Derived from the booking rather than the clock, so asking twice
  /// gives the same number.
  static String receiptNumberFor(String bookingId, DateTime paidAt) {
    final date =
        '${paidAt.year}'
        '${paidAt.month.toString().padLeft(2, '0')}'
        '${paidAt.day.toString().padLeft(2, '0')}';
    final tail = bookingId.length >= 6 ? bookingId.substring(0, 6) : bookingId;
    return 'TODA-$date-${tail.toUpperCase()}';
  }

  /// The receipt number for [bookingId], making the receipt if the trip is
  /// paid and has none. Returns null when there is nothing to receipt yet.
  ///
  /// Safe to call at any time and from either app: an unpaid trip, a trip
  /// that already has a receipt, and a missing booking all return without
  /// writing.
  Future<String?> ensureReceipt(String bookingId) async {
    final db = FirebaseFirestore.instance;
    final bookingRef = db.collection('bookings').doc(bookingId);

    // A receipt made by an older version of the app has a random id. Adopt
    // it rather than writing a second receipt for the same trip.
    String? existingNumber;
    try {
      final older = await db
          .collection('receipts')
          .where('bookingId', isEqualTo: bookingId)
          .limit(1)
          .get();
      if (older.docs.isNotEmpty) {
        existingNumber = older.docs.first.data()['receiptNumber'] as String?;
      }
    } catch (e) {
      debugPrint('Receipt: could not check for an existing one: $e');
    }

    return db.runTransaction<String?>((tx) async {
      final snap = await tx.get(bookingRef);
      final booking = snap.data();
      if (booking == null) return null;

      final onBooking = booking['receiptNumber'] as String?;
      if (onBooking != null && onBooking.isNotEmpty) return onBooking;

      final state = TripState.fromMap(bookingId, booking);
      if (!state.payment.isSettled) return null; // nothing to receipt yet

      if (existingNumber != null) {
        // The receipt exists; only the booking never learned its number.
        tx.update(bookingRef, {'receiptNumber': existingNumber});
        return existingNumber;
      }

      final paidAt = booking['paidAt'];
      final number = receiptNumberFor(
        bookingId,
        paidAt is Timestamp ? paidAt.toDate() : DateTime.now(),
      );
      double amount(String key, [double fallback = 0]) =>
          (booking[key] as num?)?.toDouble() ?? fallback;

      tx.set(db.collection('receipts').doc(bookingId), {
        'receiptId': bookingId,
        'receiptNumber': number,
        'bookingId': bookingId,
        'passengerId': booking['passengerId'] ?? '',
        'passengerName': booking['passengerName'] ?? 'Passenger',
        'driverId': booking['driverId'] ?? '',
        'driverName': booking['driverName'] ?? 'Driver',
        'terminalName': booking['terminalName'] ?? 'Terminal',
        'pickupLatitude': amount('pickupLatitude'),
        'pickupLongitude': amount('pickupLongitude'),
        'destinationLatitude': amount('destinationLatitude'),
        'destinationLongitude': amount('destinationLongitude'),
        'distance': amount('distance'),
        'fare': amount('fare'),
        // The booking's own figures first: a receipt records what this trip
        // was charged, not what the rates happen to be today.
        'pickupFee': amount('pickupFee', FareService.instance.currentPickupFee),
        'baseFare': amount('baseFare', FareService.instance.currentMinimumFare),
        'paymentMethod': booking['paymentMethod'] ?? 'cash',
        'paymentStatus': 'paid',
        'driverConfirmed': booking['driverConfirmedPayment'] == true,
        'createdAt': FieldValue.serverTimestamp(),
      });
      tx.update(bookingRef, {'receiptNumber': number});
      return number;
    });
  }

  /// As [ensureReceipt], but never throws: for callers where a missing
  /// receipt must not undo a payment that has already gone through. The
  /// next time the trip is opened, it is made.
  Future<void> ensureReceiptQuietly(String bookingId) async {
    try {
      await ensureReceipt(bookingId);
    } catch (e) {
      debugPrint('Receipt: not made for $bookingId yet: $e');
    }
  }

  Future<void> driverConfirmPayment(String receiptId) async {
    await FirebaseFirestore.instance
        .collection('receipts')
        .doc(receiptId)
        .update({
          'driverConfirmed': true,
          'confirmedAt': FieldValue.serverTimestamp(),
        });
  }
}

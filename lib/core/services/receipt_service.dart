import 'package:cloud_firestore/cloud_firestore.dart';

class ReceiptService {
  static final ReceiptService instance = ReceiptService._();
  ReceiptService._();

  String _generateReceiptNumber() {
    final now = DateTime.now();
    final dateStr =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
    final random = now.millisecondsSinceEpoch.toString().substring(7);
    return 'TODA-$dateStr-$random';
  }

  Future<String> generateReceipt({
    required String bookingId,
    required String passengerId,
    required String passengerName,
    required String driverId,
    required String driverName,
    required String terminalName,
    required double pickupLat,
    required double pickupLng,
    required double destinationLat,
    required double destinationLng,
    required double distance,
    required double fare,
    required String paymentMethod,
    required double pickupFee,
    required double baseFare,
  }) async {
    final receiptNumber = _generateReceiptNumber();
    final receiptRef = FirebaseFirestore.instance.collection('receipts').doc();

    await receiptRef.set({
      'receiptId': receiptRef.id,
      'receiptNumber': receiptNumber,
      'bookingId': bookingId,
      'passengerId': passengerId,
      'passengerName': passengerName,
      'driverId': driverId,
      'driverName': driverName,
      'terminalName': terminalName,
      'pickupLatitude': pickupLat,
      'pickupLongitude': pickupLng,
      'destinationLatitude': destinationLat,
      'destinationLongitude': destinationLng,
      'distance': distance,
      'fare': fare,
      'pickupFee': pickupFee,
      'baseFare': baseFare,
      'paymentMethod': paymentMethod,
      'paymentStatus': 'paid',
      'driverConfirmed': false,
      'createdAt': FieldValue.serverTimestamp(),
    });

    return receiptNumber;
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

  Future<void> updateBookingWithReceipt({
    required String bookingId,
    required String receiptNumber,
  }) async {
    await FirebaseFirestore.instance
        .collection('bookings')
        .doc(bookingId)
        .update({'receiptNumber': receiptNumber});
  }
}

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../config/theme.dart';
import '../../core/services/fare_service.dart';

class ReceiptScreen extends StatelessWidget {
  final String bookingId;

  const ReceiptScreen({super.key, required this.bookingId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Receipt')),
      body: FutureBuilder<QuerySnapshot>(
        future: FirebaseFirestore.instance
            .collection('receipts')
            .where('bookingId', isEqualTo: bookingId)
            .limit(1)
            .get(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            return const Center(child: Text('Receipt not found.'));
          }

          final receipt =
              snapshot.data!.docs.first.data() as Map<String, dynamic>;
          final fare = (receipt['fare'] as num?)?.toDouble() ?? 0;
          final baseFare =
              (receipt['baseFare'] as num?)?.toDouble() ??
              FareService.minimumFare;
          // Everything above the base: the kilometres after the first, and
          // any out-of-town charge. Base plus this is always the total.
          final distanceCharge = fare > baseFare ? fare - baseFare : 0.0;

          return SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Center(
                  child: Column(
                    children: [
                      Container(
                        width: 60,
                        height: 60,
                        decoration: BoxDecoration(
                          color: AppTheme.primaryGreen,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(
                          Icons.receipt_long,
                          color: Colors.white,
                          size: 32,
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'TODA E-QUEUE+',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Text(
                        'Federation of Baliwag City TODA',
                        style: TextStyle(
                          fontSize: 11,
                          color: AppTheme.textMuted,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Receipt No: ${receipt['receiptNumber'] ?? 'N/A'}',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),

                const Divider(height: 32),

                // Date & Time
                _receiptRow(
                  'Date',
                  receipt['createdAt'] != null
                      ? (receipt['createdAt'] as Timestamp)
                            .toDate()
                            .toString()
                            .substring(0, 10)
                      : 'N/A',
                ),
                const SizedBox(height: 4),
                _receiptRow(
                  'Time',
                  receipt['createdAt'] != null
                      ? (receipt['createdAt'] as Timestamp)
                            .toDate()
                            .toString()
                            .substring(11, 16)
                      : 'N/A',
                ),

                const Divider(height: 24),

                // Trip Details
                _receiptRow('Driver', receipt['driverName'] ?? 'N/A'),
                const SizedBox(height: 4),
                _receiptRow('Passenger', receipt['passengerName'] ?? 'N/A'),
                const SizedBox(height: 4),
                _receiptRow('Terminal', receipt['terminalName'] ?? 'N/A'),

                const Divider(height: 24),

                // Location
                _receiptRow(
                  'Pickup',
                  '${receipt['pickupLatitude']?.toStringAsFixed(4)}, ${receipt['pickupLongitude']?.toStringAsFixed(4)}',
                ),
                const SizedBox(height: 4),
                _receiptRow(
                  'Destination',
                  '${receipt['destinationLatitude']?.toStringAsFixed(4)}, ${receipt['destinationLongitude']?.toStringAsFixed(4)}',
                ),
                const SizedBox(height: 4),
                _receiptRow(
                  'Distance',
                  '${receipt['distance']?.toStringAsFixed(1) ?? '0'} km',
                ),

                const Divider(height: 24),

                // Fare Breakdown. The fallbacks below are the rates from
                // before rates could be set, which is exactly what the
                // receipts missing these fields were charged at — not
                // today's rates, which would misstate an old trip.
                //
                // No pick-up fee line. One was printed — ₱15 — but never
                // charged: it was carved out of the distance charge, so a
                // short trip showed a negative "Additional". Old receipts
                // still carry the field; it is ignored for the same reason.
                _receiptRow('Base Fare', '₱${baseFare.toStringAsFixed(0)}'),
                if (distanceCharge > 0) ...[
                  const SizedBox(height: 4),
                  _receiptRow(
                    'Distance Charge',
                    '₱${distanceCharge.toStringAsFixed(0)}',
                  ),
                ],
                const Divider(height: 16),
                _receiptRow(
                  'TOTAL',
                  '₱${receipt['fare']?.toStringAsFixed(0) ?? '0'}',
                ),

                const Divider(height: 24),

                // Payment
                _receiptRow(
                  'Payment Method',
                  receipt['paymentMethod'] == 'gcash' ? 'GCash' : 'Cash',
                ),
                const SizedBox(height: 4),
                _receiptRow(
                  'Status',
                  receipt['paymentStatus'] == 'paid' ? 'Paid' : 'Pending',
                ),
                const SizedBox(height: 4),
                if (receipt['driverConfirmed'] == true)
                  _receiptRow('Driver Confirmed', 'Yes')
                else
                  _receiptRow('Driver Confirmed', 'Waiting'),

                const Divider(height: 32),

                // Footer
                const Center(
                  child: Column(
                    children: [
                      Text(
                        'Thank you for riding!',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'This receipt is digitally generated.',
                        style: TextStyle(
                          fontSize: 10,
                          color: AppTheme.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _receiptRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(color: AppTheme.textMuted, fontSize: 13),
        ),
        Text(
          value,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
        ),
      ],
    );
  }
}

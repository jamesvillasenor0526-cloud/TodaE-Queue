import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../config/theme.dart';
import '../../../core/services/dispatch_service.dart';
import '../../../core/services/fare_service.dart';

class PaymentScreen extends StatefulWidget {
  final String bookingId;
  final String driverId;
  final String driverName;
  final double fare;
  final double distance;
  final String terminalName;

  const PaymentScreen({
    super.key,
    required this.bookingId,
    required this.driverId,
    required this.driverName,
    required this.fare,
    required this.distance,
    required this.terminalName,
  });

  @override
  State<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends State<PaymentScreen> {
  bool _isConfirming = false;

  Future<void> _confirmPayment() async {
    setState(() => _isConfirming = true);
    try {
      await DispatchService.instance.confirmPayment(
        bookingId: widget.bookingId,
        paymentMethod: 'gcash',
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isConfirming = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not confirm payment: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('GCash Payment'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context, false),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            // Fare summary
            Card(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    const Text(
                      '💳 Pay via GCash',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    _infoRow('Driver', widget.driverName),
                    const SizedBox(height: 8),
                    _infoRow('Terminal', widget.terminalName),
                    const SizedBox(height: 8),
                    _infoRow(
                      'Distance',
                      '${widget.distance.toStringAsFixed(2)} km',
                    ),
                    const Divider(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Total Fare',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          FareService.instance.formatFare(widget.fare),
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.primaryGreen,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),

            // GCash QR Code
            FutureBuilder<DocumentSnapshot>(
              future: FirebaseFirestore.instance
                  .collection('users')
                  .doc(widget.driverId)
                  .get(),
              builder: (context, driverSnap) {
                final gcashQrUrl =
                    driverSnap.data?.data() != null
                        ? (driverSnap.data!.data() as Map<String, dynamic>)['gcashQrUrl']
                              as String?
                        : null;

                if (gcashQrUrl == null) {
                  return Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.orange.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Column(
                      children: [
                        Icon(Icons.warning, color: AppTheme.warning, size: 48),
                        SizedBox(height: 12),
                        Text(
                          'Driver has no GCash QR code.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppTheme.warning, fontSize: 14),
                        ),
                        SizedBox(height: 8),
                        Text(
                          'Please ask the driver for their GCash number.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
                        ),
                      ],
                    ),
                  );
                }

                return Card(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      children: [
                        const Text(
                          'Scan GCash QR Code',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Image.network(
                          gcashQrUrl,
                          height: 250,
                          fit: BoxFit.contain,
                          errorBuilder: (context, error, stackTrace) {
                            return const Icon(
                              Icons.qr_code,
                              size: 100,
                              color: AppTheme.textMuted,
                            );
                          },
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Open GCash app → Scan QR → Pay',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 24),

            // Confirm Payment Button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _isConfirming ? null : _confirmPayment,
                icon: _isConfirming
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.check_circle),
                label: Text(
                  _isConfirming ? 'Confirming...' : 'I\'ve Paid',
                  style: const TextStyle(fontSize: 16, color: Colors.white),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryGreen,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '* Payment must be completed before the driver arrives',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.errorRed, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(color: AppTheme.textMuted, fontSize: 13)),
        Text(
          value,
          style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
        ),
      ],
    );
  }
}

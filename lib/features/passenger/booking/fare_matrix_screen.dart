import 'package:flutter/material.dart';
import '../../../config/theme.dart';
import '../../../core/models/fare_rates.dart';
import '../../../core/services/fare_service.dart';

/// The fares in force, as the dashboard last set them.
///
/// Every amount here comes from [FareService] — the same rates and the same
/// arithmetic a booking is charged with. This screen used to print ₱35 and
/// ₱10/km as fixed text, so a fare change in the dashboard never showed up
/// here while every actual booking was charged the new rates.
class FareMatrixScreen extends StatelessWidget {
  const FareMatrixScreen({super.key});

  /// The distances the sample fares are shown for.
  static const List<int> _sampleKm = [1, 2, 3, 4, 5, 10];

  @override
  Widget build(BuildContext context) {
    final fares = FareService.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Fare Matrix')),
      body: ValueListenableBuilder<FareRates>(
        // Redrawn the moment new rates arrive, even with the screen open.
        valueListenable: fares.ratesListenable,
        builder: (context, rates, _) => SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              const Center(
                child: Column(
                  children: [
                    Icon(
                      Icons.monetization_on,
                      size: 48,
                      color: AppTheme.primaryGreen,
                    ),
                    SizedBox(height: 8),
                    Text(
                      'TODA E-QUEUE+ FARE MATRIX',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      'Federation of Baliwag City TODA',
                      style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),

              _rateCard(
                title: '🚩 Base Fare',
                label: 'Minimum Fare (first 1 km)',
                value: _money(rates.minimumFare),
              ),
              const SizedBox(height: 16),
              _rateCard(
                title: '📏 Additional Distance',
                label: 'Per additional kilometer',
                value: '${_money(rates.ratePerKm)}/km',
              ),
              const SizedBox(height: 16),

              // Examples, worked out exactly as a booking is.
              Card(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '📋 Sample Fares',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 16),
                      for (final km in _sampleKm) ...[
                        _sampleFare(
                          km == 1 ? '0 - 1 km' : '$km km',
                          fares.formatFare(
                            fares.calculateFareFromDistance(km.toDouble()),
                          ),
                        ),
                        if (km != _sampleKm.last) const SizedBox(height: 8),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Note
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.info_outline, color: AppTheme.warning, size: 16),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Fares are computed from the road distance: terminal '
                        'to pick-up to destination. Trips that leave Baliwag '
                        'are charged the kilometres outside town twice, for '
                        'the driver\'s return.',
                        style: TextStyle(fontSize: 11, color: AppTheme.warning),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Two decimals, as a fare table is usually printed.
  static String _money(double v) => '₱${v.toStringAsFixed(2)}';

  Widget _rateCard({
    required String title,
    required String label,
    required String value,
  }) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(label, style: const TextStyle(color: AppTheme.textMuted)),
                Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _sampleFare(String distance, String fare) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(distance, style: const TextStyle(color: AppTheme.textMuted)),
        Text(
          fare,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
      ],
    );
  }
}

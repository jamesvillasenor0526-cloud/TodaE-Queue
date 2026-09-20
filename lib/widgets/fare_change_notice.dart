/// Tells the person the fare rates just changed.
///
/// A phone follows the rates live, so a passenger could open the app at one
/// price and book at another without being told. This says what moved, on
/// the screen they are already looking at, until they dismiss it — the
/// system notification only arrives if they allowed notifications.
library;

import 'package:flutter/material.dart';

import '../config/routes.dart';
import '../config/theme.dart';
import '../core/services/fare_settings_service.dart';

class FareChangeNotice extends StatelessWidget {
  const FareChangeNotice({super.key});

  @override
  Widget build(BuildContext context) {
    final fares = FareSettingsService.instance;
    return ValueListenableBuilder<String?>(
      valueListenable: fares.announcement,
      builder: (context, what, _) {
        if (what == null || what.isEmpty) return const SizedBox.shrink();
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.info.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.info.withValues(alpha: 0.35)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.campaign_outlined, color: AppTheme.info),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Fares have changed',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$what. The new fare applies to your next booking.',
                      style: const TextStyle(fontSize: 13),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        TextButton(
                          onPressed: () {
                            fares.announced();
                            Navigator.pushNamed(context, AppRoutes.fareMatrix);
                          },
                          child: const Text('See the fares'),
                        ),
                        TextButton(
                          onPressed: fares.announced,
                          child: const Text('Dismiss'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

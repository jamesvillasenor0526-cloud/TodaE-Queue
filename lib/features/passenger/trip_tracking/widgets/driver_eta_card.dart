/// What the passenger sees of the driver's navigation.
///
/// Reads the same booking document the driver writes to, so the ETA, the
/// route and the driver's position update on their own. There is no refresh
/// button because there is nothing to refresh — this is a live listener on
/// the shared record.
///
/// Deliberately read-only. The passenger gets the information that answers
/// "when will they get here?" and none of the driver's controls.
library;

import 'package:flutter/material.dart';

import '../../../../config/theme.dart';
import '../../../../core/models/navigation_state.dart';
import '../../../../core/models/road_report.dart';
import '../../../../core/models/trip_state.dart';
import '../../../../core/services/navigation_service.dart';

class DriverEtaCard extends StatelessWidget {
  const DriverEtaCard({
    super.key,
    required this.bookingId,
    required this.trip,
    this.incidentsAhead = const [],
  });

  final String bookingId;
  final TripState trip;

  /// Reports the passenger's map already knows about, so a warning can be
  /// shown without opening a second listener.
  final List<RoadReport> incidentsAhead;

  @override
  Widget build(BuildContext context) {
    final phase = NavigationPhase.forTrip(trip.trip);
    if (!phase.isNavigating) return const SizedBox.shrink();

    return StreamBuilder<TripNavigation>(
      stream: NavigationService.instance.watch(bookingId),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const _Line(
            icon: Icons.cloud_off,
            colour: AppTheme.warning,
            text: 'Connection lost — this will update when it returns.',
          );
        }

        final nav = snapshot.data;
        if (nav == null || nav.eta == null) {
          return const _Line(
            icon: Icons.schedule,
            colour: AppTheme.textMuted,
            text: 'Working out your driver\'s arrival time…',
          );
        }

        final now = DateTime.now();
        final stale = nav.isStale(now);
        final heading = phase == NavigationPhase.toPickup
            ? 'Driver is ${formatEta(nav.eta!)} away'
            : 'Arriving in ${formatEta(nav.eta!)}';

        return Container(
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: AppTheme.borderLight),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.electric_rickshaw,
                    color: AppTheme.primaryBlue,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      heading,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              if (nav.remainingMeters != null) ...[
                const SizedBox(height: AppSpacing.xs),
                Text(
                  'Distance: ${formatDistance(nav.remainingMeters!)}',
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppTheme.textMuted,
                  ),
                ),
              ],

              // A frozen dot with a confident ETA beside it is worse than
              // saying the signal dropped.
              if (stale) ...[
                const SizedBox(height: AppSpacing.sm),
                const _Line(
                  icon: Icons.gps_off,
                  colour: AppTheme.warning,
                  text: 'Waiting for a fresh location from your driver.',
                ),
              ],

              if (nav.rerouteMessage != null) ...[
                const SizedBox(height: AppSpacing.sm),
                _Line(
                  icon: Icons.alt_route,
                  colour: AppTheme.primaryBlue,
                  text: nav.rerouteMessage!,
                ),
              ],

              if (incidentsAhead.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.sm),
                _IncidentLine(reports: incidentsAhead),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _IncidentLine extends StatelessWidget {
  const _IncidentLine({required this.reports});
  final List<RoadReport> reports;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final incidents = groupIncidents(reports, now: now);
    if (incidents.isEmpty) return const SizedBox.shrink();
    final worst = incidents.first;
    return _Line(
      icon: worst.type.icon,
      colour: worst.type.color,
      text: '${worst.type.label} reported nearby · ${worst.summary(now)}',
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({
    required this.icon,
    required this.colour,
    required this.text,
  });

  final IconData icon;
  final Color colour;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: colour),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(text, style: TextStyle(fontSize: 13, color: colour)),
        ),
      ],
    );
  }
}

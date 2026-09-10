/// The driver's navigation strip under the trip card.
///
/// One view of [LiveNavigation], which owns the GPS and the route; the
/// full-screen [LiveNavigationScreen] is another. This panel holds the
/// session open while a trip is on screen, and offers the way into
/// full-screen navigation.
///
/// It deliberately does **not** touch the trip state machine. When the
/// driver arrives it says so and offers the action; pressing it calls
/// TripService, which is the only thing that moves `tripStatus`. GPS alone
/// never completes a trip.
library;

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../config/theme.dart';
import '../../../core/models/live_route.dart';
import '../../../core/models/navigation_state.dart';
import '../../../core/models/road_report.dart';
import '../../../core/models/trip_state.dart';
import '../../../core/services/voice_service.dart';
import '../../shared/reports/quick_report_sheet.dart';
import 'live_navigation.dart';
import 'live_navigation_screen.dart';

class NavigationPanel extends StatefulWidget {
  const NavigationPanel({
    super.key,
    required this.bookingId,
    required this.trip,
    required this.booking,
  });

  final String bookingId;
  final TripState trip;
  final Map<String, dynamic> booking;

  @override
  State<NavigationPanel> createState() => _NavigationPanelState();
}

class _NavigationPanelState extends State<NavigationPanel> {
  final LiveNavigation _nav = LiveNavigation.instance;

  NavigationPhase get _phase => NavigationPhase.forTrip(widget.trip.trip);

  @override
  void initState() {
    super.initState();
    // The session owns the GPS and the route; this panel is one view of it,
    // and the full-screen navigation is another.
    _nav.hold(
      bookingId: widget.bookingId,
      trip: widget.trip,
      booking: widget.booking,
    );
  }

  @override
  void didUpdateWidget(covariant NavigationPanel old) {
    super.didUpdateWidget(old);
    _nav.update(widget.trip, widget.booking);
  }

  @override
  void dispose() {
    _nav.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_phase.isNavigating) return _PhaseNotice(phase: _phase);
    return ListenableBuilder(listenable: _nav, builder: _buildLive);
  }

  Widget _buildLive(BuildContext context, Widget? _) {
    final route = _nav.route;
    final position = _nav.position;
    final remaining = _nav.remaining;
    final metres = _nav.remainingMeters;
    final upcoming = _nav.upcoming;
    final choices = _nav.choices;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_nav.banner != null) _Banner(text: _nav.banner!),
        Container(
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
                  Icon(
                    _phase == NavigationPhase.toPickup
                        ? Icons.person_pin_circle
                        : Icons.flag,
                    size: 18,
                    color: AppTheme.primaryBlue,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      _phase.driverLabel,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (_nav.working)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  const _VoiceToggle(),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),

              if (_nav.arrived)
                // The prompt only tells the driver they are here. Advancing
                // the trip stays a deliberate action elsewhere in the UI.
                const _ArrivedNotice()
              else if (route == null || position == null)
                const Text(
                  'Getting your route…',
                  style: TextStyle(color: AppTheme.textMuted),
                )
              else ...[
                _EtaRow(
                  remaining: remaining ?? Duration.zero,
                  meters: metres ?? 0,
                  delays: route.penaltySeconds > 0,
                  estimatedRoad: route.route.hasEstimatedTime,
                ),
                if (choices?.blocked != null) ...[
                  const SizedBox(height: AppSpacing.sm),
                  _BlockedNote(text: choices!.blocked!.conditionLabel),
                ],
                if (upcoming != null) ...[
                  const SizedBox(height: AppSpacing.sm),
                  _NextTurn(turn: upcoming),
                ],
                if (!route.route.isRealRoute) ...[
                  const SizedBox(height: AppSpacing.sm),
                  const _RoutingUnavailable(),
                ],
                if (route.incidentsOnRoute.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.sm),
                  _AheadWarning(reports: route.incidentsOnRoute),
                ],
                if (choices?.hasAlternative ?? false) ...[
                  const SizedBox(height: AppSpacing.sm),
                  _AlternativeOffer(
                    choices: choices!,
                    isActive: _nav.isActiveChoice,
                    onUse: _nav.useRoute,
                  ),
                ],
              ],

              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 48,
                      child: FilledButton.icon(
                        onPressed: route == null
                            ? null
                            : () => LiveNavigationScreen.open(context),
                        icon: const Icon(Icons.navigation),
                        label: const Text(
                          'Navigate',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: SizedBox(
                      height: 48,
                      child: OutlinedButton.icon(
                        onPressed: () => showQuickReportSheet(
                          context,
                          tripId: widget.bookingId,
                          at: position,
                        ),
                        icon: const Icon(Icons.add_alert),
                        label: const Text(
                          'Report',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppTheme.warning,
                          side: const BorderSide(
                            color: AppTheme.warning,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _EtaRow extends StatelessWidget {
  const _EtaRow({
    required this.remaining,
    required this.meters,
    required this.delays,
    required this.estimatedRoad,
  });
  final Duration remaining;
  final double meters;

  /// Reported delays on the route are part of the time.
  final bool delays;

  /// The route's own time is estimated — local roads TomTom does not have.
  final bool estimatedRoad;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          formatEta(remaining),
          style: const TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.bold,
            color: AppTheme.primaryGreen,
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                formatDistance(meters),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              Text(
                // Said plainly, and precisely: which part of the time is
                // this app's own estimate rather than measured traffic.
                // It used to say "Includes reported delays" for a route with
                // none, because its time was estimated for another reason.
                delays
                    ? 'Includes reported delays'
                    : estimatedRoad
                    ? 'Estimated time · local roads'
                    : 'Clear route',
                style: const TextStyle(
                  fontSize: 11,
                  color: AppTheme.textMuted,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Why the shorter-looking way is not the one being driven.
class _BlockedNote extends StatelessWidget {
  const _BlockedNote({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      const Icon(Icons.block, size: 16, color: AppTheme.errorRed),
      const SizedBox(width: AppSpacing.sm),
      Expanded(
        child: Text(
          'Shorter way not used: $text',
          style: const TextStyle(fontSize: 12, color: AppTheme.errorRed),
        ),
      ),
    ],
  );
}

/// Mutes and unmutes spoken guidance.
///
/// Deliberately in the navigation strip rather than buried in settings: a
/// driver who wants the voice off wants it off now, with one thumb, while
/// driving.
class _VoiceToggle extends StatelessWidget {
  const _VoiceToggle();

  @override
  Widget build(BuildContext context) {
    final voice = VoiceService.instance;
    return ListenableBuilder(
      listenable: voice,
      builder: (context, _) => IconButton(
        onPressed: () => voice.setEnabled(!voice.enabled),
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        tooltip: voice.enabled ? 'Mute voice guidance' : 'Unmute voice guidance',
        icon: Icon(
          voice.enabled ? Icons.volume_up : Icons.volume_off,
          size: 20,
          color: voice.enabled ? AppTheme.primaryBlue : AppTheme.textMuted,
        ),
      ),
    );
  }
}

class _NextTurn extends StatelessWidget {
  const _NextTurn({required this.turn});
  final UpcomingTurn turn;

  /// Matches the instruction, so the arrow does not point right while the
  /// text says left.
  IconData get _icon => switch (turn.step.modifier) {
    'left' || 'slight left' || 'sharp left' => Icons.turn_left,
    'right' || 'slight right' || 'sharp right' => Icons.turn_right,
    'uturn' => Icons.u_turn_left,
    _ => turn.isArrival ? Icons.flag : Icons.straight,
  };

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(_icon, color: AppTheme.primaryBlue),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            turn.step.instruction,
            style: const TextStyle(fontSize: 15),
          ),
        ),
        Text(
          formatDistance(turn.metersAway),
          style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
        ),
      ],
    );
  }
}

class _AheadWarning extends StatelessWidget {
  const _AheadWarning({required this.reports});
  final List<RoadReport> reports;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final incidents = groupIncidents(reports, now: now);
    if (incidents.isEmpty) return const SizedBox.shrink();
    final worst = incidents.first;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: worst.type.color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        children: [
          Icon(worst.type.icon, size: 18, color: worst.type.color),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              '${worst.type.label} ahead · ${worst.summary(now)}',
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

/// The other way round, offered as a choice rather than imposed.
///
/// Shows both routes with the numbers behind the recommendation — time,
/// distance and what has been reported on each — so the driver can see why
/// one is preferred instead of being told to trust it. A driver who knows
/// the roads may well disagree, and picking the other one sticks.
class _AlternativeOffer extends StatelessWidget {
  const _AlternativeOffer({
    required this.choices,
    required this.isActive,
    required this.onUse,
  });

  final RouteChoices choices;

  /// Whether a choice is the road being driven — judged by the road, since
  /// a route fetched again starts wherever the driver now is.
  final bool Function(RouteScore) isActive;
  final Future<void> Function(RouteScore) onUse;

  @override
  Widget build(BuildContext context) {
    if (!choices.hasAlternative) return const SizedBox.shrink();
    final onRecommended = isActive(choices.recommended);

    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: AppTheme.info.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppTheme.info.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.alt_route, size: 16, color: AppTheme.info),
              SizedBox(width: AppSpacing.xs),
              Text(
                'Another way',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.info,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          _RouteOption(
            score: choices.recommended,
            title: 'Fastest',
            selected: onRecommended,
            onUse: onRecommended ? null : () => onUse(choices.recommended),
          ),
          for (final alt in choices.alternatives) ...[
            const SizedBox(height: AppSpacing.xs),
            () {
              final selected = isActive(alt);
              return _RouteOption(
                score: alt,
                // The real difference, against the fastest — the same words
                // the labels on the map use.
                title: timeDifferenceLabel(
                  alternativeSeconds: alt.adjustedSeconds,
                  activeSeconds: choices.recommended.adjustedSeconds,
                  estimate: alt.isEstimate,
                ),
                selected: selected,
                onUse: selected ? null : () => onUse(alt),
              );
            }(),
          ],
        ],
      ),
    );
  }
}

class _RouteOption extends StatelessWidget {
  const _RouteOption({
    required this.score,
    required this.title,
    required this.selected,
    required this.onUse,
  });

  final RouteScore score;
  final String title;
  final bool selected;
  final VoidCallback? onUse;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
          size: 16,
          color: selected ? AppTheme.primaryGreen : AppTheme.textMuted,
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$title · ${formatEta(Duration(seconds: score.adjustedSeconds.round()))}'
                ' · ${formatDistance(score.route.distanceMeters)}',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
              Text(
                score.conditionLabel,
                style: const TextStyle(
                  fontSize: 11,
                  color: AppTheme.textMuted,
                ),
              ),
            ],
          ),
        ),
        if (onUse != null)
          TextButton(
            onPressed: onUse,
            style: TextButton.styleFrom(
              minimumSize: const Size(64, 40),
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
            ),
            child: const Text('Use'),
          ),
      ],
    );
  }
}

class _RoutingUnavailable extends StatelessWidget {
  const _RoutingUnavailable();

  @override
  Widget build(BuildContext context) {
    // Never dress a straight line up as a route — the driver has to know the
    // road guidance is missing, not follow a line through a river.
    return const Row(
      children: [
        Icon(Icons.cloud_off, size: 16, color: AppTheme.warning),
        SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            'Road directions unavailable — showing direct line only.',
            style: TextStyle(fontSize: 12, color: AppTheme.warning),
          ),
        ),
      ],
    );
  }
}

class _ArrivedNotice extends StatelessWidget {
  const _ArrivedNotice();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.check_circle, color: AppTheme.success),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            'You have arrived',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: AppTheme.success,
            ),
          ),
        ),
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppTheme.primaryBlue,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        children: [
          const Icon(Icons.alt_route, color: Colors.white, size: 20),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// What to show when there is nothing to navigate — at the pickup waiting on
/// payment, or once the trip is over.
class _PhaseNotice extends StatelessWidget {
  const _PhaseNotice({required this.phase});
  final NavigationPhase phase;

  @override
  Widget build(BuildContext context) {
    if (phase == NavigationPhase.idle) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppTheme.info.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: const Row(
        children: [
          Icon(Icons.pin_drop, color: AppTheme.info, size: 20),
          SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              'At the pickup point. Navigation resumes when the trip starts.',
              style: TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

/// Convenience for screens that already hold a booking snapshot.
class NavigationPanelFor extends StatelessWidget {
  const NavigationPanelFor({super.key, required this.bookingId});
  final String bookingId;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('bookings')
          .doc(bookingId)
          .snapshots(),
      builder: (context, snap) {
        final data = snap.data?.data();
        if (data == null) return const SizedBox.shrink();
        return NavigationPanel(
          bookingId: bookingId,
          trip: TripState.fromMap(bookingId, data),
          booking: data,
        );
      },
    );
  }
}

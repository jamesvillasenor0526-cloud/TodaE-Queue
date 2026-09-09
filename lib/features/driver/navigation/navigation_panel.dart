/// The driver's live navigation strip.
///
/// This is where the navigation loop actually runs: GPS fixes come in, the
/// shared trip record is updated, the route is re-checked against reported
/// conditions, and a reroute is applied when one is genuinely worth it.
///
/// It deliberately does **not** touch the trip state machine. When the
/// driver arrives it says so and offers the action; pressing it calls
/// TripService, which is the only thing that moves `tripStatus`. GPS alone
/// never completes a trip.
library;

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../../../config/theme.dart';
import '../../../core/models/navigation_state.dart';
import '../../../core/models/road_report.dart';
import '../../../core/models/trip_state.dart';
import '../../../core/services/navigation_service.dart';
import '../../shared/reports/quick_report_sheet.dart';

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
  StreamSubscription<Position>? _positions;
  LatLng? _position;
  RouteScore? _route;
  RouteChoices? _choices;
  String? _banner;
  bool _working = false;

  /// Guards against a slow reroute overlapping the next GPS fix.
  bool _busyRouting = false;

  NavigationPhase get _phase => NavigationPhase.forTrip(widget.trip.trip);

  LatLng? get _target =>
      NavigationService.targetFor(widget.trip, widget.booking);

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(covariant NavigationPanel old) {
    super.didUpdateWidget(old);
    // A new leg (pickup → destination) needs a fresh route, not the old one.
    if (old.trip.trip != widget.trip.trip) {
      NavigationService.instance.reset();
      _route = null;
      if (_phase.isNavigating) _recalculate();
    }
  }

  @override
  void dispose() {
    _positions?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return;
    }

    _positions =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 10,
          ),
        ).listen((p) => _onFix(LatLng(p.latitude, p.longitude)));

    // The stream only emits after the driver has moved [distanceFilter]
    // metres, so a phone sitting still produces nothing at all — and a
    // driver waiting at a terminal for a booking is exactly that. Without
    // this seed the panel stays on "Getting your route…" indefinitely.
    await _seedPosition();
  }

  /// Establishes a first position without waiting for movement.
  ///
  /// Tries the last known fix first because it returns instantly, then asks
  /// for a fresh one; either is enough to start routing.
  Future<void> _seedPosition() async {
    if (_position != null) return;
    try {
      final cached = await Geolocator.getLastKnownPosition();
      if (cached != null && mounted && _position == null) {
        await _onFix(LatLng(cached.latitude, cached.longitude));
      }
    } catch (_) {
      // No cached fix on this device yet; the live one below covers it.
    }

    try {
      final fresh = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      ).timeout(const Duration(seconds: 12));
      if (mounted) await _onFix(LatLng(fresh.latitude, fresh.longitude));
    } catch (_) {
      // Indoors or GPS denied. The panel keeps showing that it is still
      // working on the route rather than claiming a false one.
    }
  }

  Future<void> _onFix(LatLng position) async {
    if (!mounted) return;
    setState(() => _position = position);

    final target = _target;
    if (target == null || !_phase.isNavigating) return;
    if (_busyRouting) return;
    _busyRouting = true;

    try {
      final reason = await NavigationService.instance.onDriverMoved(
        bookingId: widget.bookingId,
        position: position,
        target: target,
        phase: _phase,
      );
      if (!mounted) return;
      setState(() {
        _route = NavigationService.instance.currentRoute;
        _choices = NavigationService.instance.choices;
        if (reason != RerouteReason.none) _banner = reason.message;
      });
      if (reason != RerouteReason.none) {
        // Clear the banner after it has been read, so it does not sit there
        // for the rest of the trip.
        Future.delayed(const Duration(seconds: 6), () {
          if (mounted) setState(() => _banner = null);
        });
      }
    } finally {
      _busyRouting = false;
    }
  }

  Future<void> _recalculate() async {
    final position = _position;
    final target = _target;
    if (position == null || target == null) return;

    setState(() => _working = true);
    final score = await NavigationService.instance.startLeg(
      bookingId: widget.bookingId,
      from: position,
      to: target,
    );
    if (!mounted) return;
    setState(() {
      _route = score;
      _choices = NavigationService.instance.choices;
      _working = false;
    });
  }

  /// Switches to the route the driver picked instead of the recommendation.
  Future<void> _useRoute(RouteScore route) async {
    final position = _position;
    if (position == null) return;

    setState(() => _working = true);
    await NavigationService.instance.useRoute(
      bookingId: widget.bookingId,
      route: route,
      from: position,
    );
    if (!mounted) return;
    setState(() {
      _route = route;
      _working = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_phase.isNavigating) return _PhaseNotice(phase: _phase);

    final route = _route;
    final position = _position;
    final target = _target;

    final arrived =
        position != null && target != null && hasArrived(position, target);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_banner != null) _Banner(text: _banner!),
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
                  if (_working)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),

              if (arrived)
                // The prompt only tells the driver they are here. Advancing
                // the trip stays a deliberate action elsewhere in the UI.
                const _ArrivedNotice()
              else if (route == null || position == null)
                const Text(
                  'Getting your route…',
                  style: TextStyle(color: AppTheme.textMuted),
                )
              else ...[
                _EtaRow(score: route, position: position),
                if (route.route.nextStep != null) ...[
                  const SizedBox(height: AppSpacing.sm),
                  _NextTurn(step: route.route.nextStep!),
                ],
                if (!route.route.isRealRoute) ...[
                  const SizedBox(height: AppSpacing.sm),
                  const _RoutingUnavailable(),
                ],
                if (route.incidentsOnRoute.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.sm),
                  _AheadWarning(reports: route.incidentsOnRoute),
                ],
                if (_choices?.hasAlternative ?? false) ...[
                  const SizedBox(height: AppSpacing.sm),
                  _AlternativeOffer(
                    choices: _choices!,
                    active: route,
                    onUse: _useRoute,
                  ),
                ],
              ],

              const SizedBox(height: AppSpacing.md),
              SizedBox(
                height: 48,
                child: OutlinedButton.icon(
                  onPressed: () => showQuickReportSheet(
                    context,
                    tripId: widget.bookingId,
                    at: _position,
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
                    side: const BorderSide(color: AppTheme.warning, width: 2),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _EtaRow extends StatelessWidget {
  const _EtaRow({required this.score, required this.position});
  final RouteScore score;
  final LatLng position;

  @override
  Widget build(BuildContext context) {
    final remaining = remainingDuration(score, position);
    final metres = remainingMeters(score.route, position);

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
                formatDistance(metres),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              Text(
                // Said plainly, because the delay part is this app's own
                // estimate rather than measured traffic.
                score.isEstimate
                    ? 'Includes reported delays'
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

class _NextTurn extends StatelessWidget {
  const _NextTurn({required this.step});
  final NavStep step;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.turn_right, color: AppTheme.primaryBlue),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            step.instruction,
            style: const TextStyle(fontSize: 15),
          ),
        ),
        Text(
          formatDistance(step.distanceMeters),
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
    required this.active,
    required this.onUse,
  });

  final RouteChoices choices;
  final RouteScore active;
  final Future<void> Function(RouteScore) onUse;

  @override
  Widget build(BuildContext context) {
    final alternative = choices.alternative;
    if (alternative == null) return const SizedBox.shrink();

    final onRecommended = active.route.sameRouteAs(choices.recommended.route);

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
            title: 'Recommended',
            selected: onRecommended,
            onUse: onRecommended ? null : () => onUse(choices.recommended),
          ),
          const SizedBox(height: AppSpacing.xs),
          _RouteOption(
            score: alternative,
            title: 'Alternative',
            selected: !onRecommended,
            onUse: !onRecommended ? null : () => onUse(alternative),
          ),
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

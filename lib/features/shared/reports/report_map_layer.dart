import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../../config/theme.dart';
import '../../../core/models/road_report.dart';
import '../../../core/services/report_service.dart';

/// Shades live traffic and incident reports onto a [FlutterMap] as coloured
/// congestion zones — strong red where conditions are bad, fading to a
/// slight green where they are clear.
///
/// Deliberately not pins: a scatter of individual markers reads as clutter
/// and says nothing about how bad a stretch of road actually is. Nearby
/// reports are blended into one zone instead, and the detail behind them is
/// reached through [showConditionsSheet].
///
/// Drop it into the map's `children` after the tile layer. The subscription
/// is owned here and re-centred only when [origin] moves meaningfully, so a
/// parent rebuilding for unrelated reasons doesn't churn the listener.
class TrafficOverlay extends StatefulWidget {
  const TrafficOverlay({
    super.key,
    required this.origin,
    this.radiusKm = 5,
    this.onReportsChanged,
  });

  final LatLng origin;
  final double radiusKm;

  /// Lets a parent show a count or open the conditions list without opening
  /// a second Firestore listener of its own.
  final ValueChanged<List<RoadReport>>? onReportsChanged;

  @override
  State<TrafficOverlay> createState() => _TrafficOverlayState();
}

class _TrafficOverlayState extends State<TrafficOverlay> {
  /// How far the origin must drift before the feed is re-centred. A driver's
  /// position updates every few seconds; resubscribing on each tick would
  /// tear down and rebuild the Firestore listener continuously. Well under
  /// the default radius, so the visible set stays correct.
  static const double _recentreThresholdKm = 1;

  late Stream<List<RoadReport>> _stream;
  late LatLng _subscribedOrigin;
  List<RoadReport>? _lastNotified;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(covariant TrafficOverlay old) {
    super.didUpdateWidget(old);
    final moved =
        distanceKm(_subscribedOrigin, widget.origin) > _recentreThresholdKm;
    if (moved || old.radiusKm != widget.radiusKm) {
      setState(_subscribe);
    }
  }

  void _subscribe() {
    _subscribedOrigin = widget.origin;
    _stream = ReportService.instance.watchNearby(
      _subscribedOrigin,
      radiusKm: widget.radiusKm,
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<RoadReport>>(
      stream: _stream,
      builder: (context, snapshot) {
        // A failed report feed must never take the map down with it — the
        // map is still useful without the overlay.
        final reports = snapshot.data ?? const <RoadReport>[];

        // Notified only on a genuinely new emission. Firing on every build
        // would loop if the parent calls setState from the callback.
        if (!identical(reports, _lastNotified)) {
          _lastNotified = reports;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) widget.onReportsChanged?.call(reports);
          });
        }

        final zones = buildCongestionZones(reports, now: DateTime.now());
        return CircleLayer(
          circles: [
            // A soft halo under each zone so neighbouring areas blend into
            // one another rather than reading as hard-edged discs.
            for (final z in zones)
              CircleMarker(
                point: z.center,
                radius: z.radiusMeters * 1.7,
                useRadiusInMeter: true,
                color: z.color.withValues(alpha: z.fillOpacity * 0.35),
                borderStrokeWidth: 0,
              ),
            for (final z in zones)
              CircleMarker(
                point: z.center,
                radius: z.radiusMeters,
                useRadiusInMeter: true,
                color: z.color.withValues(alpha: z.fillOpacity),
                borderColor: z.color.withValues(alpha: 0.7),
                borderStrokeWidth: 1.5,
              ),
          ],
        );
      },
    );
  }
}

/// A compact key explaining the overlay's colours, for placing over a map.
class TrafficLegend extends StatelessWidget {
  const TrafficLegend({super.key});

  static const _steps = <(String, double)>[
    ('Clear', 0.0),
    ('Light', 0.35),
    ('Moderate', 0.6),
    ('Heavy', 1.0),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        boxShadow: const [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 6,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (label, severity) in _steps) ...[
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: CongestionZone(
                  center: const LatLng(0, 0),
                  severity: severity,
                  radiusMeters: 0,
                  reports: const [],
                ).color,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 4),
            Text(label, style: const TextStyle(fontSize: 10)),
            if (label != _steps.last.$1) const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

/// The reports behind the overlay, grouped the same way the map groups them.
///
/// This is where corroborating and withdrawing a report lives now that the
/// map itself has no tappable pins.
Future<void> showConditionsSheet(
  BuildContext context,
  List<RoadReport> reports,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _ConditionsSheet(reports: reports),
  );
}

class _ConditionsSheet extends StatelessWidget {
  const _ConditionsSheet({required this.reports});
  final List<RoadReport> reports;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final zones = buildCongestionZones(reports, now: now)
      ..sort((a, b) => b.severity.compareTo(a.severity));

    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.35,
      maxChildSize: 0.92,
      expand: false,
      builder: (context, scrollController) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppRadius.lg),
          ),
        ),
        child: Column(
          children: [
            const SizedBox(height: AppSpacing.sm),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppTheme.borderLight,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Road conditions nearby',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Close',
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Expanded(
              child: zones.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(AppSpacing.xl),
                        child: Text(
                          'No conditions reported around here right now.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppTheme.textMuted),
                        ),
                      ),
                    )
                  : ListView.separated(
                      controller: scrollController,
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.lg,
                        0,
                        AppSpacing.lg,
                        AppSpacing.xl,
                      ),
                      itemCount: zones.length,
                      separatorBuilder: (_, _) =>
                          const SizedBox(height: AppSpacing.lg),
                      itemBuilder: (context, i) =>
                          _ZoneGroup(zone: zones[i], now: now),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ZoneGroup extends StatelessWidget {
  const _ZoneGroup({required this.zone, required this.now});
  final CongestionZone zone;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: zone.color,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Text(
              zone.label,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(width: AppSpacing.sm),
            Text(
              '${zone.reports.length} '
              '${zone.reports.length == 1 ? 'report' : 'reports'}',
              style: const TextStyle(
                fontSize: 12,
                color: AppTheme.textMuted,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        for (final r in zone.reports)
          _ReportRow(report: r, now: now),
      ],
    );
  }
}

class _ReportRow extends StatefulWidget {
  const _ReportRow({required this.report, required this.now});
  final RoadReport report;
  final DateTime now;

  @override
  State<_ReportRow> createState() => _ReportRowState();
}

class _ReportRowState extends State<_ReportRow> {
  bool _busy = false;
  bool _done = false;
  String? _error;

  Future<void> _run(Future<void> Function() action, String message) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _done = true;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } on ReportException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _busy = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Something went wrong. Please try again.';
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.report;
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final isMine = r.reportedBy == uid;
    final alreadyConfirmed = r.confirmedByUser(uid);

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Container(
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
                Icon(r.type.icon, size: 18, color: r.type.color),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    r.type.label,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  r.ageLabel(widget.now),
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppTheme.textMuted,
                  ),
                ),
              ],
            ),
            if (r.note != null && r.note!.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(r.note!, style: const TextStyle(fontSize: 13)),
            ],
            if (r.photoUrl != null) ...[
              const SizedBox(height: AppSpacing.sm),
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                child: Image.network(
                  r.photoUrl!,
                  height: 120,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stack) =>
                      const SizedBox.shrink(),
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.xs),
            Text(
              '${isMine ? 'You' : r.reporterName} · '
              '${r.confirmations == 0 ? 'no confirmations yet' : '${r.confirmations} confirmed'}',
              style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                _error!,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppTheme.errorRed,
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.sm),
            SizedBox(
              width: double.infinity,
              child: isMine
                  ? OutlinedButton.icon(
                      onPressed: _busy || _done
                          ? null
                          : () => _run(
                              () => ReportService.instance.clear(r.id),
                              'Report removed. Thanks for keeping it accurate.',
                            ),
                      icon: const Icon(Icons.check, size: 16),
                      label: Text(
                        _done ? 'Removed' : 'This is resolved — take it down',
                      ),
                    )
                  : OutlinedButton.icon(
                      onPressed: _busy || _done || alreadyConfirmed
                          ? null
                          : () => _run(
                              () => ReportService.instance.confirm(r.id),
                              'Thanks — your confirmation helps others.',
                            ),
                      icon: const Icon(Icons.thumb_up_outlined, size: 16),
                      label: Text(
                        _done || alreadyConfirmed
                            ? 'Confirmed'
                            : 'I can confirm this',
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

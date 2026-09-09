import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../../config/theme.dart';
import '../../../core/models/road_report.dart';
import '../../../core/models/traffic_segment.dart';
import '../../../core/services/report_service.dart';
import '../../../core/services/road_geometry_service.dart';
import '../../../core/services/traffic_incident_service.dart';

/// Paints live traffic and incident reports onto a [FlutterMap] as coloured
/// road segments — strong red where conditions are bad, fading to a slight
/// green where they are clear, the way a navigation app shows congestion.
///
/// Deliberately not pins: a scatter of individual markers reads as clutter
/// and says nothing about how bad a stretch of road actually is. Nearby
/// reports are blended into one zone, that zone is snapped onto the real
/// road beneath it, and the detail behind it is reached through
/// [showConditionsSheet].
///
/// Road shapes come from OpenStreetMap and may be slow or unavailable, so
/// zones with no road resolved yet are shaded as soft areas instead. That is
/// also what the map shows on first paint, before the geometry arrives.
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

  /// Road shapes resolved so far. Empty until Overpass answers, which is why
  /// the zone shading has to stand on its own as a first paint.
  List<RoadWay> _ways = const [];
  String? _resolvedFor;

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
        _resolveGeometry(zones);

        final (:segments, :unplaced) = buildTrafficSegments(zones, _ways);

        return Stack(
          children: [
            if (unplaced.isNotEmpty)
              CircleLayer(
                circles: [
                  // A soft halo so a zone with no road under it still reads
                  // as an area rather than a hard-edged disc.
                  for (final z in unplaced)
                    CircleMarker(
                      point: z.center,
                      radius: z.radiusMeters * 1.7,
                      useRadiusInMeter: true,
                      color: z.color.withValues(alpha: z.fillOpacity * 0.35),
                      borderStrokeWidth: 0,
                    ),
                  for (final z in unplaced)
                    CircleMarker(
                      point: z.center,
                      radius: z.radiusMeters,
                      useRadiusInMeter: true,
                      color: z.color.withValues(alpha: z.fillOpacity),
                      borderColor: z.color.withValues(alpha: 0.7),
                      borderStrokeWidth: 1.5,
                    ),
                ],
              ),
            if (segments.isNotEmpty) ...[
              // A dark casing under the colour, so a red road still reads as
              // a road against light tiles and busy backgrounds.
              PolylineLayer(
                polylines: [
                  for (final s in segments)
                    Polyline(
                      points: s.points,
                      strokeWidth: s.strokeWidth + 4,
                      color: Colors.black.withValues(alpha: 0.25),
                      strokeCap: StrokeCap.round,
                      strokeJoin: StrokeJoin.round,
                    ),
                ],
              ),
              PolylineLayer(
                polylines: [
                  for (final s in segments)
                    Polyline(
                      points: s.points,
                      strokeWidth: s.strokeWidth,
                      color: s.color,
                      strokeCap: StrokeCap.round,
                      strokeJoin: StrokeJoin.round,
                    ),
                ],
              ),
            ],

            // TomTom's measured incidents, under TODA's own so a driver's
            // local knowledge is never hidden behind them.
            _LiveTrafficLayer(origin: _subscribedOrigin),

            // Discrete incidents sit on top of the traffic shading as one
            // marker each, however many people reported them.
            _IncidentMarkers(reports: reports),
          ],
        );
      },
    );
  }

  /// Asks for the road shapes under [zones], once per distinct set.
  ///
  /// Fire-and-forget: the map has already painted the zone shading, and this
  /// upgrades it to road segments when (and if) the geometry arrives.
  void _resolveGeometry(List<CongestionZone> zones) {
    if (zones.isEmpty) return;
    final key = zones
        .map(
          (z) =>
              '${z.center.latitude.toStringAsFixed(3)},'
              '${z.center.longitude.toStringAsFixed(3)}',
        )
        .join('|');
    if (key == _resolvedFor) return;
    _resolvedFor = key;

    RoadGeometryService.instance.waysFor(zones).then((ways) {
      if (!mounted || ways.isEmpty) return;
      setState(() => _ways = ways);
    });
  }
}

/// TomTom's measured incidents, drawn along the roads they affect.
///
/// Deliberately quieter than the driver reports layered above it: these are
/// dashed and semi-transparent so the two never read as the same thing. A
/// report is somebody here saying what they can see; this is a measurement
/// from elsewhere, useful but impersonal, and the driver should be able to
/// tell which is which at a glance.
///
/// TomTom returns these as LineStrings along the road, so unlike a driver's
/// point report they need no snapping.
class _LiveTrafficLayer extends StatefulWidget {
  const _LiveTrafficLayer({required this.origin});

  final LatLng origin;

  @override
  State<_LiveTrafficLayer> createState() => _LiveTrafficLayerState();
}

class _LiveTrafficLayerState extends State<_LiveTrafficLayer> {
  List<TrafficIncident> _incidents = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _LiveTrafficLayer old) {
    super.didUpdateWidget(old);
    if (old.origin != widget.origin) _load();
  }

  Future<void> _load() async {
    // The service throttles and caches, so calling on every re-centre is
    // cheap and will not burn the daily quota.
    final found = await TrafficIncidentService.instance.near(widget.origin);
    if (!mounted) return;
    setState(() => _incidents = found);
  }

  @override
  Widget build(BuildContext context) {
    if (_incidents.isEmpty) return const SizedBox.shrink();

    return PolylineLayer(
      polylines: [
        for (final i in _incidents)
          if (i.points.length > 1)
            Polyline(
              points: i.points,
              strokeWidth: i.isSignificant ? 6 : 4,
              color: i.type.color.withValues(
                alpha: i.isSignificant ? 0.55 : 0.35,
              ),
              // Dashed, so measured traffic never looks like a report.
              pattern: StrokePattern.dashed(segments: const [10, 6]),
              strokeCap: StrokeCap.round,
            ),
      ],
    );
  }
}

/// One marker per incident, not per report.
///
/// Three drivers reporting the same accident must read as one accident that
/// three people have seen — the grouping is what turns a pile of reports
/// into information.
class _IncidentMarkers extends StatelessWidget {
  const _IncidentMarkers({required this.reports});
  final List<RoadReport> reports;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    // Traffic is already conveyed by the road shading, so only the discrete
    // things get a pin — otherwise every jam gets a marker on top of the
    // colour that already says the same thing.
    final incidents = groupIncidents(
      reports.where((r) => r.type.category == ReportCategory.incident),
      now: now,
    );

    return MarkerLayer(
      markers: [
        for (final incident in incidents)
          Marker(
            point: incident.location,
            width: 46,
            height: 46,
            child: _IncidentPin(
              incident: incident,
              now: now,
              onTap: () => showIncidentSheet(context, incident),
            ),
          ),
      ],
    );
  }
}

class _IncidentPin extends StatelessWidget {
  const _IncidentPin({
    required this.incident,
    required this.now,
    required this.onTap,
  });

  final Incident incident;
  final DateTime now;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final count = incident.reportCount;
    final status = incident.statusAt(now);

    return Semantics(
      button: true,
      label: '${incident.type.label}, $count reports',
      child: GestureDetector(
        onTap: onTap,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: incident.type.color,
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.white,
                  // A confirmed incident is drawn more solidly than one
                  // nobody has backed up yet.
                  width: status == IncidentStatus.confirmed ? 3 : 2,
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black26,
                    blurRadius: 4,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: Icon(incident.type.icon, color: Colors.white, size: 19),
            ),
            if (count > 1)
              Positioned(
                top: 0,
                right: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    border: Border.all(color: incident.type.color),
                  ),
                  child: Text(
                    '$count',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: incident.type.color,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Details behind one incident marker.
Future<void> showIncidentSheet(BuildContext context, Incident incident) {
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (_) => _IncidentSheet(incident: incident),
  );
}

class _IncidentSheet extends StatelessWidget {
  const _IncidentSheet({required this.incident});
  final Incident incident;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final status = incident.statusAt(now);

    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: incident.type.color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: Icon(incident.type.icon, color: incident.type.color),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      incident.type.label,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      incident.summary(now),
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppTheme.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              _Chip(
                icon: Icons.verified_outlined,
                label: status.label,
                colour: status == IncidentStatus.confirmed
                    ? AppTheme.success
                    : AppTheme.textMuted,
              ),
              _Chip(
                icon: Icons.people_outline,
                label: incident.reportCount == 1
                    ? '1 report'
                    : '${incident.reportCount} reports',
                colour: AppTheme.textMuted,
              ),
              _Chip(
                icon: Icons.place_outlined,
                label:
                    '${incident.location.latitude.toStringAsFixed(4)}, '
                    '${incident.location.longitude.toStringAsFixed(4)}',
                colour: AppTheme.textMuted,
              ),
            ],
          ),
          for (final note in incident.reports
              .map((r) => r.note)
              .whereType<String>()
              .where((n) => n.isNotEmpty)) ...[
            const SizedBox(height: AppSpacing.sm),
            Text('“$note”', style: const TextStyle(fontSize: 13)),
          ],
          const SizedBox(height: AppSpacing.lg),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () {
                Navigator.pop(context);
                showConditionsSheet(context, incident.reports);
              },
              icon: const Icon(Icons.list_alt, size: 18),
              label: const Text('See the reports'),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.icon,
    required this.label,
    required this.colour,
  });

  final IconData icon;
  final String label;
  final Color colour;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: colour),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(fontSize: 12, color: colour)),
        ],
      ),
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

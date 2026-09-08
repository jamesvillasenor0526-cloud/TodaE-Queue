/// TODA's crowd-sourced reports, drawn on top of Google's traffic.
///
/// Google's SDK draws general congestion itself, and does it with far more
/// data than a few dozen tricycle drivers could produce. What it cannot see
/// is the discrete stuff people on the road know first — an accident
/// blocking a lane, a flooded underpass, a closure for a fiesta. Those are
/// what these markers carry.
///
/// Markers are a parameter of the map rather than a child layer, so this is
/// a builder: it owns the Firestore subscription and hands the parent a
/// ready-made marker set.
library;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
// Both packages export a LatLng. The domain models speak latlong2, so that
// is the one left unqualified here; the map's own type is only ever reached
// through the toMaps extension.
import 'package:google_maps_flutter/google_maps_flutter.dart' hide LatLng;
import 'package:latlong2/latlong.dart';

import '../../../config/theme.dart';
import '../../../core/models/road_report.dart';
import '../../../core/services/report_service.dart';
import '../../../widgets/app_google_map.dart';

/// Marker colour per report type, matching the icon colours used in the
/// sheets so a pin and its list entry read as the same thing.
double _hueFor(ReportType type) => switch (type) {
  ReportType.accident || ReportType.roadClosure => BitmapDescriptor.hueRed,
  ReportType.trafficHeavy => BitmapDescriptor.hueRed,
  ReportType.flooding => BitmapDescriptor.hueAzure,
  ReportType.trafficModerate ||
  ReportType.hazard ||
  ReportType.breakdown => BitmapDescriptor.hueOrange,
  ReportType.trafficClear => BitmapDescriptor.hueGreen,
};

typedef ReportMapBuilder =
    Widget Function(
      BuildContext context,
      List<RoadReport> reports,
      Set<Marker> markers,
    );

/// Subscribes to live reports near [origin] and builds their map markers.
///
/// The subscription is re-centred only when [origin] moves meaningfully, so
/// a driver's position updating every few seconds doesn't tear down and
/// rebuild the Firestore listener.
class ReportMarkersBuilder extends StatefulWidget {
  const ReportMarkersBuilder({
    super.key,
    required this.origin,
    required this.builder,
    this.radiusKm = 5,
  });

  final LatLng origin;
  final double radiusKm;
  final ReportMapBuilder builder;

  @override
  State<ReportMarkersBuilder> createState() => _ReportMarkersBuilderState();
}

class _ReportMarkersBuilderState extends State<ReportMarkersBuilder> {
  static const double _recentreThresholdKm = 1;

  late Stream<List<RoadReport>> _stream;
  late LatLng _subscribedOrigin;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(covariant ReportMarkersBuilder old) {
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
        // map is still useful without the reports.
        final reports = snapshot.data ?? const <RoadReport>[];
        final markers = <Marker>{
          for (final r in reports)
            Marker(
              markerId: MarkerId('report_${r.id}'),
              position: r.location.toMaps,
              icon: BitmapDescriptor.defaultMarkerWithHue(_hueFor(r.type)),
              infoWindow: InfoWindow(
                title: r.type.label,
                snippet: r.note?.isNotEmpty == true
                    ? r.note
                    : 'Reported ${r.ageLabel(DateTime.now())}',
              ),
              onTap: () => showConditionsSheet(context, reports, focus: r),
            ),
        };
        return widget.builder(context, reports, markers);
      },
    );
  }
}

/// The reports behind the markers, with the actions a viewer may take.
///
/// [focus] pulls one report to the top, so tapping a pin lands on it rather
/// than making the user find it in the list.
Future<void> showConditionsSheet(
  BuildContext context,
  List<RoadReport> reports, {
  RoadReport? focus,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _ConditionsSheet(reports: reports, focus: focus),
  );
}

class _ConditionsSheet extends StatelessWidget {
  const _ConditionsSheet({required this.reports, this.focus});

  final List<RoadReport> reports;
  final RoadReport? focus;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    // Worst first, then most recent — the order someone deciding whether to
    // travel would want.
    final ordered = reports.where((r) => r.isLive(now)).toList()
      ..sort((a, b) {
        if (focus != null) {
          if (a.id == focus!.id) return -1;
          if (b.id == focus!.id) return 1;
        }
        final bySeverity = b.type.severity.compareTo(a.type.severity);
        if (bySeverity != 0) return bySeverity;
        final x = a.createdAt, y = b.createdAt;
        if (x == null || y == null) return 0;
        return y.compareTo(x);
      });

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
                      'Reported nearby',
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
              child: ordered.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(AppSpacing.xl),
                        child: Text(
                          'Nothing reported around here right now.\n'
                          'Live traffic is still shown on the map.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppTheme.textMuted),
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: scrollController,
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.lg,
                        0,
                        AppSpacing.lg,
                        AppSpacing.xl,
                      ),
                      itemCount: ordered.length,
                      itemBuilder: (context, i) =>
                          _ReportRow(report: ordered[i], now: now),
                    ),
            ),
          ],
        ),
      ),
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

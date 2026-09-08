import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../../config/theme.dart';
import '../../../core/models/road_report.dart';
import '../../../core/services/report_service.dart';

/// Draws live traffic and incident reports on a [FlutterMap].
///
/// Drop it into the map's `children` after the tile layer. The subscription
/// is owned here and rebuilt only when [origin] changes, so a parent
/// rebuilding for unrelated reasons doesn't churn the Firestore listener.
class ReportMarkerLayer extends StatefulWidget {
  const ReportMarkerLayer({
    super.key,
    required this.origin,
    this.radiusKm = 5,
    this.onReportsChanged,
  });

  final LatLng origin;
  final double radiusKm;

  /// Lets a parent show a count or banner without opening its own listener.
  final ValueChanged<List<RoadReport>>? onReportsChanged;

  @override
  State<ReportMarkerLayer> createState() => _ReportMarkerLayerState();
}

class _ReportMarkerLayerState extends State<ReportMarkerLayer> {
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
  void didUpdateWidget(covariant ReportMarkerLayer old) {
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
        return MarkerLayer(
          markers: [
            for (final r in reports)
              Marker(
                point: r.location,
                width: 44,
                height: 44,
                child: _ReportPin(
                  report: r,
                  onTap: () => showReportDetailSheet(context, r),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _ReportPin extends StatelessWidget {
  const _ReportPin({required this.report, required this.onTap});

  final RoadReport report;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '${report.type.label} reported here',
      child: GestureDetector(
        onTap: onTap,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: report.type.color,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black26,
                    blurRadius: 4,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: Icon(report.type.icon, color: Colors.white, size: 18),
            ),
            // Corroborated reports carry a count so a lone stale pin reads
            // differently from something several people have seen.
            if (report.isCorroborated)
              Positioned(
                top: 0,
                right: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    border: Border.all(color: report.type.color),
                  ),
                  child: Text(
                    '${report.confirmations + 1}',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: report.type.color,
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

/// Details for one report, with the actions the viewer is allowed to take.
Future<void> showReportDetailSheet(BuildContext context, RoadReport report) {
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (_) => _ReportDetail(report: report),
  );
}

class _ReportDetail extends StatefulWidget {
  const _ReportDetail({required this.report});
  final RoadReport report;

  @override
  State<_ReportDetail> createState() => _ReportDetailState();
}

class _ReportDetailState extends State<_ReportDetail> {
  bool _busy = false;
  String? _error;

  Future<void> _run(Future<void> Function() action, String done) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(done)));
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
                  color: r.type.color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: Icon(r.type.icon, color: r.type.color),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      r.type.label,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      'Reported by ${isMine ? 'you' : r.reporterName} · '
                      '${r.ageLabel(DateTime.now())}',
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
          if (r.note != null && r.note!.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            Text(r.note!),
          ],
          if (r.photoUrl != null) ...[
            const SizedBox(height: AppSpacing.md),
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.md),
              child: Image.network(
                r.photoUrl!,
                height: 160,
                width: double.infinity,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stack) =>
                    const SizedBox.shrink(),
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              const Icon(
                Icons.people_outline,
                size: 16,
                color: AppTheme.textMuted,
              ),
              const SizedBox(width: AppSpacing.xs),
              Text(
                r.confirmations == 0
                    ? 'Not yet confirmed by anyone else'
                    : '${r.confirmations} other '
                        '${r.confirmations == 1 ? 'person has' : 'people have'} '
                        'confirmed this',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppTheme.textMuted,
                ),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.md),
            Text(
              _error!,
              style: const TextStyle(color: AppTheme.errorRed),
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          if (isMine)
            OutlinedButton.icon(
              onPressed: _busy
                  ? null
                  : () => _run(
                      () => ReportService.instance.clear(r.id),
                      'Report removed. Thanks for keeping it accurate.',
                    ),
              icon: const Icon(Icons.check),
              label: const Text('This is resolved — take it down'),
            )
          else
            ElevatedButton.icon(
              onPressed: _busy || alreadyConfirmed
                  ? null
                  : () => _run(
                      () => ReportService.instance.confirm(r.id),
                      'Thanks — your confirmation helps others.',
                    ),
              icon: const Icon(Icons.thumb_up_outlined),
              label: Text(
                alreadyConfirmed
                    ? 'You already confirmed this'
                    : 'I can confirm this',
              ),
            ),
          const SizedBox(height: AppSpacing.sm),
        ],
      ),
    );
  }
}

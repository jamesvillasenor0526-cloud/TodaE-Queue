/// One-tap incident reporting for someone who may be driving.
///
/// The full [showReportSheet] asks for a category, a type, an optional note
/// and an optional photo. That is fine for a passenger sitting still; it is
/// the wrong thing to put in front of a driver.
///
/// Here a driver taps **Report**, taps the thing they can see, and is done.
/// Everything else — who they are, where they are, when, and which trip —
/// is attached automatically. There is no text field, no photo step and no
/// confirmation dialog, and every target is large enough to hit without
/// looking closely.
library;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../../config/theme.dart';
import '../../../core/models/road_report.dart';
import '../../../core/services/report_service.dart';

/// Opens the quick reporter. [tripId] is attached when reporting during a
/// trip, so an admin can see which journey a report came from.
Future<void> showQuickReportSheet(
  BuildContext context, {
  String? tripId,
  LatLng? at,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _QuickReportSheet(tripId: tripId, fixedLocation: at),
  );
}

/// The types offered, worst first. Kept short on purpose — a longer list
/// means more reading, and reading is the thing to avoid here.
const List<ReportType> _quickTypes = [
  ReportType.accident,
  ReportType.trafficHeavy,
  ReportType.roadClosure,
  ReportType.flooding,
  ReportType.hazard,
  ReportType.breakdown,
];

class _QuickReportSheet extends StatefulWidget {
  const _QuickReportSheet({this.tripId, this.fixedLocation});
  final String? tripId;
  final LatLng? fixedLocation;

  @override
  State<_QuickReportSheet> createState() => _QuickReportSheetState();
}

class _QuickReportSheetState extends State<_QuickReportSheet> {
  LatLng? _location;
  bool _locating = true;
  ReportType? _sending;
  String? _error;

  @override
  void initState() {
    super.initState();
    final fixed = widget.fixedLocation;
    if (fixed != null) {
      _location = fixed;
      _locating = false;
    } else {
      // Started immediately, so the position is usually ready by the time
      // the driver has picked a type — no waiting after the tap.
      _resolveLocation();
    }
  }

  Future<void> _resolveLocation() async {
    setState(() {
      _locating = true;
      _error = null;
    });
    final loc = await ReportService.instance.currentLocation();
    if (!mounted) return;
    setState(() {
      _location = loc;
      _locating = false;
      if (loc == null) {
        _error = 'Can\'t get your location. Turn on GPS and try again.';
      }
    });
  }

  Future<void> _send(ReportType type) async {
    final location = _location;
    if (location == null || _sending != null) return;

    setState(() {
      _sending = type;
      _error = null;
    });

    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) throw ReportException('Please sign in first.');

      // Read in the background rather than blocking the tap; a missing
      // profile must not stop a safety report.
      var name = 'A driver';
      var role = 'driver';
      try {
        final snap = await FirebaseFirestore.instance
            .collection('users')
            .doc(uid)
            .get();
        final data = snap.data() ?? const <String, dynamic>{};
        name = (data['fullName'] ?? data['name'] ?? name) as String;
        role = (data['role'] ?? role) as String;
      } catch (_) {
        // Defaults are good enough.
      }

      final outcome = await ReportService.instance.submit(
        type: type,
        location: location,
        reporterName: name,
        reporterRole: role,
        tripId: widget.tripId,
      );

      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 2),
          content: Text(
            outcome == ReportOutcome.created
                ? '${type.label} reported. Thanks!'
                : 'Already reported — your confirmation was added.',
          ),
        ),
      );
    } on ReportException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _sending = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Couldn\'t send. Please try again.';
        _sending = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = _location != null && _sending == null;

    return SafeArea(
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppRadius.lg),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.md,
          AppSpacing.lg,
          AppSpacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppTheme.borderLight,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'What do you see?',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                // A big, unmissable way out — the driver may have opened
                // this by accident.
                IconButton(
                  iconSize: 30,
                  icon: const Icon(Icons.close),
                  tooltip: 'Close',
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            if (_locating)
              const Padding(
                padding: EdgeInsets.only(bottom: AppSpacing.sm),
                child: Row(
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: AppSpacing.sm),
                    Text(
                      'Getting your location…',
                      style: TextStyle(color: AppTheme.textMuted),
                    ),
                  ],
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: Row(
                  children: [
                    const Icon(
                      Icons.error_outline,
                      color: AppTheme.errorRed,
                      size: 20,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        _error!,
                        style: const TextStyle(color: AppTheme.errorRed),
                      ),
                    ),
                    TextButton(
                      onPressed: _resolveLocation,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: 2,
              mainAxisSpacing: AppSpacing.md,
              crossAxisSpacing: AppSpacing.md,
              // Deliberately squat and wide: a big target for a thumb.
              childAspectRatio: 1.55,
              children: [
                for (final type in _quickTypes)
                  _QuickButton(
                    type: type,
                    busy: _sending == type,
                    onTap: ready ? () => _send(type) : null,
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            const Text(
              'Your location and the time are attached automatically.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickButton extends StatelessWidget {
  const _QuickButton({
    required this.type,
    required this.busy,
    required this.onTap,
  });

  final ReportType type;
  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Semantics(
      button: true,
      label: 'Report ${type.label}',
      child: Material(
        color: type.color.withValues(alpha: enabled ? 0.12 : 0.05),
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(
                color: type.color.withValues(alpha: enabled ? 0.6 : 0.2),
                width: 2,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (busy)
                  const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 3),
                  )
                else
                  Icon(
                    type.icon,
                    size: 30,
                    color: enabled ? type.color : AppTheme.textMuted,
                  ),
                const SizedBox(height: AppSpacing.xs),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.xs,
                  ),
                  child: Text(
                    type.label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: enabled
                          ? Theme.of(context).textTheme.bodyLarge?.color
                          : AppTheme.textMuted,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

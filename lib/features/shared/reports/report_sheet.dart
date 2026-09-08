import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';

import '../../../config/theme.dart';
import '../../../core/models/road_report.dart';
import '../../../core/services/report_service.dart';

/// Opens the "report a road condition" sheet.
///
/// [at] pins the report to a known point (a long-press on the map); when it
/// is null the sheet asks the device for the current position, which is the
/// common case — a driver stuck in traffic reports where they are.
Future<void> showReportSheet(BuildContext context, {LatLng? at}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _ReportSheet(fixedLocation: at),
  );
}

class _ReportSheet extends StatefulWidget {
  const _ReportSheet({this.fixedLocation});
  final LatLng? fixedLocation;

  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  final _noteController = TextEditingController();

  ReportCategory _category = ReportCategory.traffic;
  ReportType? _selected;
  File? _photo;

  LatLng? _location;
  bool _locating = true;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final fixed = widget.fixedLocation;
    if (fixed != null) {
      _location = fixed;
      _locating = false;
    } else {
      _resolveLocation();
    }
  }

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
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
      // A report with no location can't be placed on the map, so this is a
      // hard stop rather than a warning.
      if (loc == null) {
        _error = 'Couldn\'t get your location. Turn on GPS and try again.';
      }
    });
  }

  Future<void> _pickPhoto() async {
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.camera,
        maxWidth: 1280,
        imageQuality: 70,
      );
      if (picked == null || !mounted) return;
      setState(() => _photo = File(picked.path));
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Couldn\'t open the camera.');
    }
  }

  /// Name and role are stamped on the report so the map and the admin
  /// dashboard can show who flagged it. Falls back gracefully — a missing
  /// profile shouldn't block a safety report.
  Future<({String name, String role})> _reporter(String uid) async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();
      final data = snap.data() ?? const <String, dynamic>{};
      return (
        name: (data['fullName'] ?? data['name'] ?? 'Someone') as String,
        role: (data['role'] ?? 'passenger') as String,
      );
    } catch (_) {
      return (name: 'Someone', role: 'passenger');
    }
  }

  Future<void> _submit() async {
    final type = _selected;
    final location = _location;
    if (type == null || location == null || _submitting) return;

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      setState(() => _error = 'Please sign in before reporting.');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      final who = await _reporter(uid);
      final outcome = await ReportService.instance.submit(
        type: type,
        location: location,
        reporterName: who.name,
        reporterRole: who.role,
        note: _noteController.text,
        photo: _photo,
      );
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            outcome == ReportOutcome.created
                ? '${type.label} reported. Thanks!'
                : 'Someone already reported this — we added your confirmation.',
          ),
        ),
      );
    } on ReportException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _submitting = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Couldn\'t send your report. Please try again.';
        _submitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final types = ReportType.values
        .where((t) => t.category == _category)
        .toList();
    final canSubmit =
        _selected != null && _location != null && !_submitting && !_locating;

    return DraggableScrollableSheet(
      initialChildSize: 0.72,
      minChildSize: 0.5,
      maxChildSize: 0.95,
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
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.md,
                AppSpacing.lg,
                AppSpacing.sm,
              ),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Report a road condition',
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
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  0,
                  AppSpacing.lg,
                  AppSpacing.lg,
                ),
                children: [
                  SegmentedButton<ReportCategory>(
                    segments: const [
                      ButtonSegment(
                        value: ReportCategory.traffic,
                        icon: Icon(Icons.traffic),
                        label: Text('Traffic'),
                      ),
                      ButtonSegment(
                        value: ReportCategory.incident,
                        icon: Icon(Icons.report_problem_outlined),
                        label: Text('Incident'),
                      ),
                    ],
                    selected: {_category},
                    onSelectionChanged: (s) => setState(() {
                      _category = s.first;
                      _selected = null;
                    }),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  ...types.map(
                    (t) => Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                      child: _TypeTile(
                        type: t,
                        selected: _selected == t,
                        onTap: () => setState(() => _selected = t),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  TextField(
                    controller: _noteController,
                    maxLength: 140,
                    maxLines: 2,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      labelText: 'Add a detail (optional)',
                      hintText: 'e.g. near the public market',
                    ),
                  ),
                  if (_category == ReportCategory.incident) ...[
                    const SizedBox(height: AppSpacing.sm),
                    _PhotoRow(
                      photo: _photo,
                      onPick: _pickPhoto,
                      onRemove: () => setState(() => _photo = null),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.md),
                  _LocationRow(
                    locating: _locating,
                    location: _location,
                    onRetry: _resolveLocation,
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: AppSpacing.md),
                    Container(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      decoration: BoxDecoration(
                        color: AppTheme.errorRed.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(AppRadius.md),
                        border: Border.all(
                          color: AppTheme.errorRed.withValues(alpha: 0.4),
                        ),
                      ),
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
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.lg),
                  ElevatedButton.icon(
                    onPressed: canSubmit ? _submit : null,
                    icon: _submitting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.send),
                    label: Text(_submitting ? 'Sending…' : 'Submit report'),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  const Text(
                    'Reports are shared with nearby drivers and passengers, '
                    'and expire on their own once conditions change.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TypeTile extends StatelessWidget {
  const _TypeTile({
    required this.type,
    required this.selected,
    required this.onTap,
  });

  final ReportType type;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: selected
                ? type.color.withValues(alpha: 0.08)
                : Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(
              color: selected ? type.color : AppTheme.borderLight,
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: type.color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Icon(type.icon, color: type.color, size: 22),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      type.label,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      type.hint,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppTheme.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              if (selected) Icon(Icons.check_circle, color: type.color),
            ],
          ),
        ),
      ),
    );
  }
}

class _PhotoRow extends StatelessWidget {
  const _PhotoRow({
    required this.photo,
    required this.onPick,
    required this.onRemove,
  });

  final File? photo;
  final VoidCallback onPick;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    if (photo == null) {
      return OutlinedButton.icon(
        onPressed: onPick,
        icon: const Icon(Icons.photo_camera_outlined),
        label: const Text('Add a photo (optional)'),
      );
    }
    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          child: Image.file(
            photo!,
            width: 56,
            height: 56,
            fit: BoxFit.cover,
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        const Expanded(child: Text('Photo attached')),
        IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: 'Remove photo',
          onPressed: onRemove,
        ),
      ],
    );
  }
}

class _LocationRow extends StatelessWidget {
  const _LocationRow({
    required this.locating,
    required this.location,
    required this.onRetry,
  });

  final bool locating;
  final LatLng? location;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (locating) {
      return const Row(
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: AppSpacing.sm),
          Text('Getting your location…',
              style: TextStyle(color: AppTheme.textMuted)),
        ],
      );
    }
    if (location == null) {
      return Row(
        children: [
          const Icon(Icons.location_off, size: 18, color: AppTheme.errorRed),
          const SizedBox(width: AppSpacing.sm),
          const Expanded(child: Text('Location unavailable')),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      );
    }
    return Row(
      children: [
        const Icon(Icons.my_location, size: 18, color: AppTheme.success),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            'Using your current location '
            '(${location!.latitude.toStringAsFixed(4)}, '
            '${location!.longitude.toStringAsFixed(4)})',
            style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
          ),
        ),
      ],
    );
  }
}

/// The reports the signed-in user has filed, and a way to take one down.
///
/// Before this existed the only way to remove your own report was to find
/// its marker on the map and tap it — and a driver's own location dot sits
/// on top of the marker for a report they just filed where they stand, so
/// the tap went to the dot. A driver who reported a crash that has since
/// cleared had no dependable way to stop it rerouting everyone else.
library;

import 'package:flutter/material.dart';

import '../../../config/theme.dart';
import '../../../core/models/road_report.dart';
import '../../../core/services/report_service.dart';

class MyReportsScreen extends StatelessWidget {
  const MyReportsScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(
    context,
  ).push(MaterialPageRoute(builder: (_) => const MyReportsScreen()));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My road reports')),
      body: StreamBuilder<List<RoadReport>>(
        stream: ReportService.instance.watchMine(),
        builder: (context, snap) {
          if (snap.hasError) {
            return const _Message(
              icon: Icons.cloud_off,
              text: 'Can\'t load your reports right now. Check your connection.',
            );
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final now = DateTime.now();
          final reports = snap.data!;
          if (reports.isEmpty) {
            return const _Message(
              icon: Icons.flag_outlined,
              text:
                  'You haven\'t reported anything yet. Use Report on the map '
                  'when you see an accident, flooding or heavy traffic.',
            );
          }

          // Live ones first: those are what other drivers are routing around
          // right now, and the ones worth checking are still true.
          final live = reports.where((r) => r.isLive(now)).toList();
          final past = reports.where((r) => !r.isLive(now)).toList();

          return ListView(
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [
              if (live.isNotEmpty) ...[
                const _SectionTitle('Active — other drivers can see these'),
                for (final r in live) _ReportTile(report: r, now: now),
              ],
              if (past.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.md),
                const _SectionTitle('No longer active'),
                for (final r in past) _ReportTile(report: r, now: now),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _ReportTile extends StatefulWidget {
  const _ReportTile({required this.report, required this.now});
  final RoadReport report;
  final DateTime now;

  @override
  State<_ReportTile> createState() => _ReportTileState();
}

class _ReportTileState extends State<_ReportTile> {
  bool _busy = false;

  Future<void> _takeDown() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Take this report down?'),
        content: const Text(
          'Other drivers will stop seeing it, and routes will stop avoiding '
          'it. Do this when the road is clear again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Take it down'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _busy = true);
    try {
      await ReportService.instance.clear(widget.report.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Report taken down. Thanks for keeping it accurate.')),
      );
    } on ReportException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.report;
    final now = widget.now;
    final live = r.isLive(now);
    final status = r.statusAt(now);

    // Why a report is no longer active, in the driver's terms.
    final inactiveReason = r.cleared
        ? 'Taken down'
        : status == IncidentStatus.rejected
        ? 'Dismissed by an admin'
        : 'Expired';

    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  r.type.icon,
                  color: live ? r.type.color : AppTheme.textMuted,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    r.type.label,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: live ? null : AppTheme.textMuted,
                    ),
                  ),
                ),
                Text(
                  live ? status.label : inactiveReason,
                  style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Reported ${r.ageLabel(now)} · '
              '${r.confirmations == 0 ? 'no confirmations yet' : '${r.confirmations} confirmed'}'
              '${r.corroboratedByTraffic ? ' · matches live traffic' : ''}',
              style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
            ),
            Text(
              '${r.location.latitude.toStringAsFixed(4)}, '
              '${r.location.longitude.toStringAsFixed(4)}',
              style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
            ),
            if (r.note != null && r.note!.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.xs),
              Text('“${r.note}”', style: const TextStyle(fontSize: 13)),
            ],
            if (live) ...[
              const SizedBox(height: AppSpacing.sm),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _takeDown,
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check, size: 16),
                  label: const Text('Road is clear — take it down'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: AppTheme.textMuted,
      ),
    ),
  );
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: AppTheme.textMuted),
          const SizedBox(height: AppSpacing.md),
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppTheme.textMuted),
          ),
        ],
      ),
    ),
  );
}

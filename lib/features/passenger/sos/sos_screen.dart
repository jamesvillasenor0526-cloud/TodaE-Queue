/// The SOS screen, for passengers and drivers alike.
///
/// Driven by the alert itself, not by a flag held in this screen. The old
/// screen kept "alert sent" in local state, so leaving it lost the alert:
/// coming back showed a fresh button, the open alert could not be cancelled,
/// and pressing again raised a duplicate. Now whatever is open in the
/// database is what is shown, wherever the person comes from.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../config/theme.dart';
import '../../../core/models/sos_alert.dart';
import '../../../core/services/sos_service.dart';

/// The Philippines' national emergency number.
const String kEmergencyNumber = '911';

class SosScreen extends StatefulWidget {
  const SosScreen({super.key});

  @override
  State<SosScreen> createState() => _SosScreenState();
}

class _SosScreenState extends State<SosScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  StreamSubscription<SosAlert?>? _sub;

  /// The open alert, if any. Null with [_loaded] false means not yet known.
  SosAlert? _alert;
  bool _loaded = false;

  bool _sending = false;
  bool _queued = false;
  String? _error;

  /// The alert this screen last showed, so a close by an admin is reported
  /// rather than the screen silently resetting.
  SosAlert? _shown;
  String? _closedNote;

  /// Redraws the "updated N min ago" line.
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
    _sub = SosService.instance.watchMyOpenAlert().listen(_onAlert);
    _clock = Timer.periodic(
      const Duration(seconds: 15),
      (_) => mounted ? setState(() {}) : null,
    );
  }

  void _onAlert(SosAlert? alert) {
    if (!mounted) return;
    setState(() {
      if (alert != null) {
        SosService.instance.track(alert.id);
        _shown = alert;
      } else if (_shown != null && _closedNote == null) {
        // It was open and now is not, and not by this screen: an admin
        // closed it. Say so once instead of silently resetting.
        _closedNote = 'A TODA admin has resolved your alert.';
        _shown = null;
        _queued = false;
      }
      _alert = alert;
      _loaded = true;
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _clock?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _callEmergency() async {
    final ok = await launchUrl(Uri(scheme: 'tel', path: kEmergencyNumber));
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the dialler. Dial 911.')),
      );
    }
  }

  Future<void> _send() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning, color: AppTheme.errorRed),
            SizedBox(width: 8),
            Text('Send SOS?'),
          ],
        ),
        content: const Text(
          'TODA admins will be alerted with your location and your trip. '
          'Only use this in a real emergency.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.errorRed),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Yes, send SOS',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _sending = true;
      _error = null;
      _closedNote = null;
    });
    try {
      final result = await SosService.instance.trigger();
      if (mounted) setState(() => _queued = !result.delivered);
    } on SosException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _cancel(SosAlert alert) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Are you safe?'),
        content: const Text('This tells TODA admins they can stand down.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep the alert on'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("I'm safe"),
          ),
        ],
      ),
    );
    if (sure != true) return;
    // Set before cancelling: the live update that the alert has closed can
    // arrive before the cancel call returns, and would otherwise be read as
    // an admin having resolved it.
    setState(() => _closedNote = 'Alert cancelled. Stay safe.');
    try {
      await SosService.instance.cancel(alert.id);
    } on SosException catch (e) {
      if (mounted) {
        setState(() {
          _closedNote = null;
          _error = e.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final alert = _alert;
    final open = alert != null;
    return Scaffold(
      backgroundColor: open ? AppTheme.errorRed : AppTheme.backgroundGray,
      appBar: AppBar(
        backgroundColor: open ? AppTheme.errorRed : AppTheme.primaryGreen,
        title: const Text('Emergency SOS'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: open ? _openView(alert) : _idleView(_loaded),
        ),
      ),
    );
  }

  Widget _openView(SosAlert alert) {
    final message = sosStatusMessage(alert);
    final trip = alert.trip;
    const white = TextStyle(color: Colors.white);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: AppSpacing.md),
        Icon(
          alert.status == SosStatus.acknowledged
              ? Icons.support_agent
              : Icons.warning_amber_rounded,
          color: Colors.white,
          size: 64,
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          message.title,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 26,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          message.detail,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
        if (_queued && alert.triggeredAt == null) ...[
          const SizedBox(height: AppSpacing.md),
          const _Notice(
            icon: Icons.cloud_off,
            text:
                'No connection yet. Your alert is saved and will send by '
                'itself when you have signal. Call 911 now.',
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
        _InfoRow(
          icon: alert.hasLocation ? Icons.my_location : Icons.location_off,
          text: sosLocationLine(alert, DateTime.now()),
        ),
        if (trip != null && trip.vehicleLine.isNotEmpty)
          _InfoRow(icon: Icons.electric_rickshaw, text: trip.vehicleLine),
        const SizedBox(height: AppSpacing.xl),
        SizedBox(
          height: 60,
          child: FilledButton.icon(
            onPressed: _callEmergency,
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: AppTheme.errorRed,
            ),
            icon: const Icon(Icons.call),
            label: const Text(
              'Call 911',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        OutlinedButton.icon(
          onPressed: () => _cancel(alert),
          icon: const Icon(Icons.check, color: Colors.white),
          label: const Text("I'm safe — cancel alert", style: white),
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: Colors.white),
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: AppSpacing.md),
          _Notice(icon: Icons.error_outline, text: _error!),
        ],
      ],
    );
  }

  Widget _idleView(bool loaded) {
    return Column(
      children: [
        if (_closedNote != null) ...[
          _Banner(text: _closedNote!),
          const SizedBox(height: AppSpacing.lg),
        ],
        const SizedBox(height: AppSpacing.xl),
        ScaleTransition(
          scale: Tween<double>(
            begin: 1.0,
            end: 1.12,
          ).animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut)),
          child: GestureDetector(
            // Held until the open alert (if any) has loaded, so an existing
            // alert is shown rather than a second one raised.
            onTap: (_sending || !loaded) ? null : _send,
            child: Container(
              width: 190,
              height: 190,
              decoration: BoxDecoration(
                color: AppTheme.errorRed,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: AppTheme.errorRed.withValues(alpha: 0.4),
                    blurRadius: 30,
                    spreadRadius: 10,
                  ),
                ],
              ),
              child: _sending
                  ? const Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    )
                  : const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.sos, color: Colors.white, size: 64),
                        SizedBox(height: 8),
                        Text(
                          'PRESS',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        Text(
          _sending ? 'Sending your alert…' : 'Press in an emergency',
          style: const TextStyle(fontSize: 16, color: AppTheme.textMuted),
        ),
        const SizedBox(height: AppSpacing.sm),
        const Text(
          'TODA admins get your location and your trip, and it keeps\n'
          'updating until the alert is closed.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppTheme.textMuted),
        ),
        if (_error != null) ...[
          const SizedBox(height: AppSpacing.md),
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppTheme.errorRed),
          ),
        ],
        const SizedBox(height: AppSpacing.xl),
        OutlinedButton.icon(
          onPressed: _callEmergency,
          icon: const Icon(Icons.call, color: AppTheme.errorRed),
          label: const Text(
            'Call 911',
            style: TextStyle(color: AppTheme.errorRed, fontSize: 16),
          ),
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: AppTheme.errorRed),
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
          ),
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
    child: Row(
      children: [
        Icon(icon, color: Colors.white, size: 20),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(text, style: const TextStyle(color: Colors.white)),
        ),
      ],
    ),
  );
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(AppSpacing.md),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.2),
      borderRadius: BorderRadius.circular(AppRadius.md),
    ),
    child: Row(
      children: [
        Icon(icon, color: Colors.white),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(text, style: const TextStyle(color: Colors.white)),
        ),
      ],
    ),
  );
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(AppSpacing.md),
    decoration: BoxDecoration(
      color: AppTheme.success.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(AppRadius.md),
    ),
    child: Row(
      children: [
        const Icon(Icons.check_circle, color: AppTheme.success),
        const SizedBox(width: AppSpacing.sm),
        Expanded(child: Text(text)),
      ],
    ),
  );
}

/// The SOS screen, for passengers and drivers alike.
///
/// Driven by the alert itself, not by a flag held in this screen. The old
/// screen kept "alert sent" in local state, so leaving it lost the alert:
/// coming back showed a fresh button, the open alert could not be cancelled,
/// and pressing again raised a duplicate. Now whatever is open in the
/// database is what is shown, wherever the person comes from.
///
/// Two ways in. CRITICAL EMERGENCY is for someone who cannot explain: one
/// confirmation and it goes, with nothing to choose or type. GET HELP is for
/// someone with a moment to say what happened, picked with one tap. A third
/// way, silent, starts from the home screen's SOS button (see SosButton) and
/// never opens the red screen at all.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../config/theme.dart';
import '../../../core/models/sos_alert.dart';
import '../../../core/services/sos_service.dart';

/// The Philippines' national emergency number.
const String kEmergencyNumber = '911';

/// The icon for each thing that can have happened.
IconData sosCategoryIcon(SosCategory c) => switch (c) {
  SosCategory.accident => Icons.car_crash,
  SosCategory.medical => Icons.medical_services,
  SosCategory.threat => Icons.gpp_bad,
  SosCategory.harassment => Icons.do_not_touch,
  SosCategory.breakdown => Icons.car_repair,
  SosCategory.other => Icons.help_outline,
};

const Color _incidentOrange = Color(0xFFE65100);

class SosScreen extends StatefulWidget {
  const SosScreen({super.key});

  @override
  State<SosScreen> createState() => _SosScreenState();
}

class _SosScreenState extends State<SosScreen> {
  StreamSubscription<SosAlert?>? _sub;

  /// The open alert, if any. Null with [_loaded] false means not yet known.
  SosAlert? _alert;
  bool _loaded = false;

  bool _sending = false;
  bool _queued = false;
  String? _error;

  /// Choosing what happened, for GET HELP.
  bool _choosing = false;
  SosCategory? _category;

  /// The alert this screen last showed, so a close by an admin is reported
  /// rather than the screen silently resetting.
  SosAlert? _shown;
  String? _closedNote;

  /// Redraws the "updated N min ago" line, and checks the server.
  Timer? _clock;

  /// Whether the last direct check reached the server. False means the
  /// status on screen may be out of date, and the person is told so.
  bool _serverReachable = true;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _sub = SosService.instance.watchMyOpenAlert().listen(_onAlert);
    _clock = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!mounted) return;
      setState(() {}); // keeps "updated N min ago" honest
      _checkServer();
    });
  }

  /// Asks the server directly while an alert is open.
  ///
  /// The live listener alone is not enough: it can drop without notice and
  /// leave the screen showing a status that has since changed. A direct
  /// read picks up an admin's response regardless, and failing to get one
  /// is itself worth telling the person.
  Future<void> _checkServer() async {
    final open = _alert;
    if (open == null || _checking) return;
    _checking = true;
    try {
      final fresh = await SosService.instance.fetchFromServer(open.id);
      if (!mounted) return;
      if (fresh.status.isOpen) {
        setState(() {
          _serverReachable = true;
          _alert = fresh;
        });
      } else {
        setState(() => _serverReachable = true);
        _onAlert(null); // closed while the listener was not delivering
      }
    } catch (_) {
      if (mounted) setState(() => _serverReachable = false);
    } finally {
      _checking = false;
    }
  }

  void _onAlert(SosAlert? alert) {
    if (!mounted) return;
    setState(() {
      if (alert != null) {
        SosService.instance.track(alert.id);
        _shown = alert;
        _choosing = false;
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

  /// CRITICAL EMERGENCY: one confirmation, then it goes.
  Future<void> _sendCritical() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Send emergency alert?'),
        content: const Text(
          'Your current location and trip details will be shared with the '
          'TODA admin team.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.errorRed),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('SEND SOS'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _trigger(severity: SosSeverity.critical);
  }

  /// GET HELP: choosing what happened was the deliberate step, so the send
  /// button is the confirmation.
  Future<void> _sendIncident(SosCategory category) =>
      _trigger(severity: SosSeverity.incident, category: category);

  Future<void> _trigger({
    required SosSeverity severity,
    SosCategory? category,
  }) async {
    setState(() {
      _sending = true;
      _error = null;
      _closedNote = null;
    });
    try {
      final result = await SosService.instance.trigger(
        severity: severity,
        category: category,
      );
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
    // A silent alert looks like any ordinary page: someone nearby must not
    // be able to tell from across a tricycle that help has been called.
    final loud = open && !alert.silent;
    return PopScope(
      // Back from the category list returns to the two choices.
      canPop: !_choosing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _choosing = false);
      },
      child: Scaffold(
        backgroundColor: loud ? AppTheme.errorRed : AppTheme.backgroundGray,
        appBar: AppBar(
          backgroundColor: loud
              ? AppTheme.errorRed
              : open
              ? Colors.white
              : AppTheme.primaryGreen,
          foregroundColor: open && !loud ? AppTheme.textPrimaryLight : null,
          // No title on a silent alert: "SOS" across the top is the one
          // word someone glancing over would read.
          title: open && !loud ? null : const Text('Emergency SOS'),
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: open
                ? _openView(alert)
                : _choosing
                ? _categoryView()
                : _idleView(),
          ),
        ),
      ),
    );
  }

  Widget _openView(SosAlert alert) {
    final message = sosStatusMessage(alert);
    final trip = alert.trip;
    final fg = alert.silent ? AppTheme.textPrimaryLight : Colors.white;
    final category = alert.category;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: AppSpacing.md),
        Icon(
          alert.silent
              ? Icons.volume_off
              : alert.status == SosStatus.acknowledged
              ? Icons.support_agent
              : Icons.warning_amber_rounded,
          color: fg,
          size: alert.silent ? 40 : 64,
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          message.title,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: fg,
            fontSize: alert.silent ? 20 : 26,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          message.detail,
          textAlign: TextAlign.center,
          style: TextStyle(color: fg, fontSize: 16),
        ),
        if (_queued && alert.triggeredAt == null) ...[
          const SizedBox(height: AppSpacing.md),
          _Notice(
            icon: Icons.cloud_off,
            color: fg,
            text:
                'No connection yet. Your alert is saved and will send by '
                'itself when you have signal. Call 911 now.',
          ),
        ],
        if (!_serverReachable && !(_queued && alert.triggeredAt == null)) ...[
          const SizedBox(height: AppSpacing.md),
          _Notice(
            icon: Icons.signal_wifi_bad,
            color: fg,
            text:
                "Can't reach the server right now, so this status may be "
                'out of date. Call 911 if you need help now.',
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
        if (category != null)
          _InfoRow(
            icon: sosCategoryIcon(category),
            color: fg,
            text: 'You reported: ${category.label}',
          ),
        _InfoRow(
          icon: alert.hasLocation ? Icons.my_location : Icons.location_off,
          color: fg,
          text: sosLocationLine(alert, DateTime.now()),
        ),
        if (trip != null && trip.vehicleLine.isNotEmpty)
          _InfoRow(
            icon: Icons.electric_rickshaw,
            color: fg,
            text: trip.vehicleLine,
          ),
        const SizedBox(height: AppSpacing.xl),
        SizedBox(
          height: 60,
          child: FilledButton.icon(
            onPressed: _callEmergency,
            style: FilledButton.styleFrom(
              backgroundColor: alert.silent ? AppTheme.errorRed : Colors.white,
              foregroundColor: alert.silent ? Colors.white : AppTheme.errorRed,
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
          icon: Icon(Icons.check, color: fg),
          label: Text("I'm safe — cancel alert", style: TextStyle(color: fg)),
          style: OutlinedButton.styleFrom(
            side: BorderSide(color: fg),
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: AppSpacing.md),
          _Notice(icon: Icons.error_outline, color: fg, text: _error!),
        ],
      ],
    );
  }

  Widget _idleView() {
    // Held until the open alert (if any) has loaded, so an existing alert is
    // shown rather than a second one raised.
    final ready = _loaded && !_sending;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_closedNote != null) ...[
          _Banner(text: _closedNote!),
          const SizedBox(height: AppSpacing.lg),
        ],
        _ChoiceCard(
          filled: true,
          color: AppTheme.errorRed,
          icon: Icons.sos,
          title: 'CRITICAL EMERGENCY',
          subtitle: "I need help now. I can't explain what happened.",
          busy: _sending,
          onTap: ready ? _sendCritical : null,
        ),
        const SizedBox(height: AppSpacing.md),
        _ChoiceCard(
          filled: false,
          color: _incidentOrange,
          icon: Icons.report_problem_outlined,
          title: 'GET HELP — SAY WHAT HAPPENED',
          subtitle: 'I have time to choose what happened.',
          onTap: ready
              ? () => setState(() {
                  _choosing = true;
                  _category = null;
                  _error = null;
                })
              : null,
        ),
        const SizedBox(height: AppSpacing.lg),
        const Text(
          'Either way, TODA admins get your location and your trip, and it '
          'keeps updating until the alert is closed.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppTheme.textMuted),
        ),
        const SizedBox(height: AppSpacing.md),
        const _SilentHint(),
        if (_error != null) ...[
          const SizedBox(height: AppSpacing.md),
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppTheme.errorRed),
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
        Center(child: _Call911Outlined(onPressed: _callEmergency)),
      ],
    );
  }

  Widget _categoryView() {
    final chosen = _category;
    final ready = _loaded && !_sending;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _sending
                ? null
                : () => setState(() => _choosing = false),
            icon: const Icon(Icons.arrow_back),
            label: const Text('Back'),
          ),
        ),
        const Text(
          'What happened?',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: AppSpacing.xs),
        const Text(
          'Tap one. Nothing to type.',
          style: TextStyle(color: AppTheme.textMuted),
        ),
        const SizedBox(height: AppSpacing.md),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: AppSpacing.sm,
          crossAxisSpacing: AppSpacing.sm,
          childAspectRatio: 1.5,
          children: [
            for (final c in SosCategory.values)
              _CategoryTile(
                category: c,
                selected: c == chosen,
                onTap: _sending ? null : () => setState(() => _category = c),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        SizedBox(
          height: 56,
          child: FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _incidentOrange),
            onPressed: chosen != null && ready
                ? () => _sendIncident(chosen)
                : null,
            child: _sending
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(color: Colors.white),
                  )
                : Text(
                    chosen == null
                        ? 'Choose what happened'
                        : 'Send alert: ${chosen.label}',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: AppSpacing.md),
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppTheme.errorRed),
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
        const Text(
          'In danger right now? Go back and use Critical emergency, or call '
          '911.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppTheme.textMuted),
        ),
        const SizedBox(height: AppSpacing.sm),
        Center(child: _Call911Outlined(onPressed: _callEmergency)),
      ],
    );
  }
}

/// One of the two large ways in.
class _ChoiceCard extends StatelessWidget {
  const _ChoiceCard({
    required this.filled,
    required this.color,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.busy = false,
  });

  final bool filled;
  final Color color;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final fg = filled ? Colors.white : color;
    return Material(
      color: filled ? color : Colors.white,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      elevation: filled ? 4 : 0,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.lg),
          decoration: filled
              ? null
              : BoxDecoration(
                  border: Border.all(color: color, width: 2),
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                ),
          child: Row(
            children: [
              busy
                  ? SizedBox(
                      width: 56,
                      height: 56,
                      child: CircularProgressIndicator(color: fg),
                    )
                  : Icon(icon, color: fg, size: 56),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      busy ? 'Sending…' : title,
                      style: TextStyle(
                        color: fg,
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: filled
                            ? Colors.white
                            : AppTheme.textPrimaryLight,
                        fontSize: 15,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile({
    required this.category,
    required this.selected,
    required this.onTap,
  });

  final SosCategory category;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: selected ? _incidentOrange : Colors.white,
    borderRadius: BorderRadius.circular(AppRadius.md),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.sm),
        decoration: BoxDecoration(
          border: Border.all(
            color: selected ? _incidentOrange : AppTheme.borderLight,
            width: 2,
          ),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              sosCategoryIcon(category),
              size: 32,
              color: selected ? Colors.white : _incidentOrange,
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              category.label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: selected ? Colors.white : AppTheme.textPrimaryLight,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Where the silent alert is, said once, plainly.
class _SilentHint extends StatelessWidget {
  const _SilentHint();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(AppSpacing.md),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(AppRadius.md),
      border: Border.all(color: AppTheme.borderLight),
    ),
    child: const Row(
      children: [
        Icon(Icons.volume_off, color: AppTheme.textMuted),
        SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            "Can't let anyone see? On the home screen, hold the SOS button "
            "for 3 seconds. It sends silently, and admins won't call you.",
          ),
        ),
      ],
    ),
  );
}

class _Call911Outlined extends StatelessWidget {
  const _Call911Outlined({required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    onPressed: onPressed,
    icon: const Icon(Icons.call, color: AppTheme.errorRed),
    label: const Text(
      'Call 911',
      style: TextStyle(color: AppTheme.errorRed, fontSize: 16),
    ),
    style: OutlinedButton.styleFrom(
      side: const BorderSide(color: AppTheme.errorRed),
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
    ),
  );
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.text,
    this.color = Colors.white,
  });
  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
    child: Row(
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(text, style: TextStyle(color: color)),
        ),
      ],
    ),
  );
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.text,
    this.color = Colors.white,
  });
  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(AppSpacing.md),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(AppRadius.md),
    ),
    child: Row(
      children: [
        Icon(icon, color: color),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(text, style: TextStyle(color: color)),
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

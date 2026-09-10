/// The SOS button on the home screens, which knows when an alert is open.
///
/// A plain "SOS" button gave no sign that an alert was still live, so people
/// pressed again, and an alert raised and then left could sit "active" for
/// days with nobody aware of it. This one turns into "SOS ACTIVE" while an
/// alert is open, and keeps the location updating even when the SOS screen
/// itself is not showing.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../config/routes.dart';
import '../../../config/theme.dart';
import '../../../core/models/sos_alert.dart';
import '../../../core/services/sos_service.dart';

class SosButton extends StatefulWidget {
  const SosButton({super.key});

  @override
  State<SosButton> createState() => _SosButtonState();
}

class _SosButtonState extends State<SosButton>
    with SingleTickerProviderStateMixin {
  StreamSubscription<SosAlert?>? _sub;
  SosAlert? _open;
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _sub = SosService.instance.watchMyOpenAlert().listen((alert) {
      if (!mounted) return;
      if (alert != null) {
        SosService.instance.track(alert.id);
        _pulse.repeat(reverse: true);
      } else {
        _pulse.stop();
        _pulse.value = 0;
      }
      setState(() => _open = alert);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final open = _open != null;
    final button = FloatingActionButton.extended(
      heroTag: 'sos',
      onPressed: () {
        HapticFeedback.heavyImpact();
        Navigator.pushNamed(context, AppRoutes.sos);
      },
      backgroundColor: open ? const Color(0xFF8B0000) : AppTheme.errorRed,
      // Icons.sos is drawn as the letters "SOS", which beside the label read
      // "SOS SOS"; the idle button is the word alone.
      icon: open
          ? const Icon(Icons.warning_amber_rounded, color: Colors.white)
          : null,
      label: Text(
        open ? 'SOS ACTIVE' : 'SOS',
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
    if (!open) return button;
    return ScaleTransition(
      scale: Tween<double>(begin: 1.0, end: 1.08).animate(
        CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
      ),
      child: button,
    );
  }
}

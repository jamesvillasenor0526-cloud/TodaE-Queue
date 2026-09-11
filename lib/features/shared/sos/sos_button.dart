/// The SOS button on the home screens, which knows when an alert is open.
///
/// A plain "SOS" button gave no sign that an alert was still live, so people
/// pressed again, and an alert raised and then left could sit "active" for
/// days with nobody aware of it. This one turns into "SOS ACTIVE" while an
/// alert is open, and keeps the location updating even when the SOS screen
/// itself is not showing.
///
/// Tap opens the SOS screen. Holding for [kSilentHold] sends a silent alert
/// from right here, for someone being threatened who cannot be seen asking
/// for help: no red screen, no sound, one short vibration, and the button
/// keeps looking ordinary afterwards.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../config/routes.dart';
import '../../../config/theme.dart';
import '../../../core/models/sos_alert.dart';
import '../../../core/services/sos_service.dart';

/// How long the button is held to send a silent alert. Long enough that it
/// cannot happen by brushing the screen.
const Duration kSilentHold = Duration(seconds: 3);

class SosButton extends StatefulWidget {
  const SosButton({super.key});

  @override
  State<SosButton> createState() => _SosButtonState();
}

class _SosButtonState extends State<SosButton> with TickerProviderStateMixin {
  StreamSubscription<SosAlert?>? _sub;
  SosAlert? _open;
  bool _loaded = false;
  late final AnimationController _pulse;
  late final AnimationController _hold;

  /// The finger that sent a silent alert is still down; its release must
  /// not also count as a tap and open the SOS screen.
  bool _swallowTap = false;
  bool _sendingSilently = false;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _hold = AnimationController(vsync: this, duration: kSilentHold)
      ..addStatusListener((s) {
        if (s == AnimationStatus.completed) _sendSilently();
      });
    _sub = SosService.instance.watchMyOpenAlert().listen((alert) {
      if (!mounted) return;
      if (alert != null) {
        SosService.instance.track(alert.id);
      }
      // A silent alert must not make the button pulse for all to see.
      if (alert != null && !alert.silent) {
        _pulse.repeat(reverse: true);
      } else {
        _pulse.stop();
        _pulse.value = 0;
      }
      setState(() {
        _open = alert;
        _loaded = true;
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _pulse.dispose();
    _hold.dispose();
    super.dispose();
  }

  void _holdStart() {
    // A fresh press: whatever the last one did, this one's tap counts.
    _swallowTap = false;
    // Not before the open alert (if any) is known, and never a second one.
    if (!_loaded || _open != null || _sendingSilently) return;
    _hold.forward(from: 0);
  }

  void _holdEnd() {
    if (_hold.isAnimating) _hold.reset();
  }

  Future<void> _sendSilently() async {
    _swallowTap = true;
    _hold.reset();
    setState(() => _sendingSilently = true);
    final messenger = ScaffoldMessenger.of(context);
    // Felt, not seen or heard: the only sign that it went. At once, not
    // after the server answers, so the finger can come off the button.
    unawaited(HapticFeedback.heavyImpact());
    try {
      final result = await SosService.instance.trigger(silent: true);
      if (!result.delivered) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('No signal. It will send when you have signal.'),
          ),
        );
      }
    } on SosException {
      messenger.showSnackBar(
        const SnackBar(content: Text("Couldn't send. Try again or call 911.")),
      );
    } finally {
      if (mounted) setState(() => _sendingSilently = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final alert = _open;
    final loud = alert != null && !alert.silent;
    final button = FloatingActionButton.extended(
      heroTag: 'sos',
      onPressed: () {
        if (_swallowTap) {
          _swallowTap = false;
          return;
        }
        HapticFeedback.heavyImpact();
        Navigator.pushNamed(context, AppRoutes.sos);
      },
      backgroundColor: loud ? const Color(0xFF8B0000) : AppTheme.errorRed,
      // Icons.sos is drawn as the letters "SOS", which beside the label read
      // "SOS SOS"; the idle button is the word alone. A silent alert gets a
      // small dot only its sender will know the meaning of.
      icon: loud
          ? const Icon(Icons.warning_amber_rounded, color: Colors.white)
          : alert != null
          ? const _Dot()
          : null,
      label: Text(
        loud ? 'SOS ACTIVE' : 'SOS',
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
        ),
      ),
    );

    // A Listener, not a long-press recogniser: it sees the finger go down
    // without competing with the button's own tap, so the hold can show its
    // progress from the first moment.
    final held = Listener(
      onPointerDown: (_) => _holdStart(),
      onPointerUp: (_) => _holdEnd(),
      onPointerCancel: (_) => _holdEnd(),
      child: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          button,
          // A thin line filling along the bottom edge while held. Visible to
          // the person holding it, easy to miss for anyone else.
          AnimatedBuilder(
            animation: _hold,
            builder: (context, _) => _hold.value == 0
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                    child: SizedBox(
                      width: 60,
                      child: LinearProgressIndicator(
                        value: _hold.value,
                        minHeight: 3,
                        color: Colors.white,
                        backgroundColor: Colors.white24,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );

    if (!loud) return held;
    return ScaleTransition(
      scale: Tween<double>(
        begin: 1.0,
        end: 1.08,
      ).animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut)),
      child: held,
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot();

  @override
  Widget build(BuildContext context) => Container(
    width: 7,
    height: 7,
    decoration: const BoxDecoration(
      color: Colors.white,
      shape: BoxShape.circle,
    ),
  );
}

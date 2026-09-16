/// A map marker that moves like a vehicle rather than a dot on a string.
///
/// Two ways of drawing it, depending on what is known.
///
/// Given only readings, it glides from one to the next over about the time
/// between them (see glide.dart): always moving, never ahead of what is
/// known, but always one reading behind.
///
/// Given the route the vehicle is on and how fast it is going, it does what
/// a navigation app does instead — carries the vehicle along that road at
/// that speed, every frame, and corrects towards each reading as it
/// arrives (see motion.dart). The vehicle then follows the bends of the
/// road rather than cutting across them, and does not stop dead between
/// updates. That is what makes the difference on the passenger's map, where
/// the driver's position comes through the database every couple of
/// seconds.
///
/// Only this layer redraws while it moves, not the screen around it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/models/glide.dart';
import '../../../core/models/motion.dart';
import 'vehicle_position.dart';

class GlidingMarkerLayer extends StatefulWidget {
  const GlidingMarkerLayer({
    super.key,
    required this.target,
    required this.child,
    this.width = 40,
    this.height = 40,
    this.route = const [],
    this.speed = 0,
    this.fixAt,
    this.reports,
  });

  /// Told where the marker is drawn, every frame, so the route line can
  /// start from exactly the same point instead of working it out again from
  /// a position that updates at a different rate.
  final VehiclePosition? reports;

  /// The latest reading, or null for no marker.
  final LatLng? target;
  final Widget child;
  final double width;
  final double height;

  /// The road the vehicle is on, when it is known. With this and [speed],
  /// the marker is driven along the route between readings.
  final List<LatLng> route;

  /// Metres per second, from the vehicle's own phone.
  final double speed;

  /// When [target] was measured — not when it arrived here. The two differ
  /// by however long the write and the listener took, and that difference
  /// is exactly what this layer is covering.
  final DateTime? fixAt;

  @override
  State<GlidingMarkerLayer> createState() => _GlidingMarkerLayerState();
}

class _GlidingMarkerLayerState extends State<GlidingMarkerLayer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(vsync: this)
    ..addListener(_step);

  LatLng? _from;
  LatLng? _to;
  LatLng? _shown;
  DateTime? _lastReading;

  @override
  void initState() {
    super.initState();
    _shown = _to = widget.target;
    _lastReading = DateTime.now();
  }

  /// Whether there is enough to drive the marker along the road rather than
  /// drag it between readings.
  bool get _canFollowRoad =>
      widget.route.length >= 2 &&
      widget.speed >= kMovingAtLeast &&
      widget.target != null;

  @override
  void didUpdateWidget(GlidingMarkerLayer old) {
    super.didUpdateWidget(old);
    if (_canFollowRoad) {
      _to = widget.target;
      // A repeating controller is just a frame ticker here: the position is
      // worked out from the clock and the road, not from its value.
      if (!_motion.isAnimating) {
        _motion
          ..duration = const Duration(seconds: 1)
          ..repeat();
      }
      return;
    }
    if (_motion.isAnimating && _motion.duration == const Duration(seconds: 1)) {
      _motion.stop();
    }
    // Equal readings arrive whenever the screen rebuilds for any other
    // reason; only a new position starts a glide.
    if (widget.target != _to) _glideTo(widget.target);
  }

  void _glideTo(LatLng? target) {
    final now = DateTime.now();
    final since = _lastReading == null
        ? Duration.zero
        : now.difference(_lastReading!);
    _lastReading = now;
    final from = _shown;
    _to = target;
    if (target == null || from == null) {
      _motion.stop();
      _show(target);
      return;
    }
    final duration = glideDuration(
      from: from,
      to: target,
      sinceLastReading: since,
    );
    if (duration == Duration.zero) {
      _motion.stop();
      _show(target);
      return;
    }
    // From wherever the marker is now — mid-glide if a reading came early —
    // so it never jumps back to the previous reading first.
    _from = from;
    _motion
      ..duration = duration
      ..forward(from: 0);
  }

  void _step() {
    if (_canFollowRoad) {
      _driveAlongRoad();
      return;
    }
    final from = _from, to = _to;
    if (from == null || to == null) return;
    _show(lerpLatLng(from, to, _motion.value));
  }

  /// How much of the gap to the road position is closed each frame.
  ///
  /// Eased rather than snapped: a reading that disagrees with where the
  /// marker had got to is worked in over a few frames, so a correction
  /// looks like the vehicle adjusting rather than teleporting.
  static const double _catchUpPerFrame = 0.18;

  void _driveAlongRoad() {
    final fix = widget.target;
    if (fix == null) return;
    final measuredAt = widget.fixAt ?? _lastReading ?? DateTime.now();
    final ought = carriedForward(
      lastFix: fix,
      sinceFix: DateTime.now().difference(measuredAt),
      speed: widget.speed,
      route: widget.route,
    ).at;

    final shown = _shown;
    if (shown == null) {
      _show(ought);
      return;
    }
    // A jump this size is a phone coming back after a gap, not movement.
    if (const Distance().as(LengthUnit.Meter, shown, ought) > kMaxGlideMeters) {
      _show(ought);
      return;
    }
    _show(lerpLatLng(shown, ought, _catchUpPerFrame));
  }

  /// Draws the marker at [at] and tells anything following where that is.
  void _show(LatLng? at) {
    setState(() => _shown = at);
    // After the frame: listeners rebuild, and a notification during build
    // would be rebuilding a widget that is already building.
    final reports = widget.reports;
    if (reports != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) reports.value = at;
      });
    }
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final at = _shown;
    return MarkerLayer(
      markers: [
        if (at != null)
          Marker(
            point: at,
            width: widget.width,
            height: widget.height,
            child: widget.child,
          ),
      ],
    );
  }
}

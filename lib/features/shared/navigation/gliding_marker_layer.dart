/// A map marker that glides between location readings instead of jumping.
///
/// Give it each new reading as [target]; it moves there smoothly over about
/// the time since the previous one (see glide.dart), so a tricycle reported
/// every few seconds is seen driving rather than hopping. Only this layer
/// redraws while it moves, not the screen around it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/models/glide.dart';

class GlidingMarkerLayer extends StatefulWidget {
  const GlidingMarkerLayer({
    super.key,
    required this.target,
    required this.child,
    this.width = 40,
    this.height = 40,
  });

  /// The latest reading, or null for no marker.
  final LatLng? target;
  final Widget child;
  final double width;
  final double height;

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

  @override
  void didUpdateWidget(GlidingMarkerLayer old) {
    super.didUpdateWidget(old);
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
      setState(() => _shown = target);
      return;
    }
    final duration = glideDuration(
      from: from,
      to: target,
      sinceLastReading: since,
    );
    if (duration == Duration.zero) {
      _motion.stop();
      setState(() => _shown = target);
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
    final from = _from, to = _to;
    if (from == null || to == null) return;
    setState(() => _shown = lerpLatLng(from, to, _motion.value));
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

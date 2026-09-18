/// A map marker for a vehicle, drawn exactly where its latest reading says.
///
/// This used to glide between readings and, given a route and a speed,
/// carry the vehicle forward along the road between them. Both were
/// removed: the marker is now drawn at the reported position, and moves
/// when the next reading arrives. What the map shows is only ever what the
/// phone actually reported — never an in-between or projected position.
///
/// The name is kept so the maps using it did not all have to change.
library;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'vehicle_position.dart';

class GlidingMarkerLayer extends StatefulWidget {
  const GlidingMarkerLayer({
    super.key,
    required this.target,
    required this.child,
    this.width = 40,
    this.height = 40,
    this.reports,
  });

  /// Told where the marker is drawn, so the route line starts from exactly
  /// the same point.
  final VehiclePosition? reports;

  /// The latest reading, or null for no marker.
  final LatLng? target;
  final Widget child;
  final double width;
  final double height;

  @override
  State<GlidingMarkerLayer> createState() => _GlidingMarkerLayerState();
}

class _GlidingMarkerLayerState extends State<GlidingMarkerLayer> {
  @override
  void initState() {
    super.initState();
    _report(widget.target);
  }

  @override
  void didUpdateWidget(GlidingMarkerLayer old) {
    super.didUpdateWidget(old);
    if (widget.target != old.target || widget.reports != old.reports) {
      _report(widget.target);
    }
  }

  /// After the frame: listeners rebuild, and a notification during build
  /// would be rebuilding a widget that is already building.
  void _report(LatLng? at) {
    final reports = widget.reports;
    if (reports == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) reports.value = at;
    });
  }

  @override
  Widget build(BuildContext context) {
    final at = widget.target;
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

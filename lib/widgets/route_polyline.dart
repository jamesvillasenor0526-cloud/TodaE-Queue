/// The road-following line between two points.
///
/// Routing still comes from OSRM rather than Google's Directions API: OSRM
/// is free and already wired in, whereas Directions is one of the SKUs
/// Google does bill for. Only the map display moved to Google.
///
/// Polylines are a parameter of the map rather than a child layer, so this
/// is a builder that hands the parent a ready-made polyline set.
library;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' hide LatLng;
import 'package:latlong2/latlong.dart';

import '../config/theme.dart';
import '../core/services/routing_service.dart';
import 'app_google_map.dart';

typedef RouteWidgetBuilder =
    Widget Function(BuildContext context, Set<Polyline> polylines);

class RouteBuilder extends StatefulWidget {
  const RouteBuilder({
    super.key,
    required this.from,
    required this.to,
    required this.builder,
    this.color = AppTheme.primaryBlue,
    this.width = 5,
  });

  final LatLng from;
  final LatLng to;
  final Color color;
  final int width;
  final RouteWidgetBuilder builder;

  @override
  State<RouteBuilder> createState() => _RouteBuilderState();
}

class _RouteBuilderState extends State<RouteBuilder> {
  List<LatLng>? _points;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  void didUpdateWidget(covariant RouteBuilder old) {
    super.didUpdateWidget(old);
    if (old.from != widget.from || old.to != widget.to) _fetch();
  }

  Future<void> _fetch() async {
    try {
      final points = await RoutingService.instance.getRoute(
        widget.from,
        widget.to,
      );
      if (mounted) setState(() => _points = points);
    } catch (_) {
      // A straight line is a worse answer than a route, but a much better
      // one than nothing while the routing service is unreachable.
      if (mounted) setState(() => _points = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final points = _points ?? [widget.from, widget.to];
    return widget.builder(context, {
      Polyline(
        polylineId: const PolylineId('route'),
        points: [for (final p in points) p.toMaps],
        color: widget.color,
        width: widget.width,
        startCap: Cap.roundCap,
        endCap: Cap.roundCap,
      ),
    });
  }
}

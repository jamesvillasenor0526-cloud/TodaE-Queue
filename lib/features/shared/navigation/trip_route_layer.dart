/// The route line, drawn from the shared trip record.
///
/// Both apps read the same `routePoints` the driver's navigation publishes,
/// so the line on the map is the route actually being driven — including
/// after a reroute or after the driver picks an alternative.
///
/// This replaces each map computing its own route. That arrangement looked
/// fine until the two disagreed: the panel would say 13 min down one road
/// while the line still showed another, because they were two unrelated
/// OSRM calls. A route the driver is not on is worse than no route at all.
///
/// The local fallback only covers the gap before navigation has published
/// anything — a booking accepted but not yet under way, say — and it is a
/// plain direct route, never a substitute for the published one.
library;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/services/navigation_service.dart';
import '../../../core/services/routing_service.dart';

class TripRouteLayer extends StatefulWidget {
  const TripRouteLayer({
    super.key,
    required this.bookingId,
    required this.from,
    required this.to,
    this.color = const Color(0xFF1565C0),
    this.strokeWidth = 5,
    this.controller,
  });

  final String bookingId;

  /// Used only for the fallback route, before anything is published.
  final LatLng from;
  final LatLng to;

  final Color color;
  final double strokeWidth;

  /// When given, the camera is moved to frame the whole route each time it
  /// changes, so the driver can actually see where they are being sent.
  final MapController? controller;

  @override
  State<TripRouteLayer> createState() => _TripRouteLayerState();
}

class _TripRouteLayerState extends State<TripRouteLayer> {
  List<LatLng>? _fallback;

  @override
  void initState() {
    super.initState();
    _fetchFallback();
  }

  @override
  void didUpdateWidget(covariant TripRouteLayer old) {
    super.didUpdateWidget(old);
    if (old.from != widget.from || old.to != widget.to) _fetchFallback();
  }

  /// Identifies a route cheaply, so the camera only moves when the route
  /// genuinely changes rather than on every rebuild.
  String? _framed;

  void _fitTo(List<LatLng> points) {
    final controller = widget.controller;
    if (controller == null || points.length < 2) return;

    final key = '${points.length}:${points.first}:${points.last}';
    if (key == _framed) return;
    _framed = key;

    // After this frame: the map is mid-build right now.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        controller.fitCamera(
          CameraFit.coordinates(
            coordinates: points,
            padding: const EdgeInsets.all(28),
            maxZoom: 16,
          ),
        );
      } catch (_) {
        // The map may not be laid out yet; the next route update re-fits.
      }
    });
  }

  Future<void> _fetchFallback() async {
    try {
      final points = await RoutingService.instance.getRoute(
        widget.from,
        widget.to,
      );
      if (mounted) setState(() => _fallback = points);
    } catch (_) {
      if (mounted) setState(() => _fallback = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<TripNavigation>(
      stream: NavigationService.instance.watch(widget.bookingId),
      builder: (context, snapshot) {
        final published = snapshot.data;

        // The published route wins whenever there is one: it is what the
        // driver is actually following.
        final usingPublished = published != null && published.hasRoute;
        final points = usingPublished
            ? published.routePoints
            : (_fallback ?? [widget.from, widget.to]);

        // Frame the whole route whenever it changes. Without this the map
        // sits at a fixed zoom showing a few hundred metres, where two
        // different routes look identical because they share the road just
        // ahead — a reroute happens and the driver cannot see that it did.
        _fitTo(points);

        if (points.length < 2) return const SizedBox.shrink();

        return PolylineLayer(
          polylines: [
            // A casing under the line keeps it legible over the traffic
            // colour, which is painted on the same roads.
            Polyline(
              points: points,
              strokeWidth: widget.strokeWidth + 3,
              color: Colors.white.withValues(alpha: 0.8),
              strokeCap: StrokeCap.round,
              strokeJoin: StrokeJoin.round,
            ),
            Polyline(
              points: points,
              strokeWidth: widget.strokeWidth,
              color: widget.color,
              strokeCap: StrokeCap.round,
              strokeJoin: StrokeJoin.round,
            ),
          ],
        );
      },
    );
  }
}

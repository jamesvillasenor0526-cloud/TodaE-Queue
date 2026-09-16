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

import '../../../core/models/live_route.dart';
import '../../../core/models/motion.dart';
import '../../../core/services/navigation_service.dart';
import 'vehicle_position.dart';
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
    this.follows,
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

  /// Where the vehicle marker is actually drawn, updated every frame by
  /// [GlidingMarkerLayer].
  ///
  /// The line is trimmed from here and joined to it, so it always starts
  /// under the marker. Without it the two were worked out separately — the
  /// marker from the eased, carried-forward position, the line from the
  /// last raw fix — and the line kept detaching from the vehicle and
  /// snapping back as the two drifted apart between readings.
  final VehiclePosition? follows;

  @override
  State<TripRouteLayer> createState() => _TripRouteLayerState();
}

class _TripRouteLayerState extends State<TripRouteLayer> {
  List<LatLng>? _fallback;

  /// When the fallback was last asked for, so a moving driver does not ask
  /// the router again every couple of seconds.
  DateTime? _fetchedAt;

  /// The least time between fallback fetches while the driver is on the
  /// route. The line still moves in between — it is trimmed locally — so
  /// this costs nothing visible.
  static const Duration _refetchEvery = Duration(seconds: 45);

  @override
  void initState() {
    super.initState();
    _fetchFallback();
  }

  @override
  void didUpdateWidget(covariant TripRouteLayer old) {
    super.didUpdateWidget(old);
    // Where they are going changed: the old line is about the wrong place.
    if (old.to != widget.to) {
      _fetchFallback();
      return;
    }
    if (old.from == widget.from) return;

    // The driver moved. The line is trimmed against their position on every
    // build, so a new route is only worth fetching when they have left the
    // one being shown — or when it is old enough to be worth refreshing.
    final route = _fallback;
    final wandered =
        route == null ||
        (progressAlong(route, widget.from)?.offRouteMeters ?? double.infinity) >
            kOnRouteMeters;
    final stale =
        _fetchedAt == null ||
        DateTime.now().difference(_fetchedAt!) > _refetchEvery;
    if (wandered && stale) _fetchFallback();
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
    _fetchedAt = DateTime.now();
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
        final whole = usingPublished
            ? published.routePoints
            : (_fallback ?? [widget.from, widget.to]);

        // Only what is still ahead. A route is fetched every so often, not
        // every second, so drawing it whole left a line that never moved
        // while the vehicle did — the marker slid along a line trailing
        // behind it the whole way. Trimmed here, the line starts under the
        // vehicle and shortens as it goes, on every map, without asking the
        // router for anything.
        // Frame the route whenever it changes — the whole one, not the
        // trimmed line. Framing what is left would move the camera on every
        // GPS reading, which is the map fighting the person reading it.
        _fitTo(whole);

        final follows = widget.follows;
        if (follows == null) return _line(lineAhead(whole, widget.from));

        // Redrawn from wherever the marker is, every frame it moves — and
        // only this layer redraws, not the map around it.
        return ValueListenableBuilder<LatLng?>(
          valueListenable: follows,
          builder: (context, drawnAt, _) =>
              _line(lineFromVehicle(whole, drawnAt ?? widget.from)),
        );
      },
    );
  }

  Widget _line(List<LatLng> points) {
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
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import '../../../widgets/map_tiles.dart';
import 'package:latlong2/latlong.dart';
import '../../../../config/theme.dart';
import '../../../../core/services/fare_service.dart';
import '../../../../core/services/routing_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class DestinationPickerScreen extends StatefulWidget {
  final double pickupLat;
  final double pickupLng;
  final String terminalId;
  final String terminalName;

  const DestinationPickerScreen({
    super.key,
    required this.pickupLat,
    required this.pickupLng,
    required this.terminalId,
    required this.terminalName,
  });

  @override
  State<DestinationPickerScreen> createState() =>
      _DestinationPickerScreenState();
}

class _DestinationPickerScreenState extends State<DestinationPickerScreen> {
  LatLng? _destination;
  bool _isCalculatingRoute = false;
  double? _routeDistance;
  double? _routeFare;
  double? _terminalToPickupDistance; // ← ADD
  double? _pickupToDestinationDistance; // ← ADD

  /// False when the router could not be reached and the distance is worked
  /// out from the straight line instead, so the fare can say so.
  bool _distanceMeasured = true;

  void _onMapTapped(TapPosition tapPosition, LatLng point) {
    setState(() {
      _destination = point;
      _routeDistance = null;
      _routeFare = null;
    });
    _calculateRouteAndFare(point);
  }

  Future<void> _calculateRouteAndFare(LatLng destination) async {
    final pickup = LatLng(widget.pickupLat, widget.pickupLng);

    try {
      // Get terminal coordinates from Firestore
      final terminalSnap = await FirebaseFirestore.instance
          .collection('terminals')
          .doc(widget.terminalId)
          .get();

      final terminalData = terminalSnap.data();
      final boundary = terminalData?['boundary'] as List<dynamic>? ?? [];
      if (boundary.isEmpty) return;

      final terminalPoint = _parseBoundaryPoint(boundary[0]);
      if (terminalPoint == null) return;

      // Road distance from terminal to pickup, and from pickup to where
      // they are going.
      final toPickup = await RoutingService.instance.roadDistance(
        terminalPoint,
        pickup,
      );
      final toDestination = await RoutingService.instance.roadDistance(
        pickup,
        destination,
      );
      final terminalToPickupDistance = toPickup.km;
      final pickupToDestinationDistance = toDestination.km;
      _distanceMeasured = toPickup.measured && toDestination.measured;

      // Total distance
      final totalDistance =
          terminalToPickupDistance + pickupToDestinationDistance;
      final fare = FareService.instance.calculateFareFromDistance(
        totalDistance,
      );

      if (mounted) {
        setState(() {
          _routeDistance = totalDistance;
          _routeFare = fare;
          _terminalToPickupDistance = terminalToPickupDistance; // ← ADD
          _pickupToDestinationDistance = pickupToDestinationDistance; // ← ADD
        });
      }
    } catch (e) {
      // Routing is best-effort: on failure the previously shown distance and
      // fare stay put rather than blanking the estimate.
      debugPrint('Route estimate failed: $e');
    }
  }

  Future<void> _confirmAndReturn() async {
    if (_destination == null) return;

    setState(() => _isCalculatingRoute = true);

    final pickup = LatLng(widget.pickupLat, widget.pickupLng);

    // Use calculated route distance, or calculate if not done yet
    final distance =
        _routeDistance ??
        await RoutingService.instance.getRouteDistance(pickup, _destination!);
    final fare =
        _routeFare ?? FareService.instance.calculateFareFromDistance(distance);

    if (!mounted) return;

    setState(() => _isCalculatingRoute = false);

    Navigator.pop(context, {
      'pickupLat': widget.pickupLat,
      'pickupLng': widget.pickupLng,
      'destinationLat': _destination!.latitude,
      'destinationLng': _destination!.longitude,
      'distance': distance,
      'fare': fare,
    });
  }

  LatLng? _parseBoundaryPoint(dynamic raw) {
    try {
      if (raw is GeoPoint) return LatLng(raw.latitude, raw.longitude);
      if (raw is List && raw.length >= 2) {
        final lat = _toDouble(raw[0]);
        final lng = _toDouble(raw[1]);
        if (lat != null && lng != null) return LatLng(lat, lng);
      }
      if (raw is Map) {
        final lat = _toDouble(raw['lat'] ?? raw['latitude']);
        final lng = _toDouble(raw['lng'] ?? raw['longitude']);
        if (lat != null && lng != null) return LatLng(lat, lng);
      }
    } catch (_) {}
    return null;
  }

  double? _toDouble(dynamic v) {
    if (v is double) return v;
    if (v is int) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final pickup = LatLng(widget.pickupLat, widget.pickupLng);

    // Display route distance if available, else straight-line
    final displayDistance =
        _routeDistance ??
        (_destination != null
            ? FareService.instance.calculateDistance(pickup, _destination!)
            : 0);
    final displayFare =
        _routeFare ??
        FareService.instance.calculateFareFromDistance(displayDistance);

    return Scaffold(
      appBar: AppBar(title: const Text('Select Destination')),
      body: Stack(
        children: [
          FlutterMap(
            options: MapOptions(
              initialCenter: pickup,
              initialZoom: 15,
              onTap: _onMapTapped,
            ),
            children: [
              AppTileLayer(),
              MarkerLayer(
                markers: [
                  Marker(
                    point: pickup,
                    width: 40,
                    height: 40,
                    child: const Icon(
                      Icons.location_on,
                      color: AppTheme.primaryGreen,
                      size: 40,
                    ),
                  ),
                  if (_destination != null)
                    Marker(
                      point: _destination!,
                      width: 40,
                      height: 40,
                      child: const Icon(
                        Icons.flag,
                        color: AppTheme.errorRed,
                        size: 40,
                      ),
                    ),
                ],
              ),
              // Road-following polyline
              if (_destination != null)
                _RoutingPolyline(
                  driverPoint: pickup,
                  pickupPoint: _destination!,
                ),
            ],
          ),
          // Instructions
          Positioned(
            top: 12,
            left: 12,
            right: 12,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Text(
                '📍 Tap the map to set your destination',
                style: TextStyle(color: Colors.white, fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ),
          ),
          // Fare info + Confirm button at bottom
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(20),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.1),
                    blurRadius: 10,
                    offset: const Offset(0, -2),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_destination != null) ...[
                    // Terminal → Pickup
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          '🏁 Terminal → Pickup',
                          style: TextStyle(
                            fontSize: 13,
                            color: AppTheme.textMuted,
                          ),
                        ),
                        Text(
                          _terminalToPickupDistance != null
                              ? '${_terminalToPickupDistance!.toStringAsFixed(2)} km'
                              : '...',
                          style: const TextStyle(
                            fontWeight: FontWeight.w500,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // Pickup → Destination
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          '📏 Pickup → Destination',
                          style: TextStyle(
                            fontSize: 13,
                            color: AppTheme.textMuted,
                          ),
                        ),
                        Text(
                          _pickupToDestinationDistance != null
                              ? '${_pickupToDestinationDistance!.toStringAsFixed(2)} km'
                              : '...',
                          style: const TextStyle(
                            fontWeight: FontWeight.w500,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                    const Divider(height: 20),
                    // Total
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          '📏 Total Distance',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          _routeDistance != null
                              ? '${_routeDistance!.toStringAsFixed(2)} km'
                              : '...',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          '💰 Total Fare',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          FareService.instance.formatFare(displayFare),
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.primaryGreen,
                          ),
                        ),
                      ],
                    ),
                    if (!_distanceMeasured && _destination != null)
                      const Padding(
                        padding: EdgeInsets.only(top: 6),
                        child: Text(
                          'Estimated — the road distance could not be '
                          'checked just now.',
                          style: TextStyle(
                            fontSize: 11,
                            color: AppTheme.textMuted,
                          ),
                        ),
                      ),
                    const SizedBox(height: 16),
                    TextButton.icon(
                      onPressed: () => setState(() {
                        _destination = null;
                        _routeDistance = null;
                        _routeFare = null;
                        _distanceMeasured = true;
                        _terminalToPickupDistance = null; // ← ADD
                        _pickupToDestinationDistance = null; // ← ADD
                      }),
                      icon: const Icon(Icons.clear, size: 16),
                      label: const Text(
                        'Clear Destination',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _destination != null
                          ? _confirmAndReturn
                          : null,
                      icon: _isCalculatingRoute
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.check_circle),
                      label: Text(
                        _isCalculatingRoute
                            ? 'Calculating Route...'
                            : _destination != null
                            ? 'Confirm & Book'
                            : 'Tap map to set destination',
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primaryGreen,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Routing Polyline Widget ────────────────────────────────────────────────

class _RoutingPolyline extends StatefulWidget {
  final LatLng driverPoint;
  final LatLng pickupPoint;

  const _RoutingPolyline({
    required this.driverPoint,
    required this.pickupPoint,
  });

  @override
  State<_RoutingPolyline> createState() => _RoutingPolylineState();
}

class _RoutingPolylineState extends State<_RoutingPolyline> {
  List<LatLng>? _routePoints;

  @override
  void initState() {
    super.initState();
    _fetchRoute();
  }

  @override
  void didUpdateWidget(covariant _RoutingPolyline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.driverPoint != widget.driverPoint ||
        oldWidget.pickupPoint != widget.pickupPoint) {
      _fetchRoute();
    }
  }

  Future<void> _fetchRoute() async {
    try {
      final points = await RoutingService.instance.getRoute(
        widget.driverPoint,
        widget.pickupPoint,
      );
      if (mounted) setState(() => _routePoints = points);
    } catch (e) {
      if (mounted) setState(() => _routePoints = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final points = _routePoints ?? [widget.driverPoint, widget.pickupPoint];
    return PolylineLayer(
      polylines: [
        Polyline(points: points, color: AppTheme.primaryBlue, strokeWidth: 3),
      ],
    );
  }
}

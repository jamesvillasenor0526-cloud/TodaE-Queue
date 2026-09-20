import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import '../../../widgets/map_tiles.dart';
import 'package:latlong2/latlong.dart';
import '../../../../config/theme.dart';
import '../../../../core/models/place_search.dart';
import '../../../../core/models/service_area.dart';
import '../../../../core/services/fare_service.dart';
import '../../../../core/services/routing_service.dart';
import '../../../../core/services/service_area_service.dart';
import '../../shared/map/place_search_box.dart';
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
  /// So a searched place can be brought into view.
  final MapController _mapController = MapController();
  LatLng? _destination;
  bool _isCalculatingRoute = false;
  double? _routeDistance;
  double? _routeFare;
  double? _terminalToPickupDistance;
  double? _pickupToDestinationDistance;

  /// False when the router could not be reached and the distance is worked
  /// out from the straight line instead, so the fare can say so.
  bool _distanceMeasured = true;

  /// Whether where they are going lies outside Baliwag, and what it adds.
  OutOfTown _outOfTown = OutOfTown.none;

  @override
  void initState() {
    super.initState();
    // The town outline is a bundled asset; reading it is quick and only
    // happens once. Until it arrives, nothing counts as out of town.
    ServiceAreaService.instance.load().then((_) {
      if (!mounted) return;
      setState(() {}); // draws the town line
      final destination = _destination;
      if (destination != null) _calculateRouteAndFare(destination);
    });
  }

  void _onMapTapped(TapPosition tapPosition, LatLng point) {
    setState(() {
      _destination = point;
      _routeDistance = null;
      _routeFare = null;
      _outOfTown = OutOfTown.none;
    });
    _calculateRouteAndFare(point);
  }

  /// Sets a searched place as the destination and works out the fare to it,
  /// exactly as tapping the map does.
  void _useSearchResult(PlaceHit place) {
    _onMapTapped(TapPosition(Offset.zero, Offset.zero), place.at);
    _mapController.move(place.at, 16);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Destination set to ${place.name}'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// Set when the fare could not be worked out, so the passenger is told and
  /// can try again rather than waiting on a spinner that never finishes.
  bool _fareFailed = false;

  /// Whether the distance and fare on screen are for [_destination] — not
  /// for a spot tapped earlier, and not a placeholder.
  bool get _fareReady =>
      _destination != null && _routeFare != null && !_isCalculatingRoute;

  Future<void> _calculateRouteAndFare(LatLng destination) async {
    final pickup = LatLng(widget.pickupLat, widget.pickupLng);
    if (mounted) {
      setState(() {
        _isCalculatingRoute = true;
        _fareFailed = false;
      });
    }

    // Only the answer for the spot still selected counts. Tapping twice in
    // quick succession ran two of these at once, and whichever finished last
    // won — so the fare for the first spot could be shown, and booked, for
    // the second.
    bool stillWanted() => mounted && _destination == destination;

    try {
      // Get terminal coordinates from Firestore
      final terminalSnap = await FirebaseFirestore.instance
          .collection('terminals')
          .doc(widget.terminalId)
          .get();

      final terminalData = terminalSnap.data();
      final boundary = terminalData?['boundary'] as List<dynamic>? ?? [];
      final terminalPoint = boundary.isEmpty
          ? null
          : _parseBoundaryPoint(boundary[0]);
      if (terminalPoint == null) {
        throw StateError('Terminal ${widget.terminalId} has no location');
      }

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

      // Outside Baliwag, the driver comes back empty, so the kilometres past
      // the town line are charged again — unless the destination is close
      // enough to the terminal to be an ordinary short trip.
      final outOfTown = ServiceAreaService.instance.check(
        destination: destination,
        terminal: terminalPoint,
      );
      final fare = FareService.instance.fareWithReturn(
        distanceInKm: totalDistance,
        kmOutside: outOfTown.charged ? outOfTown.kmOutside : 0,
      );

      if (!stillWanted()) return;
      setState(() {
        _routeDistance = totalDistance;
        _routeFare = fare;
        _outOfTown = outOfTown;
        _terminalToPickupDistance = terminalToPickupDistance;
        _pickupToDestinationDistance = pickupToDestinationDistance;
        _isCalculatingRoute = false;
      });
    } catch (e) {
      debugPrint('Route estimate failed: $e');
      if (!stillWanted()) return;
      setState(() {
        _isCalculatingRoute = false;
        _fareFailed = true;
      });
    }
  }

  void _confirmAndReturn() {
    // Only ever the fare worked out for this destination, terminal leg and
    // out-of-town charge included. Confirming early used to book a fallback
    // that left both out.
    if (!_fareReady) return;
    final distance = _routeDistance!;
    final fare = _routeFare!;

    Navigator.pop(context, {
      'pickupLat': widget.pickupLat,
      'pickupLng': widget.pickupLng,
      'destinationLat': _destination!.latitude,
      'destinationLng': _destination!.longitude,
      'distance': distance,
      'fare': fare,
      // Carried on to the booking so the driver sees why the fare is higher
      // and can say no to the trip.
      'outsideServiceArea': _outOfTown.outside,
      'outOfTownFee': _outOfTown.charged
          ? FareService.instance.outOfTownExtra(_outOfTown.kmOutside)
          : 0.0,
      'outOfTownKm': _outOfTown.charged ? _outOfTown.kmOutside : 0.0,
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

    // No placeholder fare. A straight-line guess was shown while the real one
    // was worked out, lower than the real one — so the price jumped up a
    // moment later, after the passenger had already read it.
    final displayFare = _fareReady
        ? FareService.instance.formatFare(_routeFare!)
        : _fareFailed
        ? '—'
        : '...';
    final outOfTownFee = _outOfTown.charged
        ? FareService.instance.outOfTownExtra(_outOfTown.kmOutside)
        : 0.0;

    return Scaffold(
      appBar: AppBar(title: const Text('Select Destination')),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: pickup,
              initialZoom: 15,
              onTap: _onMapTapped,
            ),
            children: [
              AppTileLayer(muted: false),
              // The town line, so it is clear where the ordinary fare ends.
              if (ServiceAreaService.instance.area.isUsable)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: [
                        ...ServiceAreaService.instance.area.outline,
                        ServiceAreaService.instance.area.outline.first,
                      ],
                      color: AppTheme.primaryGreen.withValues(alpha: 0.5),
                      strokeWidth: 2,
                    ),
                  ],
                ),
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
          // Search, then the instruction. Tapping the map still works.
          Positioned(
            top: 12,
            left: 12,
            right: 12,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PlaceSearchBox(
                  hint: 'Search for your destination',
                  near: _destination ?? pickup,
                  onPicked: _useSearchResult,
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Text(
                    'Search above, or tap the map to set your destination',
                    style: TextStyle(color: Colors.white, fontSize: 13),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
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
                          'Terminal → Pickup',
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
                          'Pickup → Destination',
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
                          'Total Distance',
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
                    if (outOfTownFee > 0) ...[
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Text(
                              'Outside Baliwag '
                              '(${_outOfTown.kmOutside.toStringAsFixed(1)} km)',
                              style: const TextStyle(
                                fontSize: 13,
                                color: AppTheme.textMuted,
                              ),
                            ),
                          ),
                          Text(
                            '+${FareService.instance.formatFare(outOfTownFee)}',
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                              color: AppTheme.errorRed,
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Total Fare',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          displayFare,
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.primaryGreen,
                          ),
                        ),
                      ],
                    ),
                    if (_fareFailed)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Row(
                          children: [
                            const Expanded(
                              child: Text(
                                'Could not work out the fare. Check your '
                                'connection and try again.',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: AppTheme.errorRed,
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: () =>
                                  _calculateRouteAndFare(_destination!),
                              child: const Text('Try again'),
                            ),
                          ],
                        ),
                      ),
                    if (!_distanceMeasured && _fareReady)
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
                    if (outOfTownFee > 0)
                      const Padding(
                        padding: EdgeInsets.only(top: 6),
                        child: Text(
                          'This trip leaves Baliwag. The driver returns '
                          'empty, so the distance outside town is charged '
                          'twice — and a driver has to accept the trip '
                          'first.',
                          style: TextStyle(
                            fontSize: 11,
                            color: AppTheme.textMuted,
                          ),
                        ),
                      )
                    else if (_outOfTown.outside)
                      const Padding(
                        padding: EdgeInsets.only(top: 6),
                        child: Text(
                          'Just outside Baliwag, but close to the terminal — '
                          'charged as a normal trip.',
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
                        _outOfTown = OutOfTown.none;
                        _distanceMeasured = true;
                        _fareFailed = false;
                        _isCalculatingRoute = false;
                        _terminalToPickupDistance = null;
                        _pickupToDestinationDistance = null;
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
                      onPressed: _fareReady ? _confirmAndReturn : null,
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
                            ? 'Calculating fare...'
                            : _fareReady
                            ? 'Confirm & Book'
                            : _fareFailed
                            ? 'Fare unavailable'
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

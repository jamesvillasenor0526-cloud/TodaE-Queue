import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import '../../../widgets/map_tiles.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import '../../../config/theme.dart';
import '../../../core/models/place_search.dart';
import '../../shared/map/place_search_box.dart';

class PickupLocationScreen extends StatefulWidget {
  final String terminalId;
  final String terminalName;

  const PickupLocationScreen({
    super.key,
    required this.terminalId,
    required this.terminalName,
  });

  @override
  State<PickupLocationScreen> createState() => _PickupLocationScreenState();
}

class _PickupLocationScreenState extends State<PickupLocationScreen> {
  static const LatLng _baliwagCenter = LatLng(14.9540, 120.9010);

  final MapController _mapController = MapController();

  LatLng? _selectedLocation;
  LatLng? _currentLocation;
  bool _isLoadingLocation = true;
  bool _locationUnavailable = false;

  @override
  void initState() {
    super.initState();
    _getCurrentLocation();
  }

  Future<void> _getCurrentLocation() async {
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      if (mounted) {
        setState(() {
          _currentLocation = LatLng(position.latitude, position.longitude);
          _selectedLocation = _currentLocation;
          _isLoadingLocation = false;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _mapController.move(_currentLocation!, 16);
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingLocation = false;
          _locationUnavailable = true;
          _selectedLocation = _baliwagCenter;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _mapController.move(_baliwagCenter, 15);
        });
      }
    }
  }

  void _onMapTapped(TapPosition tapPosition, LatLng point) {
    setState(() {
      _selectedLocation = point;
    });
  }

  /// Moves the map to a searched place and sets it as the pick-up, which the
  /// passenger can still nudge by tapping.
  void _useSearchResult(PlaceHit place) {
    setState(() => _selectedLocation = place.at);
    _mapController.move(place.at, 17);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Pick-up set to ${place.name}'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _confirmLocation() {
    if (_selectedLocation == null) return;

    Navigator.pop(context, {
      'latitude': _selectedLocation!.latitude,
      'longitude': _selectedLocation!.longitude,
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Confirm Pickup Location'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: _isLoadingLocation
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              children: [
                // Map
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: _currentLocation ?? _baliwagCenter,
                    initialZoom: 16,
                    onTap: _onMapTapped,
                  ),
                  children: [
                    AppTileLayer(muted: false),
                    // Selected pickup pin (red)
                    if (_selectedLocation != null)
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: _selectedLocation!,
                            width: 40,
                            height: 40,
                            child: const Icon(
                              Icons.location_on,
                              color: AppTheme.errorRed,
                              size: 36,
                            ),
                          ),
                        ],
                      ),
                    // Current location dot (blue)
                    if (_currentLocation != null)
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: _currentLocation!,
                            width: 24,
                            height: 24,
                            child: Container(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.blue.withValues(alpha: 0.3),
                                border: Border.all(
                                  color: AppTheme.info,
                                  width: 2,
                                ),
                              ),
                              child: const Center(
                                child: Icon(
                                  Icons.my_location,
                                  color: AppTheme.info,
                                  size: 14,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),

                // No crosshair at the centre of the screen: it stayed put
                // while the map moved and marked nothing, so next to the
                // real pin it read as a second pickup point.

                // Search, and the instruction under it. Tapping the map
                // still works; this is for a passenger who knows the name
                // of the place but not where it sits on the map.
                Positioned(
                  top: 12,
                  left: 12,
                  right: 12,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      PlaceSearchBox(
                        hint: 'Search for your pick-up point',
                        near: _selectedLocation ?? _baliwagCenter,
                        onPicked: _useSearchResult,
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.75),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Text(
                          '📍 Search above, or tap the map to set your pickup '
                          'location',
                          style: TextStyle(color: Colors.white, fontSize: 13),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                  ),
                ),

                // Location unavailable warning
                if (_locationUnavailable)
                  Positioned(
                    top: 140,
                    left: 12,
                    right: 12,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.orange.withValues(alpha: 0.9),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text(
                        '⚠️ GPS unavailable. Tap the map to set your pickup spot.',
                        style: TextStyle(color: Colors.white, fontSize: 12),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),

                // My location button
                Positioned(
                  bottom: 100,
                  right: 16,
                  child: FloatingActionButton.small(
                    backgroundColor: Colors.white,
                    onPressed: () {
                      if (_currentLocation != null) {
                        _mapController.move(_currentLocation!, 16);
                        setState(() {
                          _selectedLocation = _currentLocation;
                        });
                      }
                    },
                    child: const Icon(Icons.my_location, color: AppTheme.info),
                  ),
                ),

                // Confirm button
                Positioned(
                  bottom: 24,
                  left: 24,
                  right: 24,
                  child: ElevatedButton.icon(
                    onPressed: _selectedLocation != null
                        ? _confirmLocation
                        : null,
                    icon: const Icon(Icons.check_circle),
                    label: Text(
                      _selectedLocation != null
                          ? 'Confirm Pickup: ${_selectedLocation!.latitude.toStringAsFixed(5)}, ${_selectedLocation!.longitude.toStringAsFixed(5)}'
                          : 'Tap map to set pickup location',
                      style: const TextStyle(fontSize: 13),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primaryGreen,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        vertical: 14,
                        horizontal: 20,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

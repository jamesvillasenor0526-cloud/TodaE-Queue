import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' hide LatLng;
import '../../../widgets/app_google_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import '../../../config/theme.dart';

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

  GoogleMapController? _mapController;

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
          _mapController.moveTo(_currentLocation!, 16);
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
          _mapController.moveTo(_baliwagCenter, 15);
        });
      }
    }
  }

  void _onMapTapped(LatLng point) {
    setState(() {
      _selectedLocation = point;
    });
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
                AppGoogleMap(
                  initialCenter: _currentLocation ?? _baliwagCenter,
                  initialZoom: 16,
                  onTap: _onMapTapped,
                  onMapCreated: (c) => _mapController = c,
                  // The device dot is drawn by the SDK, so the app no longer
                  // maintains a marker for it.
                  showMyLocation: true,
                  markers: {
                    if (_selectedLocation != null)
                      Marker(
                        markerId: const MarkerId('pickup'),
                        position: _selectedLocation!.toMaps,
                        icon: BitmapDescriptor.defaultMarkerWithHue(
                          BitmapDescriptor.hueRed,
                        ),
                        infoWindow: const InfoWindow(title: 'Pickup point'),
                      ),
                  },
                ),

                // Center crosshair
                const Center(
                  child: Icon(
                    Icons.add_location,
                    color: AppTheme.errorRed,
                    size: 40,
                  ),
                ),

                // Instructions
                Positioned(
                  top: 12,
                  left: 12,
                  right: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.75),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Text(
                      '📍 Tap anywhere on the map to set your pickup location',
                      style: TextStyle(color: Colors.white, fontSize: 13),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),

                // Location unavailable warning
                if (_locationUnavailable)
                  Positioned(
                    top: 70,
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
                        _mapController.moveTo(_currentLocation!, 16);
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

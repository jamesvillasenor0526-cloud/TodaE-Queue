import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_map/flutter_map.dart';
import '../../../widgets/map_tiles.dart';
import 'package:latlong2/latlong.dart';
import '../../../config/theme.dart';
import '../../../config/routes.dart';
import '../../../core/services/dispatch_service.dart';
import '../../../core/models/road_report.dart';
import '../../shared/reports/report_map_layer.dart';
import '../../shared/reports/report_sheet.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:geolocator/geolocator.dart';

class TerminalMapScreen extends StatefulWidget {
  const TerminalMapScreen({super.key});

  @override
  State<TerminalMapScreen> createState() => _TerminalMapScreenState();
}

class _TerminalMapScreenState extends State<TerminalMapScreen> {
  static const LatLng _baliwagCenter = LatLng(14.9540, 120.9010);

  final MapController _mapController = MapController();
  final TextEditingController _searchController = TextEditingController();
  List<Map<String, dynamic>> _searchResults = [];
  LatLng? _searchedLocation;
  String? _searchedLocationName;
  bool _isSearching = false;

  LatLng? _userLocation;
  Map<String, double> _terminalDistances = {};
  List<RoadReport> _nearbyReports = const [];

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

  void _searchLocation(String query) async {
    if (query.trim().isEmpty) {
      setState(() {
        _searchResults = [];
        _isSearching = false;
      });
      return;
    }

    setState(() => _isSearching = true);

    try {
      final results = await FirebaseFirestore.instance
          .collection('terminals')
          .get();

      final matching = results.docs
          .where((doc) {
            final name = (doc.data()['name'] ?? '').toString().toLowerCase();
            return name.contains(query.toLowerCase());
          })
          .map(
            (doc) => {
              'id': doc.id,
              'name': doc.data()['name'] ?? 'Terminal',
              'boundary': doc.data()['boundary'] ?? [],
            },
          )
          .toList();

      if (mounted) {
        setState(() {
          _searchResults = matching;
          _isSearching = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSearching = false);
        _searchResults = [];
      }
    }
  }

  void _selectSearchResult(Map<String, dynamic> result) {
    final boundary = result['boundary'] as List<dynamic>? ?? [];
    if (boundary.isEmpty) return;

    final point = _parseBoundaryPoint(boundary[0]);
    if (point == null) return;

    setState(() {
      _searchedLocation = point;
      _searchedLocationName = result['name'];
      _searchResults = [];
      _searchController.clear();
    });

    _mapController.move(point, 16);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('📍 ${result['name']}'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  void _clearSearch() {
    setState(() {
      _searchResults = [];
      _searchedLocation = null;
      _searchedLocationName = null;
      _searchController.clear();
    });
    _mapController.move(_baliwagCenter, 15);
  }

  Future<void> _findNearestTerminal() async {
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      if (!mounted) return;

      setState(() {
        _userLocation = LatLng(position.latitude, position.longitude);
      });

      // Fetch terminals and calculate distances
      final terminalsSnap = await FirebaseFirestore.instance
          .collection('terminals')
          .get();

      final terminalDistances = <String, double>{};
      LatLng? nearestPoint;
      String? nearestName;
      double? shortestDistance;

      for (final doc in terminalsSnap.docs) {
        final data = doc.data();
        final boundary = data['boundary'] as List<dynamic>? ?? [];
        if (boundary.isEmpty) continue;

        final point = _parseBoundaryPoint(boundary[0]);
        if (point == null) continue;

        final distance = const Distance().as(
          LengthUnit.Kilometer,
          _userLocation!,
          point,
        );

        terminalDistances[doc.id] = distance;

        if (shortestDistance == null || distance < shortestDistance) {
          shortestDistance = distance;
          nearestPoint = point;
          nearestName = data['name'] ?? 'Terminal';
        }
      }

      if (!mounted) return;

      setState(() {
        _terminalDistances = terminalDistances;
      });

      // Move map to nearest terminal
      if (nearestPoint != null && nearestName != null) {
        _mapController.move(nearestPoint, 16);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '📍 Nearest: $nearestName (${shortestDistance?.toStringAsFixed(1)} km)',
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      debugPrint('Find nearest error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not find nearest terminal.')),
        );
      }
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Terminal Map')),
      body: Stack(
        children: [
          // Map
          StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('terminals')
                .snapshots(),
            builder: (context, snapshot) {
              final terminals = snapshot.data?.docs ?? [];

              final markers = terminals
                  .map((doc) {
                    final data = doc.data() as Map<String, dynamic>;
                    final boundary = data['boundary'] as List<dynamic>? ?? [];
                    if (boundary.isEmpty) return null;

                    final point = _parseBoundaryPoint(boundary[0]);
                    if (point == null) return null;

                    return Marker(
                      point: point,
                      width: 120,
                      height: 60,
                      child: GestureDetector(
                        onTap: () async {
                          final result =
                              await showModalBottomSheet<DispatchResult>(
                                context: context,
                                builder: (_) => _TerminalSheet(
                                  name: data['name'] ?? 'Terminal',
                                  terminalId: doc.id,
                                ),
                              );

                          if (result == null || !context.mounted) return;

                          if (result.success) {
                            final terminalName = data['name'] ?? 'Terminal';
                            showDialog(
                              context: context,
                              builder: (dialogContext) => AlertDialog(
                                title: const Text('Driver on the way! 🚖'),
                                content: Text(
                                  '${result.driverName} has been dispatched from $terminalName.',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () {
                                      Navigator.pop(dialogContext);
                                      Navigator.pushReplacementNamed(
                                        context,
                                        AppRoutes.tripTracking,
                                        arguments: {
                                          'bookingId': result.bookingId ?? '',
                                          'driverName':
                                              result.driverName ?? 'Driver',
                                          'terminalName': terminalName,
                                        },
                                      );
                                    },
                                    child: const Text('Track Driver'),
                                  ),
                                ],
                              ),
                            );
                          } else {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  result.message ?? 'Could not book a ride.',
                                ),
                              ),
                            );
                          }
                        },
                        child: Column(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: AppTheme.primaryGreen,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                data['name'] ?? 'Terminal',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const Icon(
                              Icons.location_on,
                              color: AppTheme.primaryGreen,
                              size: 24,
                            ),
                          ],
                        ),
                      ),
                    );
                  })
                  .whereType<Marker>()
                  .toList();

              // Add searched location marker
              if (_searchedLocation != null) {
                markers.add(
                  Marker(
                    point: _searchedLocation!,
                    width: 40,
                    height: 40,
                    child: const Icon(
                      Icons.search,
                      color: AppTheme.info,
                      size: 32,
                    ),
                  ),
                );
              }

              return FlutterMap(
                mapController: _mapController,
                options: const MapOptions(
                  initialCenter: _baliwagCenter,
                  initialZoom: 15,
                ),
                children: [
                  AppTileLayer(),
                  // Shaded beneath the terminal pins so the traffic colour
                  // never hides the thing the user came here to tap.
                  TrafficOverlay(
                    origin: _userLocation ?? _baliwagCenter,
                    onReportsChanged: (reports) {
                      if (!mounted ||
                          reports.length == _nearbyReports.length) {
                        return;
                      }
                      setState(() => _nearbyReports = reports);
                    },
                  ),
                  MarkerLayer(markers: markers),
                  const AppMapAttribution(),
                ],
              );
            },
          ),

          // Search bar
          Positioned(
            top: 12,
            left: 12,
            right: 12,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black26,
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: '🔍 Search terminal...',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _searchController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: _clearSearch,
                        )
                      : null,
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                ),
                onChanged: _searchLocation,
              ),
            ),
          ),

          // Search results dropdown
          if (_searchResults.isNotEmpty)
            Positioned(
              top: 70,
              left: 12,
              right: 12,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 8)],
                ),
                constraints: const BoxConstraints(maxHeight: 200),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _searchResults.length,
                  itemBuilder: (context, index) {
                    final result = _searchResults[index];
                    return ListTile(
                      leading: const Icon(
                        Icons.location_on,
                        color: AppTheme.primaryGreen,
                      ),
                      title: Text(
                        result['name'] ?? 'Terminal',
                        style: const TextStyle(fontSize: 14),
                      ),
                      subtitle: _terminalDistances.containsKey(result['id'])
                          ? Text(
                              '${_terminalDistances[result['id']]!.toStringAsFixed(1)} km away',
                              style: const TextStyle(
                                fontSize: 11,
                                color: AppTheme.textMuted,
                              ),
                            )
                          : null,
                      trailing:
                          _terminalDistances.containsKey(result['id']) &&
                              _terminalDistances[result['id']] ==
                                  _terminalDistances.values.reduce(
                                    (a, b) => a < b ? a : b,
                                  )
                          ? const Icon(
                              Icons.star,
                              color: Colors.amber,
                              size: 16,
                            )
                          : null,
                      dense: true,
                      onTap: () => _selectSearchResult(result),
                    );
                  },
                ),
              ),
            ),

          Positioned(
            top: 70,
            right: 12,
            child: Column(
              children: [
                FloatingActionButton.small(
                  heroTag: 'nearestTerminal',
                  backgroundColor: AppTheme.info,
                  tooltip: 'Find nearest terminal',
                  onPressed: _findNearestTerminal,
                  child: const Icon(
                    Icons.near_me,
                    color: Colors.white,
                    size: 18,
                  ),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.small(
                  heroTag: 'reportCondition',
                  backgroundColor: AppTheme.warning,
                  tooltip: 'Report traffic or an incident',
                  onPressed: () => showReportSheet(context),
                  child: const Icon(
                    Icons.add_alert,
                    color: Colors.white,
                    size: 18,
                  ),
                ),
              ],
            ),
          ),

          // The shading has no tappable pins, so this is the way into the
          // detail behind it — and it doubles as a hint that the overlay is
          // live rather than decorative.
          if (_nearbyReports.isNotEmpty)
            Positioned(
              top: 70,
              left: 12,
              child: Semantics(
                button: true,
                child: InkWell(
                  onTap: () => showConditionsSheet(context, _nearbyReports),
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black26,
                          blurRadius: 6,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.traffic,
                          size: 14,
                          color: AppTheme.warning,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '${_nearbyReports.length} nearby '
                          '${_nearbyReports.length == 1 ? 'report' : 'reports'}',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Icon(Icons.chevron_right, size: 14),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          // Bottom-left is taken by the OpenStreetMap attribution.
          const Positioned(bottom: 16, right: 12, child: TrafficLegend()),

          // Searched location indicator
          if (_searchedLocationName != null)
            Positioned(
              bottom: 16,
              left: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.info,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.search, color: Colors.white, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _searchedLocationName!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.close,
                        color: Colors.white,
                        size: 16,
                      ),
                      onPressed: _clearSearch,
                    ),
                  ],
                ),
              ),
            ),

          // Loading indicator
          if (_isSearching)
            const Positioned(
              top: 70,
              left: 12,
              right: 12,
              child: LinearProgressIndicator(),
            ),
        ],
      ),
    );
  }
}

class _TerminalSheet extends StatefulWidget {
  final String name;
  final String terminalId;

  const _TerminalSheet({required this.name, required this.terminalId});

  @override
  State<_TerminalSheet> createState() => _TerminalSheetState();
}

class _TerminalSheetState extends State<_TerminalSheet> {
  bool _isBooking = false;

  Future<void> _bookRide() async {
    setState(() => _isBooking = true);
    final passengerId = FirebaseAuth.instance.currentUser!.uid;
    final result = await DispatchService.instance.dispatchNextDriver(
      terminalId: widget.terminalId,
      passengerId: passengerId,
    );
    if (!mounted) return;
    Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.location_on, color: AppTheme.primaryGreen),
              const SizedBox(width: 8),
              Text(
                widget.name,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('queueEntries')
                .where('terminalId', isEqualTo: widget.terminalId)
                .where('status', isEqualTo: 'waiting')
                .snapshots(),
            builder: (context, snapshot) {
              final count = snapshot.data?.docs.length ?? 0;
              return Text(
                '$count driver(s) in queue',
                style: const TextStyle(color: AppTheme.textMuted),
              );
            },
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: _isBooking ? null : _bookRide,
            icon: _isBooking
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.electric_rickshaw),
            label: Text(_isBooking ? 'Booking...' : 'Book from this terminal'),
          ),
        ],
      ),
    );
  }
}

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../../../config/routes.dart';
import '../../../config/theme.dart';
import '../../../core/services/geofence_service.dart';
import '../../../core/services/dispatch_service.dart';
import '../../../core/services/notification_service.dart';

class DriverHomeScreen extends StatefulWidget {
  const DriverHomeScreen({super.key});

  @override
  State<DriverHomeScreen> createState() => _DriverHomeScreenState();
}

class _DriverHomeScreenState extends State<DriverHomeScreen> {
  final uid = FirebaseAuth.instance.currentUser!.uid;
  final _geofence = GeofenceService.instance;
  int _currentIndex = 0;

  StreamSubscription<Position>? _positionSub;
  bool _isCheckingLocation = false;
  bool _locationPermissionDenied = false;
  String? _lastPromptedTerminalId;
  bool _hasActiveEntry = false;
  String? _activeBookingId;

  @override
  void initState() {
    super.initState();
    _startLocationWatch();
  }

  @override
  void dispose() {
    // Only cancel this screen's own listener — the shared GPS stream
    // itself is stopped centrally here too, since this is the screen that
    // started it and nothing else should need it once the driver leaves.
    _positionSub?.cancel();
    _geofence.stopTracking();
    super.dispose();
  }

  Future<void> _startLocationWatch() async {
    final started = await _geofence.startTracking();
    if (!started) {
      if (mounted) setState(() => _locationPermissionDenied = true);
      return;
    }
    _positionSub = _geofence.positionStream.listen(_onPositionUpdate);
  }

  Future<void> _onPositionUpdate(Position position) async {
    // Update driver location in active booking if dispatched
    // Always update driver's live location in users collection
await FirebaseFirestore.instance
    .collection('users')
    .doc(uid)
    .update({
      'lastLatitude': position.latitude,
      'lastLongitude': position.longitude,
      'lastLocationAt': FieldValue.serverTimestamp(),
      'isOnline': true,
    });

// Update driver location in active booking if dispatched
    if (_activeBookingId != null) {
      await FirebaseFirestore.instance
          .collection('bookings')
          .doc(_activeBookingId)
          .update({
            'driverLatitude': position.latitude,
            'driverLongitude': position.longitude,
          });
    }

    if (_hasActiveEntry || _isCheckingLocation || !mounted) return;

    _isCheckingLocation = true;
    try {
      final point = LatLng(position.latitude, position.longitude);

      // Get driver's assigned terminal
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();
      final assignedTerminalId = userDoc.data()?['assignedTerminalId'];

      // No assigned terminal — skip
      if (assignedTerminalId == null) return;

      final terminalDoc = await _geofence.findTerminalAtPoint(point);

      if (terminalDoc == null) {
        // Driver left all terminals — reset
        if (_lastPromptedTerminalId != null) {
          setState(() => _lastPromptedTerminalId = null);
          if (mounted) {
            Navigator.of(
              context,
            ).popUntil((r) => r.isFirst || r is! PopupRoute);
          }
        }
        return;
      }

      // Only prompt for assigned terminal — ignore others
      if (terminalDoc.id != assignedTerminalId) return;

      if (terminalDoc.id != _lastPromptedTerminalId && mounted) {
        _lastPromptedTerminalId = terminalDoc.id;
        _showArrivalPrompt(terminalDoc);
      }
    } finally {
      _isCheckingLocation = false;
    }
  }

  void _showArrivalPrompt(
    QueryDocumentSnapshot<Map<String, dynamic>> terminalDoc,
  ) {
    final data = terminalDoc.data();
    final name = data['name'] ?? 'this terminal';

    showModalBottomSheet(
      context: context,
      isDismissible: true,
      builder: (_) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.location_on,
                  color: AppTheme.primaryGreen,
                  size: 28,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    "You've arrived at $name",
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Would you like to check in to the queue here?',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () {
                      Navigator.pop(context);
                      // Reset so prompt can show again if driver re-enters
                      setState(() => _lastPromptedTerminalId = null);
                    },
                    child: const Text('Not now'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () async {
                      Navigator.pop(context);
                      await _checkIn(terminalDoc.id, name);
                    },
                    child: const Text('Check In'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _checkIn(String terminalId, String terminalName) async {
    try {
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();
      final driverName = (userDoc.data()?['name'] ?? 'Driver').toString();
      final assignedTerminalId = userDoc.data()?['assignedTerminalId'];

      // Block check-in at wrong terminal
      if (assignedTerminalId != null && assignedTerminalId != terminalId) {
        final assignedTerminalName =
            userDoc.data()?['assignedTerminalName'] ?? 'your assigned terminal';
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('You can only check in at $assignedTerminalName.'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }

      await FirebaseFirestore.instance.collection('queueEntries').add({
        'driverId': uid,
        'driverName': driverName,
        'terminalId': terminalId,
        'terminalName': terminalName,
        'status': 'waiting',
        'checkedInAt': FieldValue.serverTimestamp(),
      });

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Checked in at $terminalName')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Check-in failed: $e')));
      }
    }
  }

  Future<void> _leaveQueue(String entryId) async {
    await FirebaseFirestore.instance
        .collection('queueEntries')
        .doc(entryId)
        .update({
          'status': 'cancelled',
          'cancelledAt': FieldValue.serverTimestamp(),
        });
    _lastPromptedTerminalId = null;
  }

  Future<void> _completeTrip(String entryId, String? bookingId) async {
    await DispatchService.instance.completeTrip(
      queueEntryId: entryId,
      bookingId: bookingId,
    );
    setState(() => _activeBookingId = null);
    _lastPromptedTerminalId = null;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Trip completed. You can check in again.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('TODA E-QUEUE+'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await FirebaseAuth.instance.signOut();
              if (context.mounted) {
                Navigator.pushReplacementNamed(context, AppRoutes.login);
              }
            },
          ),
        ],
      ),
      body: IndexedStack(
        index: _currentIndex,
        children: [
          _QueueTab(
            uid: uid,
            locationPermissionDenied: _locationPermissionDenied,
            hasActiveEntry: _hasActiveEntry,
            activeBookingId: _activeBookingId,
            onActiveEntryChanged: (isActive, bookingId) {
              if (isActive != _hasActiveEntry ||
                  bookingId != _activeBookingId) {
                setState(() {
                  _hasActiveEntry = isActive;
                  _activeBookingId = bookingId;
                });
              }
            },
            onLeaveQueue: _leaveQueue,
            onCompleteTrip: _completeTrip,
          ),
          _DriverMapTab(isActive: _currentIndex == 1),
          _DriverHistoryTab(uid: uid),
          _DriverProfileTab(uid: uid),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (i) => setState(() => _currentIndex = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.electric_rickshaw_outlined),
            selectedIcon: Icon(Icons.electric_rickshaw),
            label: 'Queue',
          ),
          NavigationDestination(
            icon: Icon(Icons.map_outlined),
            selectedIcon: Icon(Icons.map),
            label: 'Map',
          ),
          NavigationDestination(
            icon: Icon(Icons.history_outlined),
            selectedIcon: Icon(Icons.history),
            label: 'History',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outlined),
            selectedIcon: Icon(Icons.person),
            label: 'Profile',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'sos',
        onPressed: () => Navigator.pushNamed(context, AppRoutes.sos),
        backgroundColor: AppTheme.errorRed,
        icon: const Icon(Icons.sos, color: Colors.white),
        label: const Text('SOS', style: TextStyle(color: Colors.white)),
      ),
    );
  }
}

// ─── Queue Tab ───────────────────────────────────────────────────────────────

class _QueueTab extends StatelessWidget {
  final String uid;
  final bool locationPermissionDenied;
  final bool hasActiveEntry;
  final String? activeBookingId;
  final Function(bool, String?) onActiveEntryChanged;
  final Function(String) onLeaveQueue;
  final Function(String, String?) onCompleteTrip;

  const _QueueTab({
    required this.uid,
    required this.locationPermissionDenied,
    required this.hasActiveEntry,
    required this.activeBookingId,
    required this.onActiveEntryChanged,
    required this.onLeaveQueue,
    required this.onCompleteTrip,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DocumentSnapshot>(
      future: FirebaseFirestore.instance.collection('users').doc(uid).get(),
      builder: (context, userSnapshot) {
        final fullName = userSnapshot.data?['name'] ?? 'Driver';
        final firstName = fullName.toString().split(' ').first;

        return Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              color: AppTheme.primaryGreen,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Hello, $firstName! 🚖',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    locationPermissionDenied
                        ? 'Location is off — enable it to check in automatically.'
                        : "We'll let you know when you arrive at a terminal.",
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ],
              ),
            ),
            Expanded(
              child: StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection('queueEntries')
                    .where('driverId', isEqualTo: uid)
                    .where('status', whereIn: ['waiting', 'dispatched'])
                    .snapshots(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return Center(child: Text('Error: ${snapshot.error}'));
                  }

                  final entries = snapshot.data?.docs ?? [];
                  final activeEntry = entries.isNotEmpty ? entries.first : null;
                  final activeData =
                      activeEntry?.data() as Map<String, dynamic>?;
                  final isDispatched = activeData?['status'] == 'dispatched';
                  final bookingId = activeData?['bookingId'] as String?;

                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    onActiveEntryChanged(
                      activeEntry != null,
                      isDispatched ? bookingId : null,
                    );
                    // Show notification when dispatched
                    if (isDispatched && bookingId != null) {
                      NotificationService.instance.showDispatchNotification(
                        driverName: activeData?['driverName'] ?? 'Driver',
                        terminalName: activeData?['terminalName'] ?? 'Terminal',
                      );
                    }
                  });

                  if (activeEntry == null) {
                    return _NoQueueView(isWatching: !locationPermissionDenied);
                  }

                  return _ActiveQueueView(
                    entry: activeEntry,
                    onLeaveQueue: () => onLeaveQueue(activeEntry.id),
                    onCompleteTrip: () {
                      final data = activeEntry.data() as Map<String, dynamic>;
                      onCompleteTrip(
                        activeEntry.id,
                        data['bookingId'] as String?,
                      );
                    },
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class _NoQueueView extends StatelessWidget {
  final bool isWatching;
  const _NoQueueView({required this.isWatching});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isWatching ? Icons.my_location : Icons.location_off,
              size: 64,
              color: Colors.grey,
            ),
            const SizedBox(height: 16),
            Text(
              isWatching
                  ? "You're not in a queue yet.\nDrive to a terminal — we'll let you know when you arrive."
                  : 'Location is off.\nEnable it in Settings to auto check-in.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey, fontSize: 15),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActiveQueueView extends StatelessWidget {
  final QueryDocumentSnapshot entry;
  final VoidCallback onLeaveQueue;
  final VoidCallback onCompleteTrip;

  const _ActiveQueueView({
    required this.entry,
    required this.onLeaveQueue,
    required this.onCompleteTrip,
  });

  @override
  Widget build(BuildContext context) {
    final data = entry.data() as Map<String, dynamic>;
    final terminalId = data['terminalId'];
    final terminalName = data['terminalName'] ?? 'Terminal';
    final status = data['status'] ?? 'waiting';

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('queueEntries')
          .where('terminalId', isEqualTo: terminalId)
          .where('status', isEqualTo: 'waiting')
          .orderBy('checkedInAt')
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Queue error:\n${snapshot.error}',
              style: const TextStyle(color: Colors.red),
            ),
          );
        }

        final waitingDocs = snapshot.data?.docs ?? [];
        final position = waitingDocs.indexWhere((d) => d.id == entry.id) + 1;
        final total = waitingDocs.length;

        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Card(
                elevation: 2,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      Text(
                        terminalName,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (status == 'dispatched') ...[
                        const Icon(
                          Icons.electric_rickshaw,
                          color: AppTheme.primaryGreen,
                          size: 48,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          "You've been dispatched!",
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.primaryGreen,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Head to the passenger pickup point.',
                          style: TextStyle(color: Colors.grey),
                        ),
                      ] else ...[
                        Text(
                          position > 0 ? '#$position' : '—',
                          style: const TextStyle(
                            fontSize: 48,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.primaryGreen,
                          ),
                        ),
                        Text(
                          'of $total waiting',
                          style: const TextStyle(color: Colors.grey),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              if (status == 'waiting')
                OutlinedButton.icon(
                  onPressed: () => _confirmLeave(context),
                  icon: const Icon(Icons.exit_to_app, color: Colors.red),
                  label: const Text(
                    'Leave Queue',
                    style: TextStyle(color: Colors.red),
                  ),
                ),
              if (status == 'dispatched')
                ElevatedButton.icon(
                  onPressed: onCompleteTrip,
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('Complete Trip'),
                ),
            ],
          ),
        );
      },
    );
  }

  void _confirmLeave(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Leave the queue?'),
        content: const Text(
          "You'll lose your spot and need to check in again.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              onLeaveQueue();
            },
            child: const Text('Leave', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}

// ─── Driver Map Tab ───────────────────────────────────────────────────────────

class _DriverMapTab extends StatefulWidget {
  final bool isActive;
  const _DriverMapTab({required this.isActive});

  @override
  State<_DriverMapTab> createState() => _DriverMapTabState();
}

class _DriverMapTabState extends State<_DriverMapTab> {
  static const LatLng _baliwagCenter = LatLng(14.9540, 120.9010);

  final _geofence = GeofenceService.instance;
  final MapController _mapController = MapController();
  StreamSubscription<Position>? _positionSub;
  LatLng? _myPosition;
  double _zoom = 16;
  bool _locationUnavailable = false;
  String? _assignedTerminalName;

  @override
  void initState() {
    super.initState();
    _loadAssignedTerminal();
    _startWatchingSelf();
  }

  Future<void> _loadAssignedTerminal() async {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .get();
    if (mounted) {
      setState(() {
        _assignedTerminalName = doc.data()?['assignedTerminalName'];
      });
    }
  }

  @override
  void didUpdateWidget(covariant _DriverMapTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Snap to the driver's current position whenever they switch back to
    // this tab (IndexedStack keeps this widget alive in the background,
    // so this is the hook for "returning" to the tab).
    if (!oldWidget.isActive && widget.isActive) {
      _centerOnMe();
    }
  }

  void _centerOnMe() {
    final point = _myPosition;
    if (point == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _mapController.move(point, _zoom);
    });
  }

  Future<void> _startWatchingSelf() async {
    // Get an immediate fix so the marker appears right away, instead of
    // waiting for the first ~15m-movement update from the live stream.
    final current = await _geofence.getCurrentPosition();
    if (current != null && mounted) {
      _updateMyPosition(LatLng(current.latitude, current.longitude));
      if (widget.isActive) _centerOnMe();
    }

    final started = await _geofence.startTracking();
    if (!started) {
      if (mounted) setState(() => _locationUnavailable = true);
      return;
    }

    // Independent subscription to the shared broadcast stream — does not
    // interfere with the arrival-detection listener elsewhere.
    _positionSub = _geofence.positionStream.listen((pos) {
      if (!mounted) return;
      _updateMyPosition(LatLng(pos.latitude, pos.longitude));
    });
  }

  void _updateMyPosition(LatLng point) {
    setState(() => _myPosition = point);
  }

  @override
  void dispose() {
    // Only cancels this widget's own listener. The shared GPS stream
    // keeps running for other listeners (e.g. arrival detection) and is
    // stopped centrally by the parent screen's dispose().
    _positionSub?.cancel();
    super.dispose();
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
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance.collection('terminals').snapshots(),
      builder: (context, snapshot) {
        final terminals = snapshot.data?.docs ?? [];
        final markers = <Marker>[];
        final circles = <CircleMarker>[];

        for (final doc in terminals) {
          final data = doc.data() as Map<String, dynamic>;
          final boundary = data['boundary'] as List<dynamic>? ?? [];
          if (boundary.isEmpty) continue;

          final point = _parseBoundaryPoint(boundary[0]);
          if (point == null) continue;

          // Show assigned terminal circle, or all circles while loading
          final isAssigned =
              _assignedTerminalName == null ||
              data['name'] == _assignedTerminalName;
          if (isAssigned) {
            circles.add(
              CircleMarker(
                point: point,
                radius: 100,
                useRadiusInMeter: true,
                color: AppTheme.primaryGreen.withValues(alpha: 0.3),
                borderColor: AppTheme.primaryGreen,
                borderStrokeWidth: 2,
              ),
            );
          }

          // Terminal marker
          markers.add(
            Marker(
              point: point,
              width: 140,
              height: 60,
              child: GestureDetector(
                onTap: () {
                  showModalBottomSheet(
                    context: context,
                    builder: (_) => Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(
                                Icons.location_on,
                                color: AppTheme.primaryGreen,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                data['name'] ?? 'Terminal',
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
                                .where('terminalId', isEqualTo: doc.id)
                                .where('status', isEqualTo: 'waiting')
                                .snapshots(),
                            builder: (context, qSnap) {
                              final count = qSnap.data?.docs.length ?? 0;
                              return Text(
                                '$count driver(s) currently waiting',
                                style: const TextStyle(color: Colors.grey),
                              );
                            },
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Drive into the highlighted circle to check in automatically.',
                            style: TextStyle(color: Colors.grey, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  );
                },
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color:
                            _assignedTerminalName == null ||
                                data['name'] == _assignedTerminalName
                            ? AppTheme.primaryGreen
                            : Colors.grey,
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
                    Icon(
                      Icons.location_on,
                      color:
                          _assignedTerminalName == null ||
                              data['name'] == _assignedTerminalName
                          ? AppTheme.primaryGreen
                          : Colors.grey,
                      size: 24,
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        if (_myPosition != null) {
          markers.add(
            Marker(
              point: _myPosition!,
              width: 40,
              height: 40,
              child: const _SelfLocationDot(),
            ),
          );
        }

        return Stack(
          children: [
            FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: _baliwagCenter,
                initialZoom: 15,
                onMapEvent: (event) {
                  _zoom = event.camera.zoom;
                },
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.example.toda_equeue_plus',
                ),
                CircleLayer(circles: circles),
                MarkerLayer(markers: markers),
              ],
            ),
            if (_locationUnavailable)
              Positioned(
                top: 12,
                left: 12,
                right: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    'Location is off — enable it to see yourself on the map.',
                    style: TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ),
            Positioned(
              bottom: 16,
              right: 16,
              child: FloatingActionButton.small(
                heroTag: 'recenter',
                backgroundColor: AppTheme.primaryGreen,
                onPressed: _myPosition == null ? null : _centerOnMe,
                child: const Icon(Icons.my_location, color: Colors.white),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SelfLocationDot extends StatelessWidget {
  const _SelfLocationDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.blue.withValues(alpha: 0.25),
      ),
      child: Center(
        child: Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.blue,
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
          ),
        ),
      ),
    );
  }
}

// ─── Driver History Tab ───────────────────────────────────────────────────────

class _DriverHistoryTab extends StatelessWidget {
  final String uid;
  const _DriverHistoryTab({required this.uid});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('queueEntries')
          .where('driverId', isEqualTo: uid)
          .where('status', whereIn: ['completed', 'cancelled'])
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final entries = snapshot.data?.docs ?? [];
        if (entries.isEmpty) {
          return const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.history, size: 64, color: Colors.grey),
                SizedBox(height: 16),
                Text(
                  'No trips yet',
                  style: TextStyle(color: Colors.grey, fontSize: 16),
                ),
              ],
            ),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: entries.length,
          itemBuilder: (context, index) {
            final data = entries[index].data() as Map<String, dynamic>;
            final status = data['status'] ?? 'completed';
            return Card(
              margin: const EdgeInsets.only(bottom: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: status == 'completed'
                      ? Colors.green
                      : Colors.grey,
                  child: Icon(
                    status == 'completed' ? Icons.check : Icons.cancel_outlined,
                    color: Colors.white,
                  ),
                ),
                title: Text(data['terminalName'] ?? 'Terminal'),
                subtitle: Text(
                  status == 'completed' ? 'Trip completed' : 'Cancelled',
                ),
                onTap: data['bookingId'] != null
                    ? () => Navigator.pushNamed(
                        context,
                        AppRoutes.tripDetail,
                        arguments: {
                          'bookingId': data['bookingId'],
                          'userRole': 'driver',
                        },
                      )
                    : null,
                trailing: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: status == 'completed'
                        ? Colors.green.withValues(alpha: 0.1)
                        : Colors.grey.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    status,
                    style: TextStyle(
                      color: status == 'completed' ? Colors.green : Colors.grey,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

// ─── Driver Profile Tab ───────────────────────────────────────────────────────

class _DriverProfileTab extends StatelessWidget {
  final String uid;
  const _DriverProfileTab({required this.uid});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DocumentSnapshot>(
      future: FirebaseFirestore.instance.collection('users').doc(uid).get(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final data = snapshot.data!.data() as Map<String, dynamic>?;
        final isVerified = data?['isVerified'] ?? false;

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const SizedBox(height: 24),
            Center(
              child: Stack(
                children: [
                  CircleAvatar(
                    radius: 48,
                    backgroundColor: AppTheme.primaryBlue,
                    child: Text(
                      (data?['name'] ?? 'D').toString().substring(0, 1),
                      style: const TextStyle(
                        fontSize: 36,
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  if (isVerified)
                    Positioned(
                      bottom: 0,
                      right: 0,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: const BoxDecoration(
                          color: Colors.green,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.verified,
                          color: Colors.white,
                          size: 16,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Center(
              child: Text(
                data?['name'] ?? 'Driver',
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 4),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: isVerified
                      ? Colors.green.withValues(alpha: 0.1)
                      : Colors.orange.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  isVerified ? '✅ Verified Driver' : '⏳ Pending Verification',
                  style: TextStyle(
                    color: isVerified ? Colors.green : Colors.orange,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            // Average rating
            if ((data?['averageRating'] ?? 0) > 0)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.star, color: Colors.amber, size: 20),
                  const SizedBox(width: 4),
                  Text(
                    '${data?['averageRating']} (${data?['totalRatings']} ratings)',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 32),
            Card(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: const Icon(Icons.person_outlined),
                    title: const Text('Full Name'),
                    subtitle: Text(data?['name'] ?? ''),
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  ListTile(
                    leading: const Icon(Icons.email_outlined),
                    title: const Text('Email'),
                    subtitle: Text(data?['email'] ?? ''),
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  ListTile(
                    leading: const Icon(Icons.phone_outlined),
                    title: const Text('Phone'),
                    subtitle: Text(data?['phone'] ?? ''),
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  ListTile(
                    leading: const Icon(Icons.electric_rickshaw_outlined),
                    title: const Text('Plate Number'),
                    subtitle: Text(data?['plateNumber'] ?? 'N/A'),
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  ListTile(
                    leading: const Icon(Icons.numbers_outlined),
                    title: const Text('Body Number'),
                    subtitle: Text(data?['bodyNumber'] ?? 'N/A'),
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  ListTile(
                    leading: const Icon(Icons.badge_outlined),
                    title: const Text('ID Type'),
                    subtitle: Text(data?['idType'] ?? 'N/A'),
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  ListTile(
                    leading: const Icon(Icons.numbers_outlined),
                    title: const Text('ID Number'),
                    subtitle: Text(data?['idNumber'] ?? 'N/A'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: () async {
                await FirebaseAuth.instance.signOut();
                if (context.mounted) {
                  Navigator.pushReplacementNamed(context, AppRoutes.login);
                }
              },
              icon: const Icon(Icons.logout, color: Colors.red),
              label: const Text(
                'Sign Out',
                style: TextStyle(color: Colors.red),
              ),
            ),
            const SizedBox(height: 80),
          ],
        );
      },
    );
  }
}

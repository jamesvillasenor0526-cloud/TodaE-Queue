import 'package:flutter/material.dart';
import '../../../core/models/trip_state.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:latlong2/latlong.dart';
import '../../../config/routes.dart';
import '../../../config/theme.dart';
import '../../../core/services/contact_service.dart';
import '../../shared/profile/my_contact.dart';
import '../../../core/services/dispatch_service.dart';
import '../../../core/services/fare_service.dart';
import '../../shared/user_profile_screen.dart';
import 'pickup_location_screen.dart';
import 'destination_picker_screen.dart';
import '../../../widgets/shimmer_loading.dart';
import '../../../widgets/state_views.dart';
import 'dart:io';
import 'package:image_picker/image_picker.dart';
import '../../../core/services/cloudinary_service.dart';
import '../../../core/services/geocoding_service.dart';
import 'package:geolocator/geolocator.dart';
import '../../../config/theme_controller.dart';
import '../../../core/services/routing_service.dart';
import '../../shared/reports/my_reports_screen.dart';
import '../../shared/sos/sos_button.dart';

class PassengerHomeScreen extends StatefulWidget {
  const PassengerHomeScreen({super.key});

  @override
  State<PassengerHomeScreen> createState() => _PassengerHomeScreenState();
}

class _PassengerHomeScreenState extends State<PassengerHomeScreen> {
  final uid = FirebaseAuth.instance.currentUser!.uid;
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('TODA E-QUEUE+'),
        actions: [
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Sign Out'),
                  content: const Text('Are you sure you want to sign out?'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text(
                        'Sign Out',
                        style: TextStyle(color: AppTheme.errorRed),
                      ),
                    ),
                  ],
                ),
              );
              if (confirm == true && context.mounted) {
                await FirebaseAuth.instance.signOut();
                if (!context.mounted) return;
                Navigator.pushReplacementNamed(context, AppRoutes.login);
              }
            },
          ),
        ],
      ),
      body: IndexedStack(
        index: _currentIndex,
        children: const [_HomeTab(), _HistoryTab(), _ProfileTab()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (i) => setState(() => _currentIndex = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
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
      floatingActionButton: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FloatingActionButton(
            heroTag: 'map',
            // The map picks a terminal; booking from it is the same flow
            // as from the list.
            onPressed: () async {
              // Untyped on purpose: the route table builds
              // MaterialPageRoute<dynamic>, and asking for a typed result
              // made pushNamed throw before the map ever opened.
              final picked = await Navigator.pushNamed(
                context,
                AppRoutes.terminalMap,
              );
              if (picked is! Map || !context.mounted) return;
              final id = picked['terminalId'], name = picked['terminalName'];
              if (id is! String || name is! String) return;
              await _bookFromTerminal(context, id, name);
            },
            backgroundColor: AppTheme.primaryBlue,
            child: const Icon(Icons.map, color: Colors.white),
          ),
          const SizedBox(height: 12),
          const SosButton(),
        ],
      ),
    );
  }
}

// ─── Home Tab ───────────────────────────────────────────────────────────────

class _HomeTab extends StatefulWidget {
  const _HomeTab();
  @override
  State<_HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<_HomeTab> {
  final uid = FirebaseAuth.instance.currentUser!.uid;
  LatLng? _userLocation;
  Map<String, double> _terminalDistances = {};
  bool _isCalculatingDistances = false;

  @override
  void initState() {
    super.initState();
    _loadUserLocation();
  }

  Future<void> _loadUserLocation() async {
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
    } catch (e) {
      debugPrint('Location error: $e');
    }
  }

  Future<void> _calculateDistances(
    List<QueryDocumentSnapshot> terminals,
  ) async {
    if (_userLocation == null || _isCalculatingDistances) return;
    _isCalculatingDistances = true;

    final distances = <String, double>{};
    for (final doc in terminals) {
      final data = doc.data() as Map<String, dynamic>;
      final boundary = data['boundary'] as List<dynamic>? ?? [];
      if (boundary.isEmpty) continue;

      final point = _parseBoundaryPoint(boundary[0]);
      if (point == null) continue;

      final distance = await RoutingService.instance.getRouteDistance(
        _userLocation!,
        point,
      );
      distances[doc.id] = distance;
    }

    if (mounted && distances.isNotEmpty) {
      setState(() {
        _terminalDistances = distances;
        _isCalculatingDistances = false;
      });
      debugPrint('🔍 Distances calculated: ${distances.length}');
      distances.forEach((id, dist) {
        debugPrint('🔍 $id: $dist km');
      });
    }
  }

  void _showDriverProfile(BuildContext context, String driverId) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            UserProfileScreen(uid: driverId, viewerRole: 'passenger'),
      ),
    );
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
    return FutureBuilder<DocumentSnapshot>(
      future: FirebaseFirestore.instance.collection('users').doc(uid).get(),
      builder: (context, snapshot) {
        final fullName = snapshot.data?['name'] ?? 'Passenger';
        final firstName = fullName.toString().split(' ').first;
        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection('bookings')
                    .where('passengerId', isEqualTo: uid)
                    .where(
                      'status',
                      whereIn: ['assigned', 'accepted', 'completed'],
                    )
                    .snapshots(),
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return const SizedBox.shrink(); // ← ADD
                  }
                  final docs = snapshot.data?.docs ?? [];
                  // A completed-and-paid trip has nothing left to act on.
                  // Read the trip state machine, not the legacy fields. The
                  // legacy `status` folds five states into 'accepted' and
                  // can lag the authoritative tripStatus, which is how the
                  // banner ends up disagreeing with the trip screen.
                  final active = docs.where((doc) {
                    final t = TripState.fromMap(
                      doc.id,
                      doc.data() as Map<String, dynamic>,
                    );
                    return !(t.trip == TripStatus.tripCompleted &&
                        t.payment == PaymentState.paymentConfirmed);
                  }).toList();
                  if (active.isEmpty) return const SizedBox.shrink();
                  final data = active.first.data() as Map<String, dynamic>;
                  final awaitingPayment =
                      TripState.fromMap(active.first.id, data).trip ==
                      TripStatus.tripCompleted;
                  return GestureDetector(
                    onTap: () => Navigator.pushNamed(
                      context,
                      AppRoutes.tripTracking,
                      arguments: {
                        'bookingId': active.first.id,
                        'driverName': data['driverName'] ?? 'Driver',
                        'terminalName': data['terminalName'] ?? 'Terminal',
                      },
                    ),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      color: AppTheme.primaryBlue,
                      child: Row(
                        children: [
                          Icon(
                            awaitingPayment
                                ? Icons.payments
                                : Icons.electric_rickshaw,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  awaitingPayment
                                      ? 'Payment due for your last trip'
                                      : 'You have an active trip!',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                Text(
                                  awaitingPayment
                                      ? 'Driver: ${data['driverName'] ?? 'Unknown'} • Tap to pay'
                                      : 'Driver: ${data['driverName'] ?? 'Unknown'} • Tap to track',
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const Icon(Icons.chevron_right, color: Colors.white),
                        ],
                      ),
                    ),
                  );
                },
              ),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                color: AppTheme.primaryGreen,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Hello, $firstName! 👋',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Where are you going today?',
                      style: TextStyle(color: Colors.white70, fontSize: 14),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: () => _showTerminalList(context),
                        icon: const Icon(Icons.electric_rickshaw),
                        label: const Text(
                          'Book a Ride',
                          style: TextStyle(fontSize: 13),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.primaryGreen,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            vertical: 14,
                            horizontal: 8,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () =>
                            Navigator.pushNamed(context, AppRoutes.fareMatrix),
                        icon: const Icon(Icons.monetization_on, size: 18),
                        label: const Text(
                          'Fare Matrix',
                          style: TextStyle(fontSize: 13),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppTheme.primaryGreen,
                          side: const BorderSide(color: AppTheme.primaryGreen),
                          padding: const EdgeInsets.symmetric(
                            vertical: 14,
                            horizontal: 8,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'Available Terminals',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(height: 8),
              StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection('terminals')
                    .snapshots(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return Column(
                      children: List.generate(
                        3,
                        (index) => const ShimmerCard(),
                      ),
                    );
                  }
                  if (snapshot.hasError) {
                    return ErrorView(
                      message:
                          'We couldn\'t load the terminal list. Check your '
                          'connection and try again.',
                      onRetry: () => setState(() {}),
                    );
                  }
                  final terminals = snapshot.data?.docs ?? [];
                  if (terminals.isEmpty) {
                    return const EmptyView(
                      icon: Icons.location_off_outlined,
                      title: 'No terminals yet',
                      message:
                          'No TODA terminals have been set up. Please check '
                          'back later or contact your TODA admin.',
                    );
                  }

                  if (_terminalDistances.isEmpty && !_isCalculatingDistances) {
                    debugPrint(
                      '🔍 Calculating distances for ${terminals.length} terminals',
                    );
                    _calculateDistances(terminals);
                  }

                  // Sort terminals by distance
                  final sortedTerminals = List<QueryDocumentSnapshot>.from(
                    terminals,
                  );
                  if (_terminalDistances.isNotEmpty) {
                    sortedTerminals.sort((a, b) {
                      final aDist = _terminalDistances[a.id] ?? double.infinity;
                      final bDist = _terminalDistances[b.id] ?? double.infinity;
                      return aDist.compareTo(bDist);
                    });
                  }

                  return ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: sortedTerminals.length,
                    itemBuilder: (context, index) {
                      final doc = sortedTerminals[index];
                      final data = doc.data() as Map<String, dynamic>;
                      final distance = _terminalDistances[doc.id];

                      return Card(
                        margin: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 6,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: ListTile(
                          leading: const CircleAvatar(
                            backgroundColor: AppTheme.primaryGreen,
                            child: Icon(Icons.location_on, color: Colors.white),
                          ),
                          title: Text(
                            data['name'] ?? 'Terminal',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (distance != null)
                                Text(
                                  distance < 1.0
                                      ? '📍 ${(distance * 1000).toStringAsFixed(0)} m away'
                                      : '📍 ${distance.toStringAsFixed(2)} km away',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: AppTheme.info,
                                  ),
                                ),
                              StreamBuilder<QuerySnapshot>(
                                stream: FirebaseFirestore.instance
                                    .collection('queueEntries')
                                    .where('terminalId', isEqualTo: doc.id)
                                    .where('status', isEqualTo: 'waiting')
                                    .orderBy('checkedInAt')
                                    .snapshots(),
                                builder: (context, qSnapshot) {
                                  final waitingDocs =
                                      qSnapshot.data?.docs ?? [];
                                  final count = waitingDocs.length;
                                  if (count == 0) {
                                    return const Text('No drivers in queue');
                                  }
                                  final firstDriver =
                                      waitingDocs.first.data()
                                          as Map<String, dynamic>;
                                  final firstDriverId =
                                      firstDriver['driverId'] ?? '';
                                  final firstDriverName =
                                      firstDriver['driverName'] ?? 'Unknown';
                                  return Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text('$count driver(s) waiting'),
                                      const SizedBox(height: 4),
                                      GestureDetector(
                                        onTap: () => _showDriverProfile(
                                          context,
                                          firstDriverId,
                                        ),
                                        child: FutureBuilder<DocumentSnapshot>(
                                          future: FirebaseFirestore.instance
                                              .collection('users')
                                              .doc(firstDriverId)
                                              .get(),
                                          builder: (context, userSnap) {
                                            if (!userSnap.hasData ||
                                                userSnap.data == null) {
                                              return const SizedBox.shrink();
                                            }

                                            final userData =
                                                userSnap.data!.data()
                                                    as Map<String, dynamic>?;
                                            final rating =
                                                userData?['averageRating'] ??
                                                0.0;

                                            return Row(
                                              children: [
                                                const Icon(
                                                  Icons.electric_rickshaw,
                                                  size: 14,
                                                  color: AppTheme.primaryGreen,
                                                ),
                                                const SizedBox(width: 4),
                                                Text(
                                                  '#1: $firstDriverName',
                                                  style: const TextStyle(
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w500,
                                                  ),
                                                ),
                                                if (rating > 0) ...[
                                                  const SizedBox(width: 6),
                                                  const Icon(
                                                    Icons.star,
                                                    size: 12,
                                                    color: Colors.amber,
                                                  ),
                                                  const SizedBox(width: 2),
                                                  Text(
                                                    '$rating',
                                                    style: const TextStyle(
                                                      fontSize: 11,
                                                      color: Colors.amber,
                                                      fontWeight:
                                                          FontWeight.bold,
                                                    ),
                                                  ),
                                                ],
                                              ],
                                            );
                                          },
                                        ),
                                      ),
                                    ],
                                  );
                                },
                              ),
                            ],
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _bookFromTerminal(
                            context,
                            doc.id,
                            data['name'] ?? 'Terminal',
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
              const SizedBox(height: 100),
            ],
          ),
        );
      },
    );
  }

  void _showTerminalList(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => DraggableScrollableSheet(
        initialChildSize: 0.5,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        expand: false,
        builder: (_, controller) => Column(
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Select a Terminal',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection('terminals')
                    .snapshots(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return Column(
                      children: List.generate(
                        3,
                        (index) => const ShimmerCard(),
                      ),
                    );
                  }
                  if (snapshot.hasError) {
                    return const Center(
                      child: Text(
                        'Could not load terminals',
                        style: TextStyle(color: AppTheme.textMuted),
                      ),
                    );
                  }
                  final terminals = snapshot.data?.docs ?? [];
                  if (terminals.isEmpty) {
                    return const Center(
                      child: Text(
                        'No terminals available',
                        style: TextStyle(color: AppTheme.textMuted),
                      ),
                    );
                  }
                  return ListView.builder(
                    controller: controller,
                    itemCount: terminals.length,
                    itemBuilder: (context, index) {
                      final doc = terminals[index];
                      final data = doc.data() as Map<String, dynamic>;
                      return ListTile(
                        leading: const CircleAvatar(
                          backgroundColor: AppTheme.primaryGreen,
                          child: Icon(
                            Icons.location_on,
                            color: Colors.white,
                            size: 18,
                          ),
                        ),
                        title: Text(
                          data['name'] ?? 'Terminal',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: StreamBuilder<QuerySnapshot>(
                          stream: FirebaseFirestore.instance
                              .collection('queueEntries')
                              .where('terminalId', isEqualTo: doc.id)
                              .where('status', isEqualTo: 'waiting')
                              .snapshots(),
                          builder: (context, qSnapshot) {
                            final count = qSnapshot.data?.docs.length ?? 0;
                            return Text(
                              '$count driver(s) waiting',
                              style: const TextStyle(
                                fontSize: 12,
                                color: AppTheme.textMuted,
                              ),
                            );
                          },
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          final terminalId = doc.id;
                          final terminalName = data['name'] ?? 'Terminal';

                          // Close the bottom sheet
                          Navigator.pop(sheetContext);

                          // Use small delay to ensure sheet is closed
                          Future.delayed(const Duration(milliseconds: 100), () {
                            if (!context.mounted) return;
                            _bookFromTerminal(
                              context,
                              terminalId,
                              terminalName,
                            );
                          });
                        },
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The whole booking, from a chosen terminal: pick-up point, destination,
/// fare, then dispatch.
///
/// Shared by the terminal list and the terminal map, so both book the same
/// way. The map used to dispatch a driver straight from its pin, which made
/// a booking with no pick-up, no destination and no fare — the driver was
/// sent with nowhere to go, and the service-area check never ran.
Future<void> _bookFromTerminal(
  BuildContext context,
  String terminalId,
  String terminalName,
) async {
  // Capture the navigator BEFORE any async operations
  final navigator = Navigator.of(context);

  final pickupData = await navigator.push<Map<String, dynamic>>(
    MaterialPageRoute(
      builder: (_) => PickupLocationScreen(
        terminalId: terminalId,
        terminalName: terminalName,
      ),
    ),
  );

  if (pickupData == null) return;
  final pickupLat = pickupData['latitude'] as double;
  final pickupLng = pickupData['longitude'] as double;

  final bookingData = await navigator.push<Map<String, dynamic>>(
    MaterialPageRoute(
      builder: (_) => DestinationPickerScreen(
        pickupLat: pickupLat,
        pickupLng: pickupLng,
        terminalId: terminalId,
        terminalName: terminalName,
      ),
    ),
  );

  if (bookingData == null) return;
  final destinationLat = bookingData['destinationLat'] as double;
  final destinationLng = bookingData['destinationLng'] as double;
  final distance = bookingData['distance'] as double;
  final fare = bookingData['fare'] as double;

  final result = await navigator.push<DispatchResult>(
    MaterialPageRoute(
      builder: (_) => _TerminalSheetScreen(
        terminalName: terminalName,
        terminalId: terminalId,
        pickupLat: pickupLat,
        pickupLng: pickupLng,
        destinationLat: destinationLat,
        destinationLng: destinationLng,
        distance: distance,
        fare: fare,
        outsideServiceArea: bookingData['outsideServiceArea'] == true,
        outOfTownFee: (bookingData['outOfTownFee'] as num?)?.toDouble() ?? 0,
        outOfTownKm: (bookingData['outOfTownKm'] as num?)?.toDouble() ?? 0,
      ),
    ),
  );

  if (result == null || !context.mounted) return;

  if (result.success) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Wait for the Driver! 🚖'),
        // No payment here. Paying — cash or the driver's GCash QR — is
        // done from the trip screen once the driver has arrived; showing
        // the QR at booking asked the passenger to pay for a ride that had
        // not started and might yet be cancelled.
        content: Text(
          '${result.driverName} has been dispatched.\n\nFare: ${FareService.instance.formatFare(fare)}',
          textAlign: TextAlign.center,
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              Navigator.pushNamed(
                context,
                AppRoutes.tripTracking,
                arguments: {
                  'bookingId': result.bookingId ?? '',
                  'driverName': result.driverName ?? 'Driver',
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
      SnackBar(content: Text(result.message ?? 'Could not book a ride.')),
    );
  }
}

// ─── Terminal Sheet ──────────────────────────────────────────────────────────

class _TerminalSheet extends StatefulWidget {
  final String name;
  final String terminalId;
  final double pickupLat;
  final double pickupLng;
  final double destinationLat;
  final double destinationLng;
  final double distance;
  final double fare;

  const _TerminalSheet({
    required this.name,
    required this.terminalId,
    required this.pickupLat,
    required this.pickupLng,
    required this.destinationLat,
    required this.destinationLng,
    required this.distance,
    required this.fare,
  });

  @override
  State<_TerminalSheet> createState() => _TerminalSheetState();
}

class _TerminalSheetState extends State<_TerminalSheet> {
  bool _isBooking = false;
  String _pickupName = 'Loading...';
  String _destinationName = 'Loading...';

  @override
  void initState() {
    super.initState();
    _getPlaceNames();
  }

  Future<void> _getPlaceNames() async {
    debugPrint('🟢 Getting place names...');
    _pickupName = await GeocodingService.instance.getPlaceName(
      widget.pickupLat,
      widget.pickupLng,
    );
    debugPrint('🟢 Pickup name: $_pickupName');

    _destinationName = await GeocodingService.instance.getPlaceName(
      widget.destinationLat,
      widget.destinationLng,
    );
    debugPrint('🟢 Destination name: $_destinationName');

    if (mounted) setState(() {});
  }

  Future<void> _bookRide() async {
    setState(() => _isBooking = true);
    final passengerId = FirebaseAuth.instance.currentUser!.uid;
    final result = await DispatchService.instance.dispatchNextDriver(
      terminalId: widget.terminalId,
      passengerId: passengerId,
      pickupLatitude: widget.pickupLat,
      pickupLongitude: widget.pickupLng,
      destinationLatitude: widget.destinationLat,
      destinationLongitude: widget.destinationLng,
      distance: widget.distance,
      fare: widget.fare,
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
          const SizedBox(height: 12),
          _infoRow(Icons.trip_origin, 'Pickup', _pickupName),
          const SizedBox(height: 8),
          _infoRow(Icons.flag, 'Destination', _destinationName),
          const SizedBox(height: 8),
          _infoRow(
            Icons.straighten,
            'Distance',
            '${widget.distance.toStringAsFixed(2)} km',
          ),
          const Divider(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                '💰 Total Fare',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              Text(
                FareService.instance.formatFare(widget.fare),
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.primaryGreen,
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
                count > 0
                    ? '$count driver(s) in queue'
                    : 'No drivers available right now',
                style: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
              );
            },
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () {
                debugPrint('🟢 Book button tapped!'); // ADD THIS
                if (!_isBooking) _bookRide();
              },
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
              label: Text(
                _isBooking ? 'Booking...' : 'Book from this terminal',
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
    );
  }

  Widget _infoRow(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, size: 14, color: AppTheme.textMuted),
        const SizedBox(width: 6),
        Text(
          '$label: ',
          style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
        ),
        Expanded(child: Text(value, style: const TextStyle(fontSize: 12))),
      ],
    );
  }
}

// ─── Terminal Sheet Screen (Full Page) ───────────────────────────────────────

class _TerminalSheetScreen extends StatefulWidget {
  final String terminalName;
  final String terminalId;
  final double pickupLat;
  final double pickupLng;
  final double destinationLat;
  final double destinationLng;
  final double distance;
  final double fare;

  /// Set when where they are going lies outside Baliwag far enough from the
  /// terminal to be charged for the driver's return.
  final double outOfTownFee;
  final double outOfTownKm;
  final bool outsideServiceArea;

  const _TerminalSheetScreen({
    required this.terminalName,
    required this.terminalId,
    required this.pickupLat,
    required this.pickupLng,
    required this.destinationLat,
    required this.destinationLng,
    required this.distance,
    required this.fare,
    this.outOfTownFee = 0,
    this.outOfTownKm = 0,
    this.outsideServiceArea = false,
  });

  @override
  State<_TerminalSheetScreen> createState() => _TerminalSheetScreenState();
}

class _TerminalSheetScreenState extends State<_TerminalSheetScreen> {
  bool _isBooking = false;
  String _pickupName = 'Loading...';
  String _destinationName = 'Loading...';

  @override
  void initState() {
    super.initState();
    _getPlaceNames();
  }

  Future<void> _getPlaceNames() async {
    _pickupName = await GeocodingService.instance.getPlaceName(
      widget.pickupLat,
      widget.pickupLng,
    );
    _destinationName = await GeocodingService.instance.getPlaceName(
      widget.destinationLat,
      widget.destinationLng,
    );
    if (mounted) setState(() {});
  }

  Future<void> _bookRide() async {
    if (_isBooking) return;
    setState(() => _isBooking = true);
    final passengerId = FirebaseAuth.instance.currentUser!.uid;
    final result = await DispatchService.instance.dispatchNextDriver(
      terminalId: widget.terminalId,
      passengerId: passengerId,
      pickupLatitude: widget.pickupLat,
      pickupLongitude: widget.pickupLng,
      destinationLatitude: widget.destinationLat,
      destinationLongitude: widget.destinationLng,
      distance: widget.distance,
      fare: widget.fare,
      outsideServiceArea: widget.outsideServiceArea,
      outOfTownFee: widget.outOfTownFee,
      outOfTownKm: widget.outOfTownKm,
    );
    if (!mounted) return;
    Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Confirm Booking'),
        leading: IconButton(
          tooltip: 'Back',
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context, null),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Terminal header
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
                    widget.terminalName,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // Trip details card
            Card(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    _infoRow(Icons.trip_origin, 'Pickup', _pickupName),
                    const SizedBox(height: 12),
                    _infoRow(Icons.flag, 'Destination', _destinationName),
                    const SizedBox(height: 12),
                    _infoRow(
                      Icons.straighten,
                      'Distance',
                      '${widget.distance.toStringAsFixed(1)} km',
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),

            // Fare card
            Card(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              color: AppTheme.primaryGreen.withValues(alpha: 0.05),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          '💰 Total Fare',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          FareService.instance.formatFare(widget.fare),
                          style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.primaryGreen,
                          ),
                        ),
                      ],
                    ),
                    // Out-of-town trips cost more and can be turned down, so
                    // say both before they book.
                    if (widget.outOfTownFee > 0) ...[
                      const SizedBox(height: 10),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Text(
                              'Includes ₱${widget.outOfTownFee.toStringAsFixed(0)} '
                              'for ${widget.outOfTownKm.toStringAsFixed(1)} km '
                              'outside Baliwag',
                              style: const TextStyle(
                                fontSize: 12,
                                color: AppTheme.textMuted,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'The driver has to accept this trip before they come '
                        'for you.',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppTheme.textMuted,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),

            // Driver availability
            StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('queueEntries')
                  .where('terminalId', isEqualTo: widget.terminalId)
                  .where('status', isEqualTo: 'waiting')
                  .snapshots(),
              builder: (context, snapshot) {
                final count = snapshot.data?.docs.length ?? 0;
                return Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: count > 0
                        ? Colors.green.withValues(alpha: 0.1)
                        : Colors.orange.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        count > 0 ? Icons.check_circle : Icons.warning,
                        color: count > 0 ? AppTheme.success : AppTheme.warning,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        count > 0
                            ? '$count driver(s) available'
                            : 'No drivers available right now',
                        style: TextStyle(
                          color: count > 0
                              ? AppTheme.success
                              : AppTheme.warning,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 32),

            // Book button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
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
                label: Text(
                  _isBooking ? 'Booking...' : 'Book from this terminal',
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryGreen,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, size: 16, color: AppTheme.textMuted),
        const SizedBox(width: 8),
        Text(
          '$label: ',
          style: const TextStyle(fontSize: 13, color: AppTheme.textMuted),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          ),
        ),
      ],
    );
  }
}

// ─── History Tab ─────────────────────────────────────────────────────────────

class _HistoryTab extends StatefulWidget {
  const _HistoryTab();

  @override
  State<_HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<_HistoryTab> {
  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('bookings')
          .where('passengerId', isEqualTo: uid)
          .orderBy('createdAt', descending: true)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Column(
            children: List.generate(3, (index) => const ShimmerCard()),
          );
        }
        if (snapshot.hasError) {
          return ErrorView(
            message:
                'We couldn\'t load your trip history. Check your connection '
                'and try again.',
            onRetry: () => setState(() {}),
          );
        }
        final bookings = snapshot.data?.docs ?? [];
        if (bookings.isEmpty) {
          return const EmptyView(
            icon: Icons.history,
            title: 'No trips yet',
            message:
                'Once you book a ride, your completed trips and receipts '
                'will appear here.',
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: bookings.length,
          itemBuilder: (context, index) {
            final data = bookings[index].data() as Map<String, dynamic>;
            final status = TripState.fromMap(
              bookings[index].id,
              data,
            ).trip.passengerLabel;
            return Card(
              margin: const EdgeInsets.only(bottom: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: status == 'completed'
                      ? AppTheme.success
                      : AppTheme.primaryBlue,
                  child: Icon(
                    status == 'completed'
                        ? Icons.check
                        : Icons.electric_rickshaw,
                    color: Colors.white,
                  ),
                ),
                title: Text(data['terminalName'] ?? 'Terminal'),
                subtitle: Text('Driver: ${data['driverName'] ?? 'Unknown'}'),
                trailing: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: status == 'completed'
                        ? Colors.green.withValues(alpha: 0.1)
                        : AppTheme.primaryBlue.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    status,
                    style: TextStyle(
                      color: status == 'completed'
                          ? AppTheme.success
                          : AppTheme.primaryBlue,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
                onTap: () => Navigator.pushNamed(
                  context,
                  AppRoutes.tripDetail,
                  arguments: {
                    'bookingId': bookings[index].id,
                    'userRole': 'passenger',
                  },
                ),
              ),
            );
          },
        );
      },
    );
  }
}

// ─── Profile Tab ─────────────────────────────────────────────────────────────

class _ProfileTab extends StatefulWidget {
  const _ProfileTab();

  @override
  State<_ProfileTab> createState() => _ProfileTabState();
}

class _ProfileTabState extends State<_ProfileTab> {
  bool _darkMode = false;
  final uid = FirebaseAuth.instance.currentUser!.uid;

  Future<void> _uploadProfilePicture(BuildContext context) async {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    final picker = ImagePicker();

    // Show source selection dialog
    final source = await showDialog<ImageSource>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Change Profile Photo'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(
                Icons.camera_alt,
                color: AppTheme.primaryGreen,
              ),
              title: const Text('Take Photo'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(
                Icons.photo_library,
                color: AppTheme.primaryBlue,
              ),
              title: const Text('Choose from Gallery'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: AppTheme.errorRed),
              title: const Text('Remove Photo'),
              onTap: () async {
                await FirebaseFirestore.instance
                    .collection('users')
                    .doc(uid)
                    .update({'profilePhotoUrl': FieldValue.delete()});
                if (ctx.mounted) Navigator.pop(ctx);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('✅ Photo removed!')),
                  );
                }
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );

    if (source == null) return;

    final pickedFile = await picker.pickImage(
      source: source,
      maxWidth: 800,
      maxHeight: 800,
      imageQuality: 80,
    );

    if (pickedFile == null) return;

    final file = File(pickedFile.path);
    final url = await CloudinaryService.instance.uploadImage(
      file,
      'profile_photos/$uid',
    );

    if (url != null) {
      await FirebaseFirestore.instance.collection('users').doc(uid).update({
        'profilePhotoUrl': url,
      });
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('✅ Profile photo updated!')),
        );
      }
    }
  }

  void _showEditNameDialog(BuildContext context) {
    final nameController = TextEditingController();
    final uid = FirebaseAuth.instance.currentUser!.uid;

    // Pre-fill existing name
    FirebaseFirestore.instance.collection('users').doc(uid).get().then((doc) {
      nameController.text = doc.data()?['name'] ?? '';
    });

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Name'),
        content: TextField(
          controller: nameController,
          decoration: const InputDecoration(
            labelText: 'Full Name',
            prefixIcon: Icon(Icons.person_outlined),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              if (nameController.text.trim().isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Name cannot be empty')),
                );
                return;
              }
              await FirebaseFirestore.instance
                  .collection('users')
                  .doc(uid)
                  .update({'name': nameController.text.trim()});
              if (ctx.mounted) Navigator.pop(ctx);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('✅ Name updated!')),
                );
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryGreen,
            ),
            child: const Text('Save', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _showEditPhoneDialog(BuildContext context) {
    final phoneController = TextEditingController();
    final uid = FirebaseAuth.instance.currentUser!.uid;

    // Pre-fill existing phone
    ContactService.instance.mine().then((contact) {
      phoneController.text = contact.phone ?? '';
    });

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Phone Number'),
        content: TextField(
          controller: phoneController,
          keyboardType: TextInputType.phone,
          maxLength: 11,
          decoration: const InputDecoration(
            labelText: 'Phone Number',
            prefixIcon: Icon(Icons.phone_outlined),
            counterText: '',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final phone = phoneController.text.trim();
              if (phone.isEmpty || phone.length != 11) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Phone must be 11 digits')),
                );
                return;
              }
              if (!RegExp(r'^[0-9]+$').hasMatch(phone)) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Phone must be numbers only')),
                );
                return;
              }
              // Into the private record, not the user document every
              // signed-in account can read.
              await ContactService.instance.save(uid, Contact(phone: phone));
              if (ctx.mounted) Navigator.pop(ctx);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('✅ Phone updated!')),
                );
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryGreen,
            ),
            child: const Text('Save', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _showEditLocationDialog(BuildContext context) {
    final locationController = TextEditingController();
    final uid = FirebaseAuth.instance.currentUser!.uid;

    // Pre-fill existing address
    FirebaseFirestore.instance.collection('users').doc(uid).get().then((doc) {
      locationController.text = doc.data()?['locationAddress'] ?? '';
    });

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Location Address'),
        content: TextField(
          controller: locationController,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: 'Location Address',
            hintText: 'House no., street, barangay, city',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              if (locationController.text.trim().isEmpty) return;
              await FirebaseFirestore.instance
                  .collection('users')
                  .doc(uid)
                  .update({'locationAddress': locationController.text.trim()});
              if (ctx.mounted) Navigator.pop(ctx);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('✅ Location updated!')),
                );
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryGreen,
            ),
            child: const Text('Save', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _showChangePasswordDialog(BuildContext context) {
    final currentController = TextEditingController();
    final newController = TextEditingController();
    final confirmController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          final newPass = newController.text;
          final confirmPass = confirmController.text;
          final currentPass = currentController.text;

          // Real-time validation checks
          final hasMinLength = newPass.length >= 8;
          final hasUppercase = RegExp(r'[A-Z]').hasMatch(newPass);
          final hasNumber = RegExp(r'[0-9]').hasMatch(newPass);
          final isDifferentFromCurrent =
              newPass.isEmpty || newPass != currentPass;
          final passwordsMatch = confirmPass.isEmpty || newPass == confirmPass;

          return AlertDialog(
            title: const Text('Change Password'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Current password
                  TextField(
                    controller: currentController,
                    obscureText: true,
                    onChanged: (v) => setDialogState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Current Password',
                      prefixIcon: Icon(Icons.lock_outline),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // New password
                  TextField(
                    controller: newController,
                    obscureText: true,
                    onChanged: (v) => setDialogState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'New Password',
                      prefixIcon: Icon(Icons.lock_reset),
                    ),
                  ),
                  const SizedBox(height: 8),

                  // Real-time requirement indicators
                  if (newPass.isNotEmpty) ...[
                    const Text(
                      'Password Requirements:',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.textMuted,
                      ),
                    ),
                    const SizedBox(height: 4),
                    _buildRequirementRow(hasMinLength, 'At least 8 characters'),
                    const SizedBox(height: 2),
                    _buildRequirementRow(
                      hasUppercase,
                      'At least 1 uppercase letter',
                    ),
                    const SizedBox(height: 2),
                    _buildRequirementRow(hasNumber, 'At least 1 number'),
                    const SizedBox(height: 2),
                    _buildRequirementRow(
                      isDifferentFromCurrent,
                      'Different from current password',
                    ),
                  ],
                  const SizedBox(height: 12),

                  // Confirm password
                  TextField(
                    controller: confirmController,
                    obscureText: true,
                    onChanged: (v) => setDialogState(() {}),
                    decoration: InputDecoration(
                      labelText: 'Confirm New Password',
                      prefixIcon: const Icon(Icons.check_circle_outline),
                      errorText: confirmPass.isNotEmpty && !passwordsMatch
                          ? 'Passwords do not match'
                          : null,
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () async {
                  final current = currentController.text;
                  final newPass = newController.text;
                  final confirm = confirmController.text;

                  if (current.isEmpty || newPass.isEmpty || confirm.isEmpty) {
                    return;
                  }

                  final isValid =
                      hasMinLength &&
                      hasUppercase &&
                      hasNumber &&
                      isDifferentFromCurrent &&
                      passwordsMatch;

                  if (!isValid) {
                    return;
                  }

                  try {
                    final user = FirebaseAuth.instance.currentUser!;
                    final credential = EmailAuthProvider.credential(
                      email: user.email!,
                      password: current,
                    );
                    await user.reauthenticateWithCredential(credential);
                    await user.updatePassword(newPass);
                    if (context.mounted) {
                      Navigator.pop(ctx);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('✅ Password changed successfully!'),
                        ),
                      );
                    }
                  } catch (e) {
                    if (!context.mounted) return;
                    setDialogState(() {});
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'That current password doesn\'t match. Please try again.',
                        ),
                      ),
                    );
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryGreen,
                ),
                child: const Text(
                  'Change Password',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildRequirementRow(bool isMet, String requirement) {
    return Row(
      children: [
        Icon(
          isMet ? Icons.check_circle : Icons.cancel,
          size: 14,
          color: isMet ? AppTheme.success : AppTheme.errorRed,
        ),
        const SizedBox(width: 6),
        Text(
          requirement,
          style: TextStyle(
            fontSize: 11,
            color: isMet ? AppTheme.success : AppTheme.errorRed,
            fontWeight: isMet ? FontWeight.w500 : FontWeight.normal,
          ),
        ),
      ],
    );
  }

  void _showTermsDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(
          'Terms & Conditions',
          textAlign: TextAlign.center,
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'TODA E-QUEUE+',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.primaryGreen,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Terms and Conditions & Privacy Policy',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: AppTheme.textMuted),
                ),
                const SizedBox(height: 20),

                const Text(
                  '1. ACCEPTANCE OF TERMS',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                  'By registering and using TODA E-QUEUE+ (the "App"), you agree to be bound by these Terms and Conditions. If you do not agree, you must not use the App.',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),

                const Text(
                  '2. DESCRIPTION OF SERVICE',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                  'TODA E-QUEUE+ is a geo-fenced queue management, booking, and safety system for the Federation of Baliwag City TODA. Features include automated queue management, passenger booking, GPS trip tracking, fare calculation, and emergency SOS.',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),

                const Text(
                  '3. DRIVER RESPONSIBILITIES',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                  '• Provide valid identification documents\n'
                  '• Maintain a valid tricycle franchise\n'
                  '• Follow TODA regulations and city ordinances\n'
                  '• Stay within assigned terminal geofence when queuing\n'
                  '• Complete accepted bookings in a timely manner\n'
                  '• Honor the fare calculated by the system\n'
                  '• Maintain professional conduct at all times\n'
                  '• Report incidents or violations promptly',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),

                const Text(
                  '4. PASSENGER RESPONSIBILITIES',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                  '• Provide accurate booking information\n'
                  '• Be at the designated pickup location on time\n'
                  '• Pay the calculated fare upon trip completion\n'
                  '• Treat drivers with respect\n'
                  '• Use SOS feature only for genuine emergencies\n'
                  '• Not engage in fraudulent activities',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),

                const Text(
                  '5. FARE POLICY',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                // The rates in force, not the ones the app shipped with.
                Text(
                  '${FareService.instance.policyLines}\n'
                  '• Fares calculated based on GPS road distance\n'
                  '• Payment accepted: Cash or GCash QR code\n'
                  '• Fares are non-negotiable',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),

                const Text(
                  '6. QUEUE MANAGEMENT',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                  '• Drivers must be within designated geofence to join queue\n'
                  '• Queue follows FIFO (First-In, First-Out) order\n'
                  '• Drivers who leave queue go to the back upon re-entry\n'
                  '• 20-minute cooldown applies after leaving queue\n'
                  '• Unverified drivers are not permitted in the queue',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),

                const Text(
                  '7. CANCELLATION POLICY',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                  '• Passengers may cancel before driver accepts\n'
                  '• Cancellation restricted after driver acceptance\n'
                  '• Repeated cancellations may result in restrictions\n'
                  '• Drivers who cancel without valid reason face penalties',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),

                const Text(
                  '8. PRIVACY POLICY',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Information We Collect:\n'
                  '• Name, email, phone number\n'
                  '• GPS location during active trips\n'
                  '• Profile photos and verification documents\n'
                  '• Trip history and payment records\n'
                  '• Ratings and feedback',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'How We Use Your Information:\n'
                  '• To provide transportation services\n'
                  '• To verify driver credentials\n'
                  '• To process bookings and payments\n'
                  '• To send important notifications\n'
                  '• To respond to SOS emergencies',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Data Protection:\n'
                  '• Data stored securely in Firebase Cloud Firestore\n'
                  '• Personal information never sold to third parties\n'
                  '• GPS only active during trips or queue participation\n'
                  '• Users may request data deletion',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),

                const Text(
                  '9. EMERGENCY FEATURES',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                  '• SOS button sends alert with location to TODA admin\n'
                  '• SOS should only be used in genuine emergencies\n'
                  '• Misuse may result in account suspension',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),

                const Text(
                  '10. RATING SYSTEM',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                  '• Passengers may rate drivers 1-5 stars\n'
                  '• Drivers may respond to ratings\n'
                  '• Ratings are visible to other users\n'
                  '• Continuous low ratings may affect privileges',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),

                const Text(
                  '11. LIMITATION OF LIABILITY',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                  'TODA E-QUEUE+ is a platform connecting drivers and passengers. We do not provide transportation services directly and are not liable for incidents during trips.',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),

                const Text(
                  '12. TERMINATION',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                  'We reserve the right to suspend accounts for violation of terms, fraudulent activity, or misuse of emergency features.',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),

                const Text(
                  '13. CONTACT',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Federation of Baliwag City TODA\n'
                  'Email: fedbaliwagtoda@gmail.com\n'
                  'Baliwag City Hall, Bulacan',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _sendSuggestion(BuildContext context) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Suggestion'),
        content: TextField(
          controller: controller,
          maxLines: 4,
          decoration: const InputDecoration(
            hintText: 'Share your suggestion...',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Submit'),
          ),
        ],
      ),
    );

    if (result == null || result.isEmpty || !mounted) return;

    await FirebaseFirestore.instance.collection('tickets').add({
      'userId': uid,
      'type': 'suggestion',
      'message': result,
      'status': 'open',
      'createdAt': FieldValue.serverTimestamp(),
    });

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✅ Thanks — your suggestion was sent.')),
      );
    }
  }

  void _showHelpTopics(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Help Topics'),
        content: const SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '1. How to book a ride?',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              Text(
                'Tap "Book a Ride", select terminal, pick pickup and destination.',
              ),
              SizedBox(height: 12),
              Text(
                '2. How to track my driver?',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              Text('After booking, tap "Track Driver" to see live location.'),
              SizedBox(height: 12),
              Text(
                '3. How to use SOS?',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              Text('Tap the red SOS button in an emergency.'),
              SizedBox(height: 12),
              Text(
                '4. How to pay?',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              Text('Pay cash or GCash after trip, then mark as paid.'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final data = snapshot.data!.data() as Map<String, dynamic>?;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const SizedBox(height: 24),
            Center(
              child: Column(
                children: [
                  GestureDetector(
                    onTap: () => _uploadProfilePicture(context),
                    child: CircleAvatar(
                      radius: 48,
                      backgroundColor: AppTheme.primaryBlue,
                      backgroundImage: data?['profilePhotoUrl'] != null
                          ? NetworkImage(data!['profilePhotoUrl'])
                          : null,
                      child: data?['profilePhotoUrl'] == null
                          ? Text(
                              (data?['name'] ?? 'P').toString().substring(0, 1),
                              style: const TextStyle(
                                fontSize: 36,
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            )
                          : null,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Tap to change photo',
                    style: TextStyle(fontSize: 10, color: AppTheme.textMuted),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 2),
            Center(
              child: Text(
                data?['name'] ?? 'Passenger',
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(height: 1),
            Center(
              child: Text(
                FirebaseAuth.instance.currentUser?.email ?? '',
                style: const TextStyle(color: AppTheme.textMuted),
              ),
            ),
            const SizedBox(height: 32),

            // Personal Information Card (Editable)
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
                    trailing: const Icon(Icons.edit, size: 16),
                    onTap: () => _showEditNameDialog(context),
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  ListTile(
                    leading: const Icon(Icons.email_outlined),
                    title: const Text('Email'),
                    // Known locally from the signed-in account, rather than
                    // read back off a document other people can see.
                    subtitle: Text(
                      FirebaseAuth.instance.currentUser?.email ?? '',
                    ),
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  MyContact(
                    builder: (context, contact) => ListTile(
                      leading: const Icon(Icons.phone_outlined),
                      title: const Text('Phone'),
                      subtitle: Text(contact.phone ?? 'Not set'),
                      trailing: const Icon(Icons.edit, size: 16),
                      onTap: () => _showEditPhoneDialog(context),
                    ),
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  // Edit Location — inside Personal Info
                  ListTile(
                    leading: const Icon(
                      Icons.home_outlined,
                      color: AppTheme.info,
                    ),
                    title: const Text('Location Address'),
                    subtitle: Text(
                      data?['locationAddress'] ?? 'Not set',
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: const Icon(Icons.edit, size: 16),
                    onTap: () => _showEditLocationDialog(context),
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  ListTile(
                    leading: const Icon(Icons.verified_user_outlined),
                    title: const Text('Role'),
                    subtitle: Text(data?['role'] ?? 'passenger'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // My road reports — the dependable way to take one down; see
            // MyReportsScreen for why the map alone was not enough.
            Card(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: ListTile(
                leading: const Icon(
                  Icons.flag_outlined,
                  color: AppTheme.warning,
                ),
                title: const Text(
                  'My road reports',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: const Text('See what you reported, or take it down'),
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: () => MyReportsScreen.open(context),
              ),
            ),
            const SizedBox(height: 16),

            // Privacy & Security Card
            Card(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const ListTile(
                    leading: Icon(Icons.shield, color: AppTheme.primaryGreen),
                    title: Text(
                      'Privacy & Security',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  ListTile(
                    leading: const Icon(
                      Icons.lock_outline,
                      color: AppTheme.warning,
                    ),
                    title: const Text('Change Password'),
                    trailing: const Icon(Icons.chevron_right, size: 18),
                    onTap: () => _showChangePasswordDialog(context),
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  ListTile(
                    leading: const Icon(
                      Icons.description_outlined,
                      color: AppTheme.textMuted,
                    ),
                    title: const Text('Terms & Conditions'),
                    trailing: const Icon(Icons.chevron_right, size: 18),
                    onTap: () => _showTermsDialog(context),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // Settings Card
            Card(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  SwitchListTile(
                    secondary: const Icon(Icons.dark_mode_outlined),
                    title: const Text('Dark Mode'),
                    subtitle: const Text('Use dark theme'),
                    value: _darkMode,
                    onChanged: (value) {
                      setState(() => _darkMode = value);
                      ThemeController.instance.toggleTheme(value);
                    },
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // About Card
            Card(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.info_outlined),
                    title: const Text('About App'),
                    subtitle: const Text('TODA E-QUEUE+ v1.0.0'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.pushNamed(context, AppRoutes.about),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // Help Center Card
            Card(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(
                      Icons.bug_report,
                      color: AppTheme.warning,
                    ),
                    title: const Text('Send Ticket / Report Issue'),
                    trailing: const Icon(Icons.chevron_right, size: 18),
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.sendTicket),
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  ListTile(
                    leading: const Icon(Icons.lightbulb_outlined),
                    title: const Text('Suggestion'),
                    subtitle: const Text('Share your ideas'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _sendSuggestion(context),
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  ListTile(
                    leading: const Icon(Icons.help_outlined),
                    title: const Text('Help Topics'),
                    subtitle: const Text('Frequently asked questions'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _showHelpTopics(context),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: () async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Sign Out'),
                    content: const Text('Are you sure you want to sign out?'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text(
                          'Sign Out',
                          style: TextStyle(color: AppTheme.errorRed),
                        ),
                      ),
                    ],
                  ),
                );
                if (confirm == true && context.mounted) {
                  await FirebaseAuth.instance.signOut();
                  if (!context.mounted) return;
                  Navigator.pushReplacementNamed(context, AppRoutes.login);
                }
              },
              icon: const Icon(Icons.logout, color: AppTheme.errorRed),
              label: const Text(
                'Sign Out',
                style: TextStyle(color: AppTheme.errorRed),
              ),
            ),
            const SizedBox(height: 24),
            const Center(
              child: Text(
                'TODA E-QUEUE+ v1.0.0',
                style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
              ),
            ),
            const SizedBox(height: 8),
          ],
        );
      },
    );
  }
}

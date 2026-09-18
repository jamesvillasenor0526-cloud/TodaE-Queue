import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_map/flutter_map.dart';
import '../../../widgets/map_tiles.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import '../../../config/theme.dart';
import '../../../config/routes.dart';
import '../booking/payment_screen.dart';
import 'widgets/trip_status_card.dart';
import 'widgets/driver_eta_card.dart';
import '../../../core/models/glide.dart';
import '../../../core/models/location_fix.dart';
import '../../../core/models/location_need.dart';
import '../../../core/models/queue_rules.dart';
import '../../../core/services/dispatch_service.dart';
import '../../../core/models/trip_state.dart';
import '../../../core/services/location_hub.dart';
import '../../../core/services/receipt_service.dart';
import '../../../core/services/trip_service.dart';
import '../../shared/chat/message_button.dart';
import '../../shared/reports/report_map_layer.dart';
import '../../../core/models/trip_message.dart';
import '../../shared/navigation/gliding_marker_layer.dart';
import '../../shared/navigation/trip_route_layer.dart';
import '../../shared/navigation/vehicle_position.dart';
import '../../../core/services/phone_actions.dart';
import '../../../widgets/state_views.dart';

/// How far the passenger has to move before their own dot is redrawn.
///
/// They are usually standing still waiting, and a redraw rebuilds the whole
/// screen. Ten metres is a step or two of real movement rather than GPS
/// wandering on the spot.
const double kPassengerMovedMeters = 10;

class TripTrackingScreen extends StatefulWidget {
  final String bookingId;
  final String driverName;
  final String terminalName;

  const TripTrackingScreen({
    super.key,
    required this.bookingId,
    required this.driverName,
    required this.terminalName,
  });

  @override
  State<TripTrackingScreen> createState() => _TripTrackingScreenState();
}

class _TripTrackingScreenState extends State<TripTrackingScreen> {
  static const LatLng _baliwagCenter = LatLng(14.9540, 120.9010);
  bool _ratingShown = false;

  /// Asked once per visit: see the receipt check in build.
  bool _receiptChecked = false;

  /// While another driver is being found, so the offer can't be taken twice.
  bool _reassigning = false;

  /// Whether the dispatched driver has had long enough to accept. The clock
  /// above redraws this every few seconds.
  bool _waitingTooLong(Map<String, dynamic> data) {
    if (TripState.fromMap(widget.bookingId, data).trip !=
        TripStatus.requested) {
      return false;
    }
    final at = data['dispatchTime'] ?? data['createdAt'];
    if (at is! Timestamp) return false;
    return waitedLongEnoughToReassign(DateTime.now().difference(at.toDate()));
  }

  /// Gives up on a driver who has not answered, and takes the passenger to
  /// the trip with the next driver in the queue.
  ///
  /// Nothing used to time out: an ignored dispatch left the passenger
  /// waiting on a driver who might have gone home.
  Future<void> _findAnotherDriver() async {
    setState(() => _reassigning = true);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      final result = await DispatchService.instance.findAnotherDriver(
        widget.bookingId,
      );
      if (!mounted) return;
      if (!result.success) {
        setState(() => _reassigning = false);
        messenger.showSnackBar(
          SnackBar(content: Text(result.message ?? 'Please try again.')),
        );
        return;
      }
      messenger.showSnackBar(
        SnackBar(content: Text('${result.driverName} is on the way.')),
      );
      navigator.pushReplacement(
        MaterialPageRoute(
          builder: (_) => TripTrackingScreen(
            bookingId: result.bookingId!,
            driverName: result.driverName ?? 'Your driver',
            terminalName: widget.terminalName,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _reassigning = false);
      messenger.showSnackBar(
        SnackBar(content: Text('Could not find another driver: $e')),
      );
    }
  }

  StreamSubscription<Position>? _positionStream;

  /// Where the driver's marker is drawn, shared with the route line so the
  /// line always starts under the tricycle instead of drifting off it.
  final VehiclePosition _driverDrawnAt = VehiclePosition();
  LatLng? _passengerPosition;
  final MapController _mapController = MapController();

  /// Redraws "updated N s ago", which ages even when no reading arrives.
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    _startPassengerLocationUpdates();
    _loadPassengerLastLocation();
    // Slow on purpose. This rebuilds the entire screen — map, tiles, every
    // card — and the only things that need it are the stale-driver warning
    // and the "your driver hasn't answered" prompt, which are about
    // fifteen seconds and ninety seconds respectively. The line "updated N
    // s ago" keeps its own time (see _LiveAgeText), so it stays accurate
    // without dragging the map through a rebuild every five seconds.
    _clock = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _driverDrawnAt.dispose();
    _positionStream?.cancel();
    _clock?.cancel();
    super.dispose();
  }

  /// How fresh the driver's position is, in words — or null when the
  /// driver's app does not say when it was taken.
  ///
  /// This used to read "Driver location updating live..." whatever was
  /// happening, including when the driver's phone had stopped reporting.
  static ({String text, bool stale})? _driverLocationAge(
    Map<String, dynamic> data,
  ) {
    final at = data['driverLocationAt'];
    if (at is! Timestamp) return null;
    final age = DateTime.now().difference(at.toDate());
    final safeAge = age.isNegative ? Duration.zero : age;
    final stale = safeAge > kDriverLocationStale;
    return (
      text: stale
          ? "Driver's location last updated ${fixAgeLabel(safeAge)} — "
                'their phone may have lost signal'
          : 'Driver location live · updated ${fixAgeLabel(safeAge)}',
      stale: stale,
    );
  }

  void _startPassengerLocationUpdates() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }
    if (permission == LocationPermission.deniedForever) return;
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      if (mounted) {
        setState(
          () => _passengerPosition = LatLng(pos.latitude, pos.longitude),
        );
      }
    } catch (_) {}
    // From the app's shared stream: the plugin runs only one, and a request
    // of its own here would be handed whatever pace was already set.
    _positionStream = LocationHub.instance
        .watch(
          const LocationNeed(interval: Duration(seconds: 2), distanceFilter: 5),
        )
        .listen((Position p) {
          if (!mounted) return;
          final at = LatLng(p.latitude, p.longitude);
          // A passenger waiting for a tricycle is standing still, and GPS
          // wanders a few metres while they do. Rebuilding this whole
          // screen — map, tiles, every card — for that wander, twice a
          // second, is most of what made the screen feel rough. Their own
          // dot only matters when they have actually moved.
          final last = _passengerPosition;
          if (last != null &&
              const Distance().as(LengthUnit.Meter, last, at) <
                  kPassengerMovedMeters) {
            return;
          }
          setState(() => _passengerPosition = at);
        });
  }

  void _loadPassengerLastLocation() async {
    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();
      final data = doc.data();
      if (data != null &&
          data['lastLatitude'] != null &&
          _passengerPosition == null &&
          mounted) {
        setState(
          () => _passengerPosition = LatLng(
            data['lastLatitude'] as double,
            data['lastLongitude'] as double,
          ),
        );
      }
    } catch (_) {}
  }

  void _showRatingDialog(BuildContext context, String driverId) {
    if (_ratingShown) return;
    _ratingShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      // Nothing to ask if this trip has already been rated — from this
      // phone or another. Old ratings carry a random id, so this looks the
      // trip up by its booking rather than by the rating's id.
      try {
        final existing = await FirebaseFirestore.instance
            .collection('ratings')
            .where('bookingId', isEqualTo: widget.bookingId)
            .limit(1)
            .get();
        if (existing.docs.isNotEmpty || !mounted) return;
      } catch (_) {
        // Could not check; better to offer the rating than to lose it.
      }
      if (!mounted) return;
      showDialog(
        // This screen's own context: the one passed in was captured before
        // the lookup above.
        context: this.context,
        barrierDismissible: false,
        builder: (c) => _RatingDialog(
          bookingId: widget.bookingId,
          driverId: driverId,
          driverName: widget.driverName,
          // Payment still needs to happen on this screen after the trip
          // ends, so just close the dialog rather than navigating away.
          onDone: () => Navigator.pop(c),
          onSkip: () => Navigator.pop(c),
        ),
      );
    });
  }

  Future<void> _cancelTrip(
    BuildContext context,
    Map<String, dynamic> data,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel Trip?'),
        content: const Text('Are you sure you want to cancel?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('No'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.errorRed),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Yes, Cancel',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      // Go through the state machine so tripStatus is set too. Writing only
      // the legacy `status` field left the trip reading as still active,
      // because TripState prefers tripStatus.
      await TripService.instance.moveTrip(
        bookingId: widget.bookingId,
        to: TripStatus.cancelled,
        by: TripRole.passenger,
      );
      await FirebaseFirestore.instance
          .collection('bookings')
          .doc(widget.bookingId)
          .update({'cancelledReason': 'Passenger cancelled the trip'});

      // The driver keeps the place they were waiting in: they did nothing
      // wrong. Cancelling their entry, as this used to, put them at the back
      // of the queue — or out of it — because a passenger changed their mind.
      final qid = data['queueEntryId'] as String?;
      if (qid != null) {
        await DispatchService.instance.returnDriverToQueue(qid);
      }
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Trip cancelled.')));
        Navigator.pushReplacementNamed(context, AppRoutes.passengerHome);
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not cancel the trip: $e')),
        );
      }
    }
  }

  /// Header tint for the current trip state, so the banner colour matches
  /// what the status card below it is saying.
  Color _headerColor(Map<String, dynamic> data) {
    final trip = TripState.fromMap(widget.bookingId, data).trip;
    return switch (trip) {
      TripStatus.cancelled => AppTheme.errorRed,
      TripStatus.tripCompleted => AppTheme.success,
      _ => AppTheme.primaryBlue,
    };
  }

  LatLng _calculateCenter(LatLng? a, LatLng? b) {
    if (a != null && b != null) {
      return LatLng(
        (a.latitude + b.latitude) / 2,
        (a.longitude + b.longitude) / 2,
      );
    }
    return a ?? b ?? _baliwagCenter;
  }

  /// The driver's number: from the booking, or else from their profile.
  ///
  /// Only 26 of 63 bookings carry the driver's number, and the buttons did
  /// nothing at all without it. They also asked canLaunchUrl first, which
  /// on Android 11+ said no to every number (see phone_actions.dart).
  /// The driver's number, from the booking — the driver's own app puts it
  /// there when they accept.
  ///
  /// It used to fall back to reading the driver's user record, which is how
  /// every signed-in account could read all 78 phone numbers in the
  /// database. There is no fallback now: before the driver accepts, and on
  /// trips booked by an older version of the app, Call is unavailable and
  /// says so.
  Future<String?> _driverPhone(Map<String, dynamic> booking) async {
    final onBooking = booking['driverPhone'] as String?;
    return dialableNumber(onBooking) == null ? null : onBooking;
  }

  Future<void> _callDriver(Map<String, dynamic> booking) async {
    final phone = await _driverPhone(booking);
    if (mounted) await callNumber(context, phone, who: 'The driver');
  }

  Future<void> _messageDriver(Map<String, dynamic> booking) async {
    final phone = await _driverPhone(booking);
    if (mounted) await textNumber(context, phone, who: 'The driver');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Trip Tracking'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () async {
            final confirm = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('Leave Tracking?'),
                content: const Text(
                  'Are you sure you want to leave the trip tracking screen?',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Stay'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Leave'),
                  ),
                ],
              ),
            );
            if (confirm == true && context.mounted) {
              Navigator.pushReplacementNamed(context, AppRoutes.passengerHome);
            }
          },
        ),
      ),
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance
            .collection('bookings')
            .doc(widget.bookingId)
            .snapshots(),
        builder: (context, snapshot) {
          // A failed listener used to leave a spinner turning with no
          // message and no way back — signing out on another device, or
          // losing permission, looked exactly like loading.
          if (snapshot.hasError) {
            return ErrorView(
              message:
                  "We can't load this trip right now. Check your connection "
                  'and try again.',
              onRetry: () => setState(() {}),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final data = snapshot.data!.data() as Map<String, dynamic>?;
          if (data == null) {
            return const Center(child: Text('Booking not found.'));
          }

          // The authoritative trip state, not the legacy mirror: a
          // completed trip drives the rating prompt, and reading the
          // lagging field would either miss it or fire it early.
          final tripCompleted =
              TripState.fromMap(widget.bookingId, data).trip ==
              TripStatus.tripCompleted;
          final driverId = data['driverId'] ?? '';
          final driverLat = data['driverLatitude'] as double?;
          final driverLng = data['driverLongitude'] as double?;
          final hasDriverLocation = driverLat != null && driverLng != null;
          final driverPosition = hasDriverLocation
              ? LatLng(driverLat, driverLng)
              : null;

          // The map deliberately isn't re-centred on every build. It used to
          // be, which snapped the camera onto the driver at zoom 16 several
          // times a second and fought the route layer's attempt to frame the
          // whole journey — the passenger could never see where they were
          // going. The recentre button below still does it on demand.

          String estimatedArrival = 'Calculating...';
          if (hasDriverLocation && data['pickupLatitude'] != null) {
            final d = const Distance().as(
              LengthUnit.Meter,
              driverPosition!,
              LatLng(
                data['pickupLatitude'] as double,
                data['pickupLongitude'] as double,
              ),
            );
            final s = (d / 5.5);
            if (s < 60) {
              estimatedArrival = 'Less than 1 min';
            } else if (s < 3600) {
              estimatedArrival = '~${s ~/ 60} min';
            } else {
              estimatedArrival = '~${s ~/ 3600}h ${(s % 3600) ~/ 60}m';
            }
          }

          if (tripCompleted && !_ratingShown) {
            _showRatingDialog(context, driverId);
          }

          // A trip paid before receipts were made from one place can still
          // be missing one; three in the database are. Making it here means
          // opening the trip is enough to put that right.
          if (!_receiptChecked &&
              TripState.fromMap(widget.bookingId, data).payment.isSettled &&
              data['receiptNumber'] == null) {
            _receiptChecked = true;
            ReceiptService.instance.ensureReceiptQuietly(widget.bookingId);
          }

          final driverAge = _driverLocationAge(data);

          // The driver is drawn by GlidingMarkerLayer below, so it drives
          // between readings instead of hopping.
          final markers = <Marker>[];
          if (_passengerPosition != null) {
            markers.add(
              Marker(
                point: _passengerPosition!,
                width: 40,
                height: 40,
                child: GestureDetector(
                  onTap: () {
                    _mapController.move(_passengerPosition!, 16);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('📍 Your location'),
                        duration: Duration(seconds: 1),
                      ),
                    );
                  },
                  child: const Icon(
                    Icons.person_pin_circle,
                    color: AppTheme.primaryGreen,
                    size: 36,
                  ),
                ),
              ),
            );
          }

          final pLat = data['pickupLatitude'] as double?;
          final pLng = data['pickupLongitude'] as double?;
          if (pLat != null && pLng != null) {
            final pickupPoint = LatLng(pLat, pLng);
            markers.add(
              Marker(
                point: pickupPoint,
                width: 40,
                height: 40,
                child: GestureDetector(
                  onTap: () {
                    _mapController.move(pickupPoint, 16);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('📍 Pickup location'),
                        duration: Duration(seconds: 1),
                      ),
                    );
                  },
                  child: const Icon(
                    Icons.flag,
                    color: AppTheme.warning,
                    size: 28,
                  ),
                ),
              ),
            );
          }

          final dLat = data['destinationLatitude'] as double?;
          final dLng = data['destinationLongitude'] as double?;
          if (dLat != null && dLng != null) {
            final destinationPoint = LatLng(dLat, dLng);
            markers.add(
              Marker(
                point: destinationPoint,
                width: 40,
                height: 40,
                child: GestureDetector(
                  onTap: () {
                    _mapController.move(destinationPoint, 16);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('📍 Destination'),
                        duration: Duration(seconds: 1),
                      ),
                    );
                  },
                  child: const Icon(
                    Icons.location_on,
                    color: AppTheme.errorRed,
                    size: 28,
                  ),
                ),
              ),
            );
          }
          final mapCenter = _calculateCenter(
            driverPosition,
            _passengerPosition,
          );

          // Where the driver is actually heading: the pick-up point until
          // the passenger is aboard, the destination afterwards.
          //
          // The route used to be drawn to `mapCenter`, which is the middle
          // of the camera — half way between the driver and the passenger,
          // or the middle of Baliwag when neither was known. That is not a
          // place anyone is going, so the line ran off to a point on no
          // road and stayed there.
          final trip = TripState.fromMap(widget.bookingId, data);
          final aboard =
              trip.trip == TripStatus.tripInProgress ||
              trip.trip == TripStatus.readyToStart;
          final routePickup = (pLat != null && pLng != null)
              ? LatLng(pLat, pLng)
              : null;
          final routeDestination = (dLat != null && dLng != null)
              ? LatLng(dLat, dLng)
              : null;
          final routeTarget = aboard
              ? (routeDestination ?? routePickup)
              : (routePickup ?? _passengerPosition ?? routeDestination);

          return Column(
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                // Header derives from the same authoritative trip state as
                // the status card below, so the two can never disagree.
                color: _headerColor(data),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      TripState.fromMap(
                        widget.bookingId,
                        data,
                      ).trip.passengerLabel,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Driver: ${widget.driverName} • Terminal: ${widget.terminalName}',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                      ),
                    ),
                    if (!tripCompleted && hasDriverLocation) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.timer,
                              color: Colors.white,
                              size: 16,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Est. arrival: $estimatedArrival',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              // Contact driver buttons
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _callDriver(data),
                        icon: const Icon(Icons.call, size: 16),
                        label: const Text(
                          'Call Driver',
                          style: TextStyle(fontSize: 12),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppTheme.primaryBlue,
                          side: const BorderSide(color: AppTheme.primaryBlue),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // In-app messages, which reach the driver while the trip
                    // is running without either side learning the other's
                    // number.
                    Expanded(
                      child: MessageButton(
                        bookingId: widget.bookingId,
                        role: MessageSender.passenger,
                        otherName:
                            (data['driverName'] as String?)
                                    ?.trim()
                                    .isNotEmpty ==
                                true
                            ? data['driverName'] as String
                            : 'Your driver',
                        compact: true,
                      ),
                    ),
                    // SMS stays: it reaches a driver whose app is closed.
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: 'Send an SMS instead',
                      onPressed: () => _messageDriver(data),
                      icon: const Icon(Icons.sms_outlined, size: 20),
                      color: AppTheme.textMuted,
                    ),
                  ],
                ),
              ),

              Expanded(
                child: Stack(
                  children: [
                    FlutterMap(
                      mapController: _mapController,
                      options: MapOptions(
                        initialCenter: mapCenter,
                        initialZoom: 16,
                      ),
                      children: [
                        // Full colour: here the map is what the passenger is
                        // reading — which road the tricycle is on — not a
                        // backdrop for a route line.
                        AppTileLayer(muted: false),
                        // Traffic and incidents matter most while you are
                        // actually on the road, so the overlay follows the
                        // trip too.
                        TrafficOverlay(origin: mapCenter, radiusKm: 3),
                        // The driver's actual route, from the same record
                        // they publish it to. The passenger had no route
                        // line at all before this — only markers — so a
                        // reroute was invisible to them.
                        // No target, no line: a route to nowhere is worse
                        // than none at all.
                        if (driverPosition != null && routeTarget != null)
                          TripRouteLayer(
                            bookingId: widget.bookingId,
                            controller: _mapController,
                            from: driverPosition,
                            to: routeTarget,
                            follows: _driverDrawnAt,
                          ),
                        MarkerLayer(markers: markers),
                        GlidingMarkerLayer(
                          target: driverPosition,
                          reports: _driverDrawnAt,
                          child: GestureDetector(
                            onTap: () {
                              if (driverPosition != null) {
                                _mapController.move(driverPosition, 16);
                              }
                            },
                            child: Icon(
                              Icons.electric_rickshaw,
                              // Greyed when the phone has stopped reporting,
                              // so an old position is not read as current.
                              color: driverAge?.stale == true
                                  ? Colors.grey
                                  : AppTheme.primaryBlue,
                              size: 36,
                            ),
                          ),
                        ),
                      ],
                    ),
                    // Recenter button
                    Positioned(
                      bottom: 16,
                      right: 16,
                      child: FloatingActionButton.small(
                        backgroundColor: Colors.white,
                        tooltip: 'Recenter',
                        onPressed: () {
                          _mapController.move(mapCenter, 16);
                        },
                        child: const Icon(
                          Icons.my_location,
                          color: AppTheme.primaryBlue,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // Driver's live ETA and route, read straight off the same
              // booking document the driver writes to.
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: DriverEtaCard(
                  bookingId: widget.bookingId,
                  trip: TripState.fromMap(widget.bookingId, data),
                ),
              ),
              // One card driven entirely by the shared backend trip record,
              // so whatever the driver does lands here without a refresh.
              TripStatusCard(
                bookingId: widget.bookingId,
                onPayWithGcash: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => PaymentScreen(
                        bookingId: widget.bookingId,
                        driverId: driverId,
                        driverName: data['driverName'] ?? widget.driverName,
                        fare: (data['fare'] ?? 0).toDouble(),
                        distance: (data['distance'] ?? 0).toDouble(),
                        terminalName:
                            data['terminalName'] ?? widget.terminalName,
                      ),
                    ),
                  );
                },
              ),
              // Waiting on a driver who has not answered. The offer appears
              // only once they have had [kAcceptWindow]; before that the
              // status card's "Matching you with the next driver" stands.
              if (_waitingTooLong(data))
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppTheme.warning.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.hourglass_bottom,
                          color: AppTheme.warning,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            "Your driver hasn't answered yet.",
                            style: TextStyle(fontSize: 13),
                          ),
                        ),
                        TextButton(
                          onPressed: _reassigning ? null : _findAnotherDriver,
                          child: Text(
                            _reassigning ? 'Finding…' : 'Find another driver',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (data['receiptNumber'] != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextButton.icon(
                    onPressed: () => Navigator.pushNamed(
                      context,
                      AppRoutes.receipt,
                      arguments: widget.bookingId,
                    ),
                    icon: const Icon(Icons.receipt_long, size: 16),
                    label: const Text('View Receipt'),
                  ),
                ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                color: Colors.grey.shade100,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    GestureDetector(
                      onTap: () {
                        if (driverPosition != null) {
                          _mapController.move(driverPosition, 16);
                        }
                      },
                      child: _LegendItem(
                        icon: Icons.electric_rickshaw,
                        color: AppTheme.primaryBlue,
                        label: 'Driver',
                      ),
                    ),
                    GestureDetector(
                      onTap: () {
                        if (_passengerPosition != null) {
                          _mapController.move(_passengerPosition!, 16);
                        }
                      },
                      child: _LegendItem(
                        icon: Icons.person_pin_circle,
                        color: AppTheme.primaryGreen,
                        label: 'You',
                      ),
                    ),
                    if (pLat != null && pLng != null)
                      GestureDetector(
                        onTap: () {
                          _mapController.move(LatLng(pLat, pLng), 16);
                        },
                        child: _LegendItem(
                          icon: Icons.flag,
                          color: AppTheme.warning,
                          label: 'Pickup',
                        ),
                      ),
                    if (dLat != null && dLng != null)
                      GestureDetector(
                        onTap: () {
                          _mapController.move(LatLng(dLat, dLng), 16);
                        },
                        child: _LegendItem(
                          icon: Icons.location_on,
                          color: AppTheme.errorRed,
                          label: 'Destination',
                        ),
                      ),
                  ],
                ),
              ),
              if (tripCompleted)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: ElevatedButton(
                    onPressed: () => Navigator.pushReplacementNamed(
                      context,
                      AppRoutes.passengerHome,
                    ),
                    child: const Text('Back to Home'),
                  ),
                )
              else
                Container(
                  padding: const EdgeInsets.all(16),
                  color: Colors.white,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.timer_outlined,
                            color: AppTheme.primaryBlue,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  hasDriverLocation
                                      ? 'Est. arrival: $estimatedArrival'
                                      : 'Waiting for driver...',
                                  style: const TextStyle(
                                    color: AppTheme.textMuted,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                if (hasDriverLocation)
                                  _LiveAgeText(
                                    measuredAt:
                                        (data['driverLocationAt'] as Timestamp?)
                                            ?.toDate(),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      // Offered exactly when the state machine allows it,
                      // rather than guessing from the legacy field — which
                      // lumps five states together and so hid the button
                      // for most of the window a passenger may cancel in.
                      if (canTransitionTrip(
                        TripState.fromMap(widget.bookingId, data).trip,
                        TripStatus.cancelled,
                        TripRole.passenger,
                      ))
                        OutlinedButton.icon(
                          onPressed: () => _cancelTrip(context, data),
                          icon: const Icon(
                            Icons.cancel_outlined,
                            color: AppTheme.errorRed,
                          ),
                          label: const Text(
                            'Cancel Trip',
                            style: TextStyle(color: AppTheme.errorRed),
                          ),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: AppTheme.errorRed),
                            minimumSize: const Size(double.infinity, 44),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _LegendItem extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  const _LegendItem({
    required this.icon,
    required this.color,
    required this.label,
  });
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, color: color, size: 20),
      const SizedBox(width: 4),
      Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
    ],
  );
}

class _RatingDialog extends StatefulWidget {
  final String bookingId, driverId, driverName;
  final VoidCallback onDone, onSkip;
  const _RatingDialog({
    required this.bookingId,
    required this.driverId,
    required this.driverName,
    required this.onDone,
    required this.onSkip,
  });
  @override
  State<_RatingDialog> createState() => _RatingDialogState();
}

class _RatingDialogState extends State<_RatingDialog> {
  int _rating = 0;
  final _c = TextEditingController();
  bool _sub = false;
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_rating == 0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Select a rating')));
      return;
    }
    setState(() => _sub = true);
    try {
      final pid = FirebaseAuth.instance.currentUser!.uid;
      // The trip's own id, so the same trip cannot be rated twice. The
      // driver's average is kept by the driver's app (RatingService):
      // writing it from here was refused every time, which is why every
      // rating ended in "Failed" and some were sent again.
      await FirebaseFirestore.instance
          .collection('ratings')
          .doc(widget.bookingId)
          .set({
            'bookingId': widget.bookingId,
            'driverId': widget.driverId,
            'passengerId': pid,
            'rating': _rating,
            'comment': _c.text.trim(),
            'createdAt': FieldValue.serverTimestamp(),
          });
      if (mounted) widget.onDone();
    } on FirebaseException catch (e) {
      if (!mounted) return;
      setState(() => _sub = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e.code == 'permission-denied'
                ? 'This trip has already been rated.'
                : 'Could not send your rating. Please try again.',
          ),
        ),
      );
      if (e.code == 'permission-denied') widget.onSkip();
    } catch (_) {
      if (!mounted) return;
      setState(() => _sub = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not send your rating.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    title: const Column(
      children: [
        Icon(Icons.star, color: Colors.amber, size: 48),
        SizedBox(height: 8),
        Text(
          'Rate your trip',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
      ],
    ),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'How was your ride with ${widget.driverName}?',
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppTheme.textMuted),
        ),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(
            5,
            (i) => GestureDetector(
              onTap: () => setState(() => _rating = i + 1),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Icon(
                  _rating >= i + 1 ? Icons.star : Icons.star_border,
                  color: Colors.amber,
                  size: 40,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          ['Poor', 'Fair', 'Good', 'Very Good', 'Excellent!'][_rating > 0
              ? _rating - 1
              : 0],
          style: const TextStyle(
            color: Colors.amber,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _c,
          maxLines: 3,
          decoration: InputDecoration(
            hintText: 'Leave a comment (optional)',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: _sub ? null : widget.onSkip,
        child: const Text('Skip'),
      ),
      ElevatedButton(
        onPressed: _sub ? null : _submit,
        child: _sub
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Text('Submit'),
      ),
    ],
  );
}

/// "Driver location live · updated 4 s ago", keeping its own time.
///
/// This line ages whether or not anything arrives, so it used to be redrawn
/// by a timer on the whole screen — rebuilding the map and every card twice
/// a minute for one line of text. Ticking here costs a paragraph.
class _LiveAgeText extends StatefulWidget {
  const _LiveAgeText({required this.measuredAt});

  /// When the driver's phone took the reading, or null when it did not say.
  final DateTime? measuredAt;

  @override
  State<_LiveAgeText> createState() => _LiveAgeTextState();
}

class _LiveAgeTextState extends State<_LiveAgeText> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final at = widget.measuredAt;
    if (at == null) return const SizedBox.shrink();
    final age = DateTime.now().difference(at);
    final safeAge = age.isNegative ? Duration.zero : age;
    final stale = safeAge > kDriverLocationStale;
    return Text(
      stale
          ? "Driver's location last updated ${fixAgeLabel(safeAge)} — "
                'their phone may have lost signal'
          : 'Driver location live · updated ${fixAgeLabel(safeAge)}',
      style: TextStyle(
        color: stale ? AppTheme.warning : AppTheme.textMuted,
        fontSize: 11,
      ),
    );
  }
}

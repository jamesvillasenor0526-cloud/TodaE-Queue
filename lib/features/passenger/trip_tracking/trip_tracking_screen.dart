import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import '../../../config/theme.dart';
import '../../../config/routes.dart';
import '../booking/payment_screen.dart';
import 'widgets/trip_status_card.dart';
import '../../../core/models/trip_state.dart';
import 'package:url_launcher/url_launcher.dart';

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

  StreamSubscription<Position>? _positionStream;
  LatLng? _passengerPosition;
  final MapController _mapController = MapController();

  @override
  void initState() {
    super.initState();
    _startPassengerLocationUpdates();
    _loadPassengerLastLocation();
  }

  @override
  void dispose() {
    _positionStream?.cancel();
    super.dispose();
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
    _positionStream =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 5,
          ),
        ).listen((Position p) {
          if (mounted) {
            setState(
              () => _passengerPosition = LatLng(p.latitude, p.longitude),
            );
          }
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showDialog(
        context: context,
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
      final batch = FirebaseFirestore.instance.batch();
      batch.update(
        FirebaseFirestore.instance.collection('bookings').doc(widget.bookingId),
        {
          'status': 'cancelled',
          'cancelledAt': FieldValue.serverTimestamp(),
          'cancelledReason': 'Passenger cancelled the trip',
        },
      );
      final qid = data['queueEntryId'] as String?;
      if (qid != null) {
        batch.update(
          FirebaseFirestore.instance.collection('queueEntries').doc(qid),
          {'status': 'cancelled', 'cancelledAt': FieldValue.serverTimestamp()},
        );
      }
      await batch.commit();
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

  void _callDriver(String phoneNumber) async {
    final formatted = phoneNumber.replaceAll(' ', '').replaceAll('-', '');
    final url = Uri.parse('tel:$formatted');

    debugPrint('🔍 Attempting to call: $formatted');

    try {
      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      } else {
        debugPrint('❌ No dialer app found');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('No dialer app found. Call manually: $formatted'),
              duration: const Duration(seconds: 3),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('❌ Call error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not make call. Number: $formatted')),
        );
      }
    }
  }

  void _messageDriver(String phoneNumber) async {
    final formatted = phoneNumber.replaceAll(' ', '').replaceAll('-', '');
    final url = Uri.parse('sms:$formatted');

    debugPrint('🔍 Attempting to message: $formatted');

    try {
      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      } else {
        debugPrint('❌ No SMS app found');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('No SMS app found. Message manually: $formatted'),
              duration: const Duration(seconds: 3),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('❌ SMS error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not send message. Number: $formatted')),
        );
      }
    }
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
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final data = snapshot.data!.data() as Map<String, dynamic>?;
          if (data == null) {
            return const Center(child: Text('Booking not found.'));
          }

          final status = data['status'] ?? 'assigned';
          final driverId = data['driverId'] ?? '';
          final driverLat = data['driverLatitude'] as double?;
          final driverLng = data['driverLongitude'] as double?;
          final hasDriverLocation = driverLat != null && driverLng != null;
          final driverPosition = hasDriverLocation
              ? LatLng(driverLat, driverLng)
              : null;

          // Add this after driverPosition:
          if (driverPosition != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _mapController.move(driverPosition, 16);
            });
          }

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

          if (status == 'completed' && !_ratingShown) {
            _showRatingDialog(context, driverId);
          }

          final markers = <Marker>[];
          if (driverPosition != null) {
            markers.add(
              Marker(
                point: driverPosition,
                width: 40,
                height: 40,
                child: GestureDetector(
                  onTap: () {
                    _mapController.move(driverPosition, 16);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('📍 Driver location'),
                        duration: Duration(seconds: 1),
                      ),
                    );
                  },
                  child: const Icon(
                    Icons.electric_rickshaw,
                    color: AppTheme.primaryBlue,
                    size: 36,
                  ),
                ),
              ),
            );
          }

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
                  child: const Icon(Icons.flag, color: AppTheme.warning, size: 28),
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
                    if (status != 'completed' && hasDriverLocation) ...[
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
                        onPressed: () {
                          final phone = data['driverPhone'] as String?;
                          if (phone != null) _callDriver(phone);
                        },
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
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          final phone = data['driverPhone'] as String?;
                          if (phone != null) _messageDriver(phone);
                        },
                        icon: const Icon(Icons.message, size: 16),
                        label: const Text(
                          'Message',
                          style: TextStyle(fontSize: 12),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppTheme.primaryGreen,
                          side: const BorderSide(color: AppTheme.primaryGreen),
                        ),
                      ),
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
                        TileLayer(
                          urlTemplate:
                              'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                          userAgentPackageName: 'com.example.toda_equeue_plus',
                        ),
                        MarkerLayer(markers: markers),
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
              if (status == 'completed')
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
                                  Text(
                                    'Driver location updating live...',
                                    style: const TextStyle(
                                      color: AppTheme.textMuted,
                                      fontSize: 11,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (status != 'accepted')
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
      await FirebaseFirestore.instance.collection('ratings').add({
        'bookingId': widget.bookingId,
        'driverId': widget.driverId,
        'passengerId': pid,
        'rating': _rating,
        'comment': _c.text.trim(),
        'createdAt': FieldValue.serverTimestamp(),
      });
      final snap = await FirebaseFirestore.instance
          .collection('ratings')
          .where('driverId', isEqualTo: widget.driverId)
          .get();
      final r = snap.docs
          .map((d) => (d.data()['rating'] as num).toDouble())
          .toList();
      await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.driverId)
          .update({
            'averageRating': double.parse(
              (r.reduce((a, b) => a + b) / r.length).toStringAsFixed(1),
            ),
            'totalRatings': r.length,
          });
      if (mounted) widget.onDone();
    } catch (e) {
      setState(() => _sub = false);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
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

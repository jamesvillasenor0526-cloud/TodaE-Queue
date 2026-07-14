import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../../../config/theme.dart';
import '../../../config/routes.dart';

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

  void _showRatingDialog(BuildContext context, String driverId) {
    if (_ratingShown) return;
    _ratingShown = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => _RatingDialog(
          bookingId: widget.bookingId,
          driverId: driverId,
          driverName: widget.driverName,
          onDone: () {
            Navigator.pop(dialogContext);
            Navigator.pushReplacementNamed(context, AppRoutes.passengerHome);
          },
          onSkip: () {
            Navigator.pop(dialogContext);
            Navigator.pushReplacementNamed(context, AppRoutes.passengerHome);
          },
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
        content: const Text(
          'Are you sure you want to cancel? The driver will be notified.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('No'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
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

      final bookingRef = FirebaseFirestore.instance
          .collection('bookings')
          .doc(widget.bookingId);
      batch.update(bookingRef, {
        'status': 'cancelled',
        'cancelledAt': FieldValue.serverTimestamp(),
      });

      final queueEntryId = data['queueEntryId'] as String?;
      if (queueEntryId != null) {
        final queueRef = FirebaseFirestore.instance
            .collection('queueEntries')
            .doc(queueEntryId);
        batch.update(queueRef, {
          'status': 'cancelled',
          'cancelledAt': FieldValue.serverTimestamp(),
        });
      }

      await batch.commit();

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Trip cancelled.')));
        Navigator.pushReplacementNamed(context, AppRoutes.passengerHome);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to cancel: $e')));
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
          onPressed: () =>
              Navigator.pushReplacementNamed(context, AppRoutes.passengerHome),
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

          // Show rating dialog when trip completes
          if (status == 'completed' && !_ratingShown) {
            _showRatingDialog(context, driverId);
          }

          return Column(
            children: [
              // Status banner
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                color: status == 'completed'
                    ? Colors.green
                    : AppTheme.primaryBlue,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      status == 'completed'
                          ? '✅ Trip Completed!'
                          : '🚗 Driver is on the way',
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
                  ],
                ),
              ),

              // Map
              Expanded(
                child: FlutterMap(
                  options: MapOptions(
                    initialCenter: driverPosition ?? _baliwagCenter,
                    initialZoom: 16,
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.example.toda_equeue_plus',
                    ),
                    if (driverPosition != null)
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: driverPosition,
                            width: 80,
                            height: 80,
                            child: const Column(
                              children: [
                                Icon(
                                  Icons.electric_rickshaw,
                                  color: AppTheme.primaryBlue,
                                  size: 36,
                                ),
                                Text(
                                  'Driver',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: AppTheme.primaryBlue,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),

              // Bottom info
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
                            Icons.info_outline,
                            color: AppTheme.primaryBlue,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              hasDriverLocation
                                  ? 'Driver location updating live...'
                                  : 'Waiting for driver location...',
                              style: const TextStyle(color: Colors.grey),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: () => _cancelTrip(context, data),
                        icon: const Icon(
                          Icons.cancel_outlined,
                          color: Colors.red,
                        ),
                        label: const Text(
                          'Cancel Trip',
                          style: TextStyle(color: Colors.red),
                        ),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Colors.red),
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

// ─── Rating Dialog ────────────────────────────────────────────────────────────

class _RatingDialog extends StatefulWidget {
  final String bookingId;
  final String driverId;
  final String driverName;
  final VoidCallback onDone;
  final VoidCallback onSkip;

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
  final _commentController = TextEditingController();
  bool _isSubmitting = false;

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  Future<void> _submitRating() async {
    if (_rating == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a star rating.')),
      );
      return;
    }

    setState(() => _isSubmitting = true);

    try {
      final passengerId = FirebaseAuth.instance.currentUser!.uid;

      // Save rating
      await FirebaseFirestore.instance.collection('ratings').add({
        'bookingId': widget.bookingId,
        'driverId': widget.driverId,
        'passengerId': passengerId,
        'rating': _rating,
        'comment': _commentController.text.trim(),
        'createdAt': FieldValue.serverTimestamp(),
      });

      // Update driver's average rating
      final ratingsSnap = await FirebaseFirestore.instance
          .collection('ratings')
          .where('driverId', isEqualTo: widget.driverId)
          .get();

      final ratings = ratingsSnap.docs
          .map((d) => (d.data()['rating'] as num).toDouble())
          .toList();

      final avg = ratings.reduce((a, b) => a + b) / ratings.length;
      final avgRounded = double.parse(avg.toStringAsFixed(1));

      await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.driverId)
          .update({
            'averageRating': avgRounded,
            'totalRatings': ratings.length,
          });

      if (mounted) widget.onDone();
    } catch (e) {
      setState(() => _isSubmitting = false);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to submit rating: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
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
            style: const TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: 20),

          // Star rating
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(5, (index) {
              final star = index + 1;
              return GestureDetector(
                onTap: () => setState(() => _rating = star),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Icon(
                    _rating >= star ? Icons.star : Icons.star_border,
                    color: Colors.amber,
                    size: 40,
                  ),
                ),
              );
            }),
          ),
          const SizedBox(height: 8),
          Text(
            _ratingLabel(_rating),
            style: const TextStyle(
              color: Colors.amber,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),

          // Comment field
          TextField(
            controller: _commentController,
            maxLines: 3,
            decoration: InputDecoration(
              hintText: 'Leave a comment (optional)',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _isSubmitting ? null : widget.onSkip,
          child: const Text('Skip'),
        ),
        ElevatedButton(
          onPressed: _isSubmitting ? null : _submitRating,
          child: _isSubmitting
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

  String _ratingLabel(int rating) {
    return switch (rating) {
      1 => 'Poor',
      2 => 'Fair',
      3 => 'Good',
      4 => 'Very Good',
      5 => 'Excellent!',
      _ => 'Tap a star to rate',
    };
  }
}

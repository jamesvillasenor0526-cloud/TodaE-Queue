import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import '../../config/theme.dart';
import '../../config/routes.dart';
import '../../core/services/geocoding_service.dart';

class TripDetailScreen extends StatefulWidget {
  final String bookingId;
  final String userRole;

  const TripDetailScreen({
    super.key,
    required this.bookingId,
    required this.userRole,
  });

  @override
  State<TripDetailScreen> createState() => _TripDetailScreenState();
}

class _TripDetailScreenState extends State<TripDetailScreen> {
  String _pickupName = 'Loading...';
  String _destinationName = 'Loading...';

  bool _placeNamesLoaded = false;

  Future<void> _getPlaceNames(Map<String, dynamic> data) async {
    if (_placeNamesLoaded) return; // ← Prevent infinite loop
    _placeNamesLoaded = true;

    if (data['pickupLatitude'] != null && data['pickupLongitude'] != null) {
      _pickupName = await GeocodingService.instance.getPlaceName(
        data['pickupLatitude'] as double,
        data['pickupLongitude'] as double,
      );
    }
    if (data['destinationLatitude'] != null &&
        data['destinationLongitude'] != null) {
      _destinationName = await GeocodingService.instance.getPlaceName(
        data['destinationLatitude'] as double,
        data['destinationLongitude'] as double,
      );
    }
    if (mounted) setState(() {});
  }

  Color _statusColor(String status) {
    return switch (status) {
      'assigned' => AppTheme.primaryBlue,
      'completed' => AppTheme.success,
      'cancelled' => AppTheme.textMuted,
      _ => AppTheme.textMuted,
    };
  }

  IconData _statusIcon(String status) {
    return switch (status) {
      'assigned' => Icons.electric_rickshaw,
      'completed' => Icons.check_circle,
      'cancelled' => Icons.cancel,
      _ => Icons.info,
    };
  }

  String _statusLabel(String status) {
    return switch (status) {
      'assigned' => 'Trip In Progress',
      'completed' => 'Trip Completed',
      'cancelled' => 'Trip Cancelled',
      _ => 'Unknown Status',
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Trip Details')),
      body: FutureBuilder<DocumentSnapshot>(
        future: FirebaseFirestore.instance
            .collection('bookings')
            .doc(widget.bookingId)
            .get(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (!snapshot.hasData || !snapshot.data!.exists) {
            return const Center(child: Text('Trip not found.'));
          }

          final data = snapshot.data!.data() as Map<String, dynamic>;

          // Fetch place names (only once)
          if (!_placeNamesLoaded) {
            _getPlaceNames(data);
          }

          final status = data['status'] ?? 'unknown';
          final terminalName = data['terminalName'] ?? 'Unknown Terminal';
          final driverName = data['driverName'] ?? 'Unknown Driver';
          final driverId = data['driverId'] ?? '';
          final passengerId = data['passengerId'] ?? '';
          final createdAt = data['createdAt'] as Timestamp?;
          final completedAt = data['completedAt'] as Timestamp?;

          final formattedDate = createdAt != null
              ? DateFormat('MMM dd, yyyy • hh:mm a').format(createdAt.toDate())
              : 'N/A';

          final formattedCompleted = completedAt != null
              ? DateFormat(
                  'MMM dd, yyyy • hh:mm a',
                ).format(completedAt.toDate())
              : null;

          String? duration;
          if (createdAt != null && completedAt != null) {
            final diff = completedAt.toDate().difference(createdAt.toDate());
            final minutes = diff.inMinutes;
            duration = minutes < 60
                ? '$minutes min'
                : '${diff.inHours}h ${diff.inMinutes % 60}m';
          }

          final otherPersonId = widget.userRole == 'passenger'
              ? driverId
              : passengerId;

          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Status banner
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: _statusColor(status),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    children: [
                      Icon(_statusIcon(status), color: Colors.white, size: 48),
                      const SizedBox(height: 8),
                      Text(
                        _statusLabel(status),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (duration != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          'Duration: $duration',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // Trip info card
                Card(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _DetailTile(
                        icon: Icons.location_on_outlined,
                        title: 'Terminal',
                        value: terminalName,
                      ),
                      const Divider(height: 1, indent: 16, endIndent: 16),

                      // Other person with profile photo
                      FutureBuilder<DocumentSnapshot>(
                        future: FirebaseFirestore.instance
                            .collection('users')
                            .doc(otherPersonId)
                            .get(),
                        builder: (context, userSnap) {
                          final otherData =
                              userSnap.data?.data() as Map<String, dynamic>?;
                          final otherName =
                              otherData?['name'] ??
                              (widget.userRole == 'passenger'
                                  ? driverName
                                  : 'Passenger');
                          final isVerified = otherData?['isVerified'] ?? false;
                          final profilePhoto =
                              otherData?['profilePhotoUrl'] as String?;

                          return ListTile(
                            leading: CircleAvatar(
                              radius: 24,
                              backgroundColor: widget.userRole == 'passenger'
                                  ? AppTheme.primaryBlue
                                  : AppTheme.primaryGreen,
                              backgroundImage: profilePhoto != null
                                  ? NetworkImage(profilePhoto)
                                  : null,
                              child: profilePhoto == null
                                  ? Text(
                                      otherName.substring(0, 1).toUpperCase(),
                                      style: const TextStyle(
                                        fontSize: 18,
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    )
                                  : null,
                            ),
                            title: Text(
                              widget.userRole == 'passenger'
                                  ? 'Driver'
                                  : 'Passenger',
                              style: const TextStyle(
                                fontSize: 12,
                                color: AppTheme.textMuted,
                              ),
                            ),
                            subtitle: Row(
                              children: [
                                Text(
                                  otherName,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                if (widget.userRole == 'passenger' &&
                                    isVerified) ...[
                                  const SizedBox(width: 4),
                                  const Icon(
                                    Icons.verified,
                                    color: AppTheme.success,
                                    size: 14,
                                  ),
                                ],
                              ],
                            ),
                            trailing: const Icon(
                              Icons.chevron_right,
                              color: AppTheme.textMuted,
                            ),
                            onTap: otherPersonId.isNotEmpty
                                ? () => Navigator.pushNamed(
                                    context,
                                    AppRoutes.userProfile,
                                    arguments: {
                                      'uid': otherPersonId,
                                      'viewerRole': widget.userRole,
                                    },
                                  )
                                : null,
                          );
                        },
                      ),

                      // Pickup location
                      if (data['pickupLatitude'] != null &&
                          data['pickupLongitude'] != null) ...[
                        const Divider(height: 1, indent: 16, endIndent: 16),
                        _DetailTile(
                          icon: Icons.trip_origin,
                          title: 'Pickup Location',
                          value: _pickupName,
                        ),
                      ],
                      // Destination
                      if (data['destinationLatitude'] != null &&
                          data['destinationLongitude'] != null) ...[
                        const Divider(height: 1, indent: 16, endIndent: 16),
                        _DetailTile(
                          icon: Icons.flag,
                          title: 'Destination',
                          value: _destinationName,
                        ),
                      ],
                      // Distance
                      if (data['distance'] != null) ...[
                        const Divider(height: 1, indent: 16, endIndent: 16),
                        _DetailTile(
                          icon: Icons.straighten,
                          title: 'Distance',
                          value: '${data['distance'].toStringAsFixed(2)} km',
                        ),
                      ],
                      // Fare
                      if (data['fare'] != null) ...[
                        const Divider(height: 1, indent: 16, endIndent: 16),
                        _DetailTile(
                          icon: Icons.monetization_on,
                          title: 'Fare',
                          value: '₱${data['fare'].toStringAsFixed(0)}',
                          valueColor: AppTheme.primaryGreen,
                        ),
                      ],
                      // Payment method
                      if (data['paymentMethod'] != null) ...[
                        const Divider(height: 1, indent: 16, endIndent: 16),
                        _DetailTile(
                          icon: Icons.payment,
                          title: 'Payment Method',
                          value: data['paymentMethod'] == 'gcash'
                              ? '📱 GCash'
                              : '💵 Cash',
                        ),
                      ],
                      // Payment status
                      if (data['paymentStatus'] != null) ...[
                        const Divider(height: 1, indent: 16, endIndent: 16),
                        _DetailTile(
                          icon: data['paymentStatus'] == 'paid'
                              ? Icons.check_circle
                              : Icons.pending,
                          title: 'Payment Status',
                          value: data['paymentStatus'] == 'paid'
                              ? '✅ Paid'
                              : '⏳ Pending',
                          valueColor: data['paymentStatus'] == 'paid'
                              ? AppTheme.success
                              : AppTheme.warning,
                        ),
                      ],
                      const Divider(height: 1, indent: 16, endIndent: 16),
                      _DetailTile(
                        icon: Icons.access_time_outlined,
                        title: 'Booked At',
                        value: formattedDate,
                      ),
                      if (formattedCompleted != null) ...[
                        const Divider(height: 1, indent: 16, endIndent: 16),
                        _DetailTile(
                          icon: Icons.check_circle_outline,
                          title: 'Completed At',
                          value: formattedCompleted,
                        ),
                      ],
                      const Divider(height: 1, indent: 16, endIndent: 16),
                      _DetailTile(
                        icon: Icons.info_outline,
                        title: 'Status',
                        value: status.toUpperCase(),
                        valueColor: _statusColor(status),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // Track button for active trips
                if (status == 'assigned' && widget.userRole == 'passenger')
                  ElevatedButton.icon(
                    onPressed: () => Navigator.pushNamed(
                      context,
                      AppRoutes.tripTracking,
                      arguments: {
                        'bookingId': widget.bookingId,
                        'driverName': driverName,
                        'terminalName': terminalName,
                      },
                    ),
                    icon: const Icon(Icons.my_location),
                    label: const Text('Track Driver'),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _DetailTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;
  final Color? valueColor;

  const _DetailTile({
    required this.icon,
    required this.title,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: AppTheme.primaryGreen),
      title: Text(
        title,
        style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
      ),
      subtitle: Text(
        value,
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w500,
          color: valueColor,
        ),
      ),
    );
  }
}

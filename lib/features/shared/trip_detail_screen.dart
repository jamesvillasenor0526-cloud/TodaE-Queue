import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import '../../config/theme.dart';
import '../../config/routes.dart';

class TripDetailScreen extends StatelessWidget {
  final String bookingId;
  final String userRole;

  const TripDetailScreen({
    super.key,
    required this.bookingId,
    required this.userRole,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Trip Details')),
      body: FutureBuilder<DocumentSnapshot>(
        future: FirebaseFirestore.instance
            .collection('bookings')
            .doc(bookingId)
            .get(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (!snapshot.hasData || !snapshot.data!.exists) {
            return const Center(child: Text('Trip not found.'));
          }

          final data = snapshot.data!.data() as Map<String, dynamic>;
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

          // The "other person" — who the current user wants to see
          final otherPersonId = userRole == 'passenger'
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

                      // Tappable other person row
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
                              (userRole == 'passenger'
                                  ? driverName
                                  : 'Passenger');
                          final isVerified = otherData?['isVerified'] ?? false;

                          return ListTile(
                            leading: Icon(
                              userRole == 'passenger'
                                  ? Icons.electric_rickshaw_outlined
                                  : Icons.person_outlined,
                              color: AppTheme.primaryGreen,
                            ),
                            title: Text(
                              userRole == 'passenger' ? 'Driver' : 'Passenger',
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.grey,
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
                                if (userRole == 'passenger' && isVerified) ...[
                                  const SizedBox(width: 4),
                                  const Icon(
                                    Icons.verified,
                                    color: Colors.green,
                                    size: 14,
                                  ),
                                ],
                              ],
                            ),
                            trailing: const Icon(
                              Icons.chevron_right,
                              color: Colors.grey,
                            ),
                            onTap: otherPersonId.isNotEmpty
                                ? () => Navigator.pushNamed(
                                    context,
                                    AppRoutes.userProfile,
                                    arguments: {
                                      'uid': otherPersonId,
                                      'viewerRole': userRole,
                                    },
                                  )
                                : null,
                          );
                        },
                      ),

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
                if (status == 'assigned' && userRole == 'passenger')
                  ElevatedButton.icon(
                    onPressed: () => Navigator.pushNamed(
                      context,
                      AppRoutes.tripTracking,
                      arguments: {
                        'bookingId': bookingId,
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

  Color _statusColor(String status) {
    return switch (status) {
      'assigned' => AppTheme.primaryBlue,
      'completed' => Colors.green,
      'cancelled' => Colors.grey,
      _ => Colors.grey,
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
        style: const TextStyle(fontSize: 12, color: Colors.grey),
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

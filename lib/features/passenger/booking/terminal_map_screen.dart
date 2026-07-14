import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../../../config/theme.dart';
import '../../../config/routes.dart';
import '../../../core/services/dispatch_service.dart';
import 'package:firebase_auth/firebase_auth.dart';

class TerminalMapScreen extends StatelessWidget {
  const TerminalMapScreen({super.key});

  static const LatLng _baliwagCenter = LatLng(14.9540, 120.9010);

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
    return Scaffold(
      appBar: AppBar(title: const Text('Terminal Map')),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance.collection('terminals').snapshots(),
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
                      final result = await showModalBottomSheet<DispatchResult>(
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

          return FlutterMap(
            options: const MapOptions(
              initialCenter: _baliwagCenter,
              initialZoom: 15,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.toda_equeue_plus',
              ),
              MarkerLayer(markers: markers),
            ],
          );
        },
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
                style: const TextStyle(color: Colors.grey),
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

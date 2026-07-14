import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../../../config/routes.dart';
import '../../../config/theme.dart';
import '../../../core/services/dispatch_service.dart';

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
            icon: const Icon(Icons.notifications_outlined),
            onPressed: () {},
          ),
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
            onPressed: () =>
                Navigator.pushNamed(context, AppRoutes.terminalMap),
            backgroundColor: AppTheme.primaryBlue,
            child: const Icon(Icons.map, color: Colors.white),
          ),
          const SizedBox(height: 12),
          FloatingActionButton.extended(
            heroTag: 'sos',
            onPressed: () => Navigator.pushNamed(context, AppRoutes.sos),
            backgroundColor: AppTheme.errorRed,
            icon: const Icon(Icons.sos, color: Colors.white),
            label: const Text('SOS', style: TextStyle(color: Colors.white)),
          ),
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
              // Active booking banner
              StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection('bookings')
                    .where('passengerId', isEqualTo: uid)
                    .where('status', isEqualTo: 'assigned')
                    .snapshots(),
                builder: (context, snapshot) {
                  final active = snapshot.data?.docs ?? [];
                  if (active.isEmpty) return const SizedBox.shrink();
                  final data = active.first.data() as Map<String, dynamic>;
                  return GestureDetector(
                    onTap: () {
                      final ctx = context;
                      Navigator.pushNamed(
                        ctx,
                        AppRoutes.tripTracking,
                        arguments: {
                          'bookingId': active.first.id,
                          'driverName': data['driverName'] ?? 'Driver',
                          'terminalName': data['terminalName'] ?? 'Terminal',
                        },
                      );
                    },
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      color: AppTheme.primaryBlue,
                      child: Row(
                        children: [
                          const Icon(
                            Icons.electric_rickshaw,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'You have an active trip!',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                Text(
                                  'Driver: ${data['driverName'] ?? 'Unknown'} • Tap to track',
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

              // Welcome header
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

              // Book a ride button
              Padding(
                padding: const EdgeInsets.all(16),
                child: ElevatedButton.icon(
                  onPressed: () => _showTerminalList(context),
                  icon: const Icon(Icons.electric_rickshaw),
                  label: const Text(
                    'Book a Ride',
                    style: TextStyle(fontSize: 16),
                  ),
                ),
              ),

              // Terminal list preview
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
                    return const Center(child: CircularProgressIndicator());
                  }
                  final terminals = snapshot.data?.docs ?? [];
                  if (terminals.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('No terminals available.'),
                    );
                  }
                  return ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: terminals.length,
                    itemBuilder: (context, index) {
                      final doc = terminals[index];
                      final data = doc.data() as Map<String, dynamic>;
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
                          subtitle: StreamBuilder<QuerySnapshot>(
                            stream: FirebaseFirestore.instance
                                .collection('queueEntries')
                                .where('terminalId', isEqualTo: doc.id)
                                .where('status', isEqualTo: 'waiting')
                                .snapshots(),
                            builder: (context, qSnapshot) {
                              final count = qSnapshot.data?.docs.length ?? 0;
                              return Text('$count driver(s) waiting');
                            },
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
              const SizedBox(height: 100), // padding for FABs
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
      builder: (_) => DraggableScrollableSheet(
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
                  final terminals = snapshot.data?.docs ?? [];
                  return ListView.builder(
                    controller: controller,
                    itemCount: terminals.length,
                    itemBuilder: (context, index) {
                      final doc = terminals[index];
                      final data = doc.data() as Map<String, dynamic>;
                      return ListTile(
                        leading: const Icon(
                          Icons.location_on,
                          color: AppTheme.primaryGreen,
                        ),
                        title: Text(data['name'] ?? 'Terminal'),
                        subtitle: StreamBuilder<QuerySnapshot>(
                          stream: FirebaseFirestore.instance
                              .collection('queueEntries')
                              .where('terminalId', isEqualTo: doc.id)
                              .where('status', isEqualTo: 'waiting')
                              .snapshots(),
                          builder: (context, qSnapshot) {
                            final count = qSnapshot.data?.docs.length ?? 0;
                            return Text('$count driver(s) waiting');
                          },
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          Navigator.pop(context);
                          _bookFromTerminal(
                            context,
                            doc.id,
                            data['name'] ?? 'Terminal',
                          );
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

  Future<void> _bookFromTerminal(
    BuildContext context,
    String terminalId,
    String terminalName,
  ) async {
    final result = await showModalBottomSheet<DispatchResult>(
      context: context,
      builder: (_) =>
          _TerminalSheet(name: terminalName, terminalId: terminalId),
    );

    if (result == null || !mounted) return;

    if (result.success) {
      showDialog(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Driver on the way! 🚖'),
          content: Text(
            '${result.driverName} has been dispatched to pick you up from $terminalName.',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                if (mounted) {
                  Navigator.pushNamed(
                    context,
                    AppRoutes.tripTracking,
                    arguments: {
                      'bookingId': result.bookingId ?? '',
                      'driverName': result.driverName ?? 'Driver',
                      'terminalName': terminalName,
                    },
                  );
                }
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
}

// ─── Terminal Sheet ──────────────────────────────────────────────────────────

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

// ─── History Tab ─────────────────────────────────────────────────────────────

class _HistoryTab extends StatelessWidget {
  const _HistoryTab();

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
          return const Center(child: CircularProgressIndicator());
        }
        final bookings = snapshot.data?.docs ?? [];
        if (bookings.isEmpty) {
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
          itemCount: bookings.length,
          itemBuilder: (context, index) {
            final data = bookings[index].data() as Map<String, dynamic>;
            final status = data['status'] ?? 'assigned';
            return Card(
              margin: const EdgeInsets.only(bottom: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: status == 'completed'
                      ? Colors.green
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
                          ? Colors.green
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

class _ProfileTab extends StatelessWidget {
  const _ProfileTab();

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    return FutureBuilder<DocumentSnapshot>(
      future: FirebaseFirestore.instance.collection('users').doc(uid).get(),
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
              child: CircleAvatar(
                radius: 48,
                backgroundColor: AppTheme.primaryGreen,
                child: Text(
                  (data?['name'] ?? 'P').toString().substring(0, 1),
                  style: const TextStyle(
                    fontSize: 36,
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Center(
              child: Text(
                data?['name'] ?? 'Passenger',
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            Center(
              child: Text(
                data?['email'] ?? '',
                style: const TextStyle(color: Colors.grey),
              ),
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
                    leading: const Icon(Icons.verified_user_outlined),
                    title: const Text('Role'),
                    subtitle: Text(data?['role'] ?? 'passenger'),
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
          ],
        );
      },
    );
  }
}

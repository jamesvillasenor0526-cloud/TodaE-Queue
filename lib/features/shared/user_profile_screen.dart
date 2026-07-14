import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../config/theme.dart';

class UserProfileScreen extends StatelessWidget {
  final String uid;
  final String viewerRole; // role of the person VIEWING

  const UserProfileScreen({
    super.key,
    required this.uid,
    required this.viewerRole,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: FutureBuilder<DocumentSnapshot>(
        future: FirebaseFirestore.instance.collection('users').doc(uid).get(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (!snapshot.hasData || !snapshot.data!.exists) {
            return const Center(child: Text('User not found.'));
          }

          final data = snapshot.data!.data() as Map<String, dynamic>;
          final role = data['role'] ?? 'passenger';
          final isVerified = data['isVerified'] ?? false;
          final name = data['name'] ?? 'Unknown';

          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                const SizedBox(height: 24),
                // Avatar
                Center(
                  child: Stack(
                    children: [
                      CircleAvatar(
                        radius: 52,
                        backgroundColor: role == 'driver'
                            ? AppTheme.primaryBlue
                            : AppTheme.primaryGreen,
                        child: Text(
                          name.substring(0, 1).toUpperCase(),
                          style: const TextStyle(
                            fontSize: 40,
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
                              size: 18,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // Name
                Text(
                  name,
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),

                // Role + verification badge
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: role == 'driver'
                        ? (isVerified
                              ? Colors.green.withValues(alpha: 0.1)
                              : Colors.orange.withValues(alpha: 0.1))
                        : AppTheme.primaryGreen.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    role == 'driver'
                        ? (isVerified
                              ? '✅ Verified Driver'
                              : '⏳ Pending Verification')
                        : '👤 Passenger',
                    style: TextStyle(
                      color: role == 'driver'
                          ? (isVerified ? Colors.green : Colors.orange)
                          : AppTheme.primaryGreen,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ),

                // Rating (drivers only)
                if (role == 'driver' && (data['averageRating'] ?? 0) > 0) ...[
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.star, color: Colors.amber, size: 20),
                      const SizedBox(width: 4),
                      Text(
                        '${data['averageRating']} (${data['totalRatings']} ratings)',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 32),

                // Info card
                Card(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _ProfileTile(
                        icon: Icons.phone_outlined,
                        title: 'Phone',
                        value: data['phone'] ?? 'N/A',
                      ),
                      if (role == 'passenger') ...[
                        const Divider(height: 1, indent: 16, endIndent: 16),
                        _ProfileTile(
                          icon: Icons.email_outlined,
                          title: 'Email',
                          value: data['email'] ?? 'N/A',
                        ),
                      ],
                      if (role == 'driver') ...[
                        const Divider(height: 1, indent: 16, endIndent: 16),
                        _ProfileTile(
                          icon: Icons.electric_rickshaw_outlined,
                          title: 'Plate Number',
                          value: data['plateNumber'] ?? 'N/A',
                        ),
                        const Divider(height: 1, indent: 16, endIndent: 16),
                        _ProfileTile(
                          icon: Icons.numbers_outlined,
                          title: 'Body Number',
                          value: data['bodyNumber'] ?? 'N/A',
                        ),
                        const Divider(height: 1, indent: 16, endIndent: 16),
                        _ProfileTile(
                          icon: Icons.badge_outlined,
                          title: 'ID Type',
                          value: data['idType'] ?? 'N/A',
                        ),
                        const Divider(height: 1, indent: 16, endIndent: 16),
                        _ProfileTile(
                          icon: Icons.numbers_outlined,
                          title: 'ID Number',
                          value: data['idNumber'] ?? 'N/A',
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ProfileTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;

  const _ProfileTile({
    required this.icon,
    required this.title,
    required this.value,
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
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
      ),
    );
  }
}

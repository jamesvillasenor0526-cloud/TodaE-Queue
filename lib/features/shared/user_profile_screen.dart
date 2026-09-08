import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../config/theme.dart';

class UserProfileScreen extends StatelessWidget {
  final String uid;
  final String viewerRole;

  const UserProfileScreen({
    super.key,
    required this.uid,
    required this.viewerRole,
  });

  void _showRatingDetails(BuildContext context, Map<String, dynamic> data) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('ratings')
            .where('driverId', isEqualTo: uid)
            .orderBy('createdAt', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          final ratings = snapshot.data?.docs ?? [];
          return Container(
            padding: const EdgeInsets.all(24),
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.5,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Ratings for ${data['name'] ?? 'Driver'}',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                if (ratings.isEmpty)
                  const Center(child: Text('No ratings yet.'))
                else
                  Expanded(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: ratings.length,
                      itemBuilder: (context, index) {
                        final r = ratings[index].data() as Map<String, dynamic>;
                        final stars = r['rating'] ?? 0;
                        final comment = r['comment'] ?? '';
                        final date =
                            (r['createdAt'] as Timestamp?)
                                ?.toDate()
                                .toString()
                                .substring(0, 10) ??
                            '';
                        final passengerId = r['passengerId'] ?? '';

                        return Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    ...List.generate(
                                      5,
                                      (i) => Icon(
                                        i < stars
                                            ? Icons.star
                                            : Icons.star_border,
                                        color: Colors.amber,
                                        size: 18,
                                      ),
                                    ),
                                    const Spacer(),
                                    Text(
                                      date,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: AppTheme.textMuted,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                FutureBuilder<DocumentSnapshot>(
                                  future: FirebaseFirestore.instance
                                      .collection('users')
                                      .doc(passengerId)
                                      .get(),
                                  builder: (context, userSnap) {
                                    final passengerName =
                                        userSnap.data?['name'] ?? 'Passenger';
                                    return Text(
                                      'by $passengerName',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: AppTheme.textMuted,
                                        fontStyle: FontStyle.italic,
                                      ),
                                    );
                                  },
                                ),
                                if (comment.isNotEmpty) ...[
                                  const SizedBox(height: 6),
                                  Text(
                                    comment,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      color: AppTheme.textMuted,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance
            .collection('users')
            .doc(uid)
            .snapshots(),
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
                Center(
                  child: Stack(
                    children: [
                      CircleAvatar(
                        radius: 52,
                        backgroundColor: role == 'driver'
                            ? AppTheme.primaryBlue
                            : AppTheme.primaryGreen,
                        backgroundImage: data['profilePhotoUrl'] != null
                            ? NetworkImage(data['profilePhotoUrl'])
                            : null,
                        child: data['profilePhotoUrl'] == null
                            ? Text(
                                name.substring(0, 1).toUpperCase(),
                                style: const TextStyle(
                                  fontSize: 40,
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                              )
                            : null,
                      ),
                      if (isVerified)
                        Positioned(
                          bottom: 0,
                          right: 0,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: const BoxDecoration(
                              color: AppTheme.success,
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
                Text(
                  name,
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
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
                          ? (isVerified ? AppTheme.success : AppTheme.warning)
                          : AppTheme.primaryGreen,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ),
                if (role == 'driver' && (data['averageRating'] ?? 0) > 0) ...[
                  const SizedBox(height: 8),
                  GestureDetector(
                    onTap: () => _showRatingDetails(context, data),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.star, color: Colors.amber, size: 20),
                        const SizedBox(width: 4),
                        Text(
                          '${data['averageRating']} (${data['totalRatings']} ratings)',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                        const Icon(
                          Icons.chevron_right,
                          size: 16,
                          color: AppTheme.textMuted,
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 32),
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
        style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
      ),
      subtitle: Text(
        value,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
      ),
    );
  }
}

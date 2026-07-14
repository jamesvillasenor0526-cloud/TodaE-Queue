import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../config/routes.dart';
import '../../../config/theme.dart';
import 'dart:io';
import 'face_verification_screen.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  String _idTypeLabel(String type) {
    return switch (type) {
      'drivers_license' => "Driver's License",
      'voters_id' => "Voter's ID",
      'philsys' => "PhilSys ID",
      'passport' => "Passport",
      'postal_id' => "Postal ID",
      _ => "ID",
    };
  }

  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _isLoading = false;
  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  String _selectedRole = 'passenger';
  String _selectedIdType = 'drivers_license';
  final _plateController = TextEditingController();
  final _bodyNumberController = TextEditingController();
  final _licenseController = TextEditingController();
  File? _selfieFile;
  File? _idPhotoFile;
  String? _selectedTerminalId;
  String? _selectedTerminalName;
  String? _errorMessage;

  @override
  void dispose() {
    _plateController.dispose();
    _bodyNumberController.dispose();
    _licenseController.dispose();
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _plateController.dispose();
    _bodyNumberController.dispose();
    _licenseController.dispose();
    super.dispose();
  }

  Future<void> _register() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final credential = await FirebaseAuth.instance
          .createUserWithEmailAndPassword(
            email: _emailController.text.trim(),
            password: _passwordController.text.trim(),
          );

      // Save user data to Firestore
      await FirebaseFirestore.instance
          .collection('users')
          .doc(credential.user!.uid)
          .set({
            'uid': credential.user!.uid,
            'name': _nameController.text.trim(),
            'email': _emailController.text.trim(),
            'phone': _phoneController.text.trim(),
            'role': _selectedRole,
            'createdAt': FieldValue.serverTimestamp(),
            'isVerified': false,
            'isActive': true,
            'verificationStatus': _selectedRole == 'passenger'
                ? 'approved'
                : 'pending',
            if (_selectedRole == 'driver') ...{
              'plateNumber': _plateController.text.trim(),
              'bodyNumber': _bodyNumberController.text.trim(),
              'idType': _selectedIdType,
              'idNumber': _licenseController.text.trim(),
              'hasSelfie': _selfieFile != null,
              'hasIdPhoto': _idPhotoFile != null,
              'assignedTerminalId': _selectedTerminalId,
              'assignedTerminalName': _selectedTerminalName,
            },
          });

      if (mounted) {
        Navigator.pushReplacementNamed(context, AppRoutes.roleSelect);
      }
    } on FirebaseAuthException catch (e) {
      setState(() {
        _errorMessage = switch (e.code) {
          'email-already-in-use' =>
            'An account already exists with this email.',
          'invalid-email' => 'Invalid email address.',
          'weak-password' => 'Password must be at least 6 characters.',
          _ => 'Registration failed. Please try again.',
        };
      });
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Create Account'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Join TODA E-QUEUE+',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                const Text(
                  'Create your account to get started',
                  style: TextStyle(color: Colors.grey),
                ),
                const SizedBox(height: 32),

                // Error message
                if (_errorMessage != null)
                  Container(
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: AppTheme.errorRed.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppTheme.errorRed),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.error_outline,
                          color: AppTheme.errorRed,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _errorMessage!,
                            style: const TextStyle(color: AppTheme.errorRed),
                          ),
                        ),
                      ],
                    ),
                  ),

                // Role selector
                const Text(
                  'I am a...',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _RoleCard(
                        icon: Icons.person,
                        label: 'Passenger',
                        selected: _selectedRole == 'passenger',
                        onTap: () =>
                            setState(() => _selectedRole = 'passenger'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _RoleCard(
                        icon: Icons.electric_rickshaw,
                        label: 'Driver',
                        selected: _selectedRole == 'driver',
                        onTap: () => setState(() => _selectedRole = 'driver'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                // Full name
                TextFormField(
                  controller: _nameController,
                  decoration: const InputDecoration(
                    labelText: 'Full Name',
                    prefixIcon: Icon(Icons.person_outlined),
                  ),
                  validator: (v) => v == null || v.isEmpty
                      ? 'Please enter your full name'
                      : null,
                ),
                const SizedBox(height: 16),

                // Email
                TextFormField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    prefixIcon: Icon(Icons.email_outlined),
                  ),
                  validator: (v) =>
                      v == null || v.isEmpty ? 'Please enter your email' : null,
                ),
                const SizedBox(height: 16),

                // Phone
                TextFormField(
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Phone Number',
                    prefixIcon: Icon(Icons.phone_outlined),
                  ),
                  validator: (v) => v == null || v.isEmpty
                      ? 'Please enter your phone number'
                      : null,
                ),
                const SizedBox(height: 16),

                // Password
                TextFormField(
                  controller: _passwordController,
                  obscureText: _obscurePassword,
                  decoration: InputDecoration(
                    labelText: 'Password',
                    prefixIcon: const Icon(Icons.lock_outlined),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                      onPressed: () =>
                          setState(() => _obscurePassword = !_obscurePassword),
                    ),
                  ),
                  validator: (v) {
                    if (v == null || v.isEmpty) {
                      return 'Please enter a password';
                    }
                    if (v.length < 6) {
                      return 'Password must be at least 6 characters';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                // Driver-specific fields
                if (_selectedRole == 'driver') ...[
                  const SizedBox(height: 16),
                  const Divider(),
                  const SizedBox(height: 8),
                  const Text(
                    'Vehicle Information',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _plateController,
                    decoration: const InputDecoration(
                      labelText: 'Plate Number',
                      prefixIcon: Icon(Icons.numbers_outlined),
                    ),
                    validator: (v) =>
                        _selectedRole == 'driver' && (v == null || v.isEmpty)
                        ? 'Please enter plate number'
                        : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _bodyNumberController,
                    decoration: const InputDecoration(
                      labelText: 'Body Number',
                      prefixIcon: Icon(Icons.electric_rickshaw_outlined),
                    ),
                    validator: (v) =>
                        _selectedRole == 'driver' && (v == null || v.isEmpty)
                        ? 'Please enter body number'
                        : null,
                  ),
                  const SizedBox(height: 16),
                  // ID Type selector
                  const Text(
                    'Valid ID Type',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    value: _selectedIdType,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.badge_outlined),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'drivers_license',
                        child: Text("Driver's License"),
                      ),
                      DropdownMenuItem(
                        value: 'voters_id',
                        child: Text("Voter's ID"),
                      ),
                      DropdownMenuItem(
                        value: 'philsys',
                        child: Text("PhilSys ID"),
                      ),
                      DropdownMenuItem(
                        value: 'passport',
                        child: Text("Passport"),
                      ),
                      DropdownMenuItem(
                        value: 'postal_id',
                        child: Text("Postal ID"),
                      ),
                    ],
                    onChanged: (v) => setState(
                      () => _selectedIdType = v ?? 'drivers_license',
                    ),
                    validator: (v) =>
                        v == null ? 'Please select an ID type' : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _licenseController,
                    decoration: InputDecoration(
                      labelText: _selectedIdType == 'drivers_license'
                          ? 'License Number'
                          : 'ID Number',
                      prefixIcon: const Icon(Icons.numbers_outlined),
                      helperText: _selectedIdType == 'drivers_license'
                          ? null
                          : 'Enter your ${_idTypeLabel(_selectedIdType)} number',
                    ),
                    validator: (v) =>
                        _selectedRole == 'driver' && (v == null || v.isEmpty)
                        ? 'Please enter your ID number'
                        : null,
                  ),
                  const SizedBox(height: 16),
                  // Assigned Terminal
                  const SizedBox(height: 16),
                  const Text(
                    'Assigned Terminal',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
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
                        return const Text(
                          'No terminals available. Please contact your TODA officer.',
                          style: TextStyle(color: Colors.red, fontSize: 12),
                        );
                      }
                      return DropdownButtonFormField<String>(
                        value: _selectedTerminalId,
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.location_on_outlined),
                          hintText: 'Select your terminal',
                        ),
                        items: terminals.map((doc) {
                          final data = doc.data() as Map<String, dynamic>;
                          return DropdownMenuItem<String>(
                            value: doc.id,
                            child: Text(data['name'] ?? 'Terminal'),
                          );
                        }).toList(),
                        onChanged: (v) {
                          if (v == null) return;
                          final doc = terminals.firstWhere((d) => d.id == v);
                          final data = doc.data() as Map<String, dynamic>;
                          setState(() {
                            _selectedTerminalId = v;
                            _selectedTerminalName = data['name'];
                          });
                        },
                        validator: (v) => _selectedRole == 'driver' && v == null
                            ? 'Please select your assigned terminal'
                            : null,
                      );
                    },
                  ),
                  const SizedBox(height: 16),
                  // Face verification
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: _selfieFile != null && _idPhotoFile != null
                          ? Colors.green.withValues(alpha: 0.1)
                          : Colors.orange.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: _selfieFile != null && _idPhotoFile != null
                            ? Colors.green
                            : Colors.orange,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              _selfieFile != null && _idPhotoFile != null
                                  ? Icons.verified_user
                                  : Icons.face,
                              color: _selfieFile != null && _idPhotoFile != null
                                  ? Colors.green
                                  : Colors.orange,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _selfieFile != null && _idPhotoFile != null
                                  ? 'Verification photos captured ✅'
                                  : 'Identity Verification Required',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color:
                                    _selfieFile != null && _idPhotoFile != null
                                    ? Colors.green
                                    : Colors.orange,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Take a selfie and a photo of your Driver\'s License for verification.',
                          style: TextStyle(color: Colors.grey, fontSize: 12),
                        ),
                        const SizedBox(height: 12),
                        ElevatedButton.icon(
                          onPressed: () async {
                            final result =
                                await Navigator.push<Map<String, dynamic>>(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        const FaceVerificationScreen(),
                                  ),
                                );
                            if (result != null) {
                              setState(() {
                                _selfieFile = result['selfie'] as File?;
                                _idPhotoFile = result['idPhoto'] as File?;
                              });
                            }
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.orange,
                          ),
                          icon: const Icon(Icons.camera_alt),
                          label: Text(
                            _selfieFile != null
                                ? 'Retake Photos'
                                : 'Start Verification',
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],

                // Confirm password
                TextFormField(
                  controller: _confirmPasswordController,
                  obscureText: _obscureConfirm,
                  decoration: InputDecoration(
                    labelText: 'Confirm Password',
                    prefixIcon: const Icon(Icons.lock_outlined),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscureConfirm
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                      onPressed: () =>
                          setState(() => _obscureConfirm = !_obscureConfirm),
                    ),
                  ),
                  validator: (v) {
                    if (v == null || v.isEmpty) {
                      return 'Please confirm your password';
                    }
                    if (v != _passwordController.text) {
                      return 'Passwords do not match';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 32),

                // Register button
                ElevatedButton(
                  onPressed: _isLoading ? null : _register,
                  child: _isLoading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            color: AppTheme.white,
                            strokeWidth: 2,
                          ),
                        )
                      : const Text(
                          'Create Account',
                          style: TextStyle(fontSize: 16),
                        ),
                ),
                const SizedBox(height: 16),

                // Login link
                Center(
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text.rich(
                      TextSpan(
                        text: 'Already have an account? ',
                        style: TextStyle(color: Colors.grey),
                        children: [
                          TextSpan(
                            text: 'Sign In',
                            style: TextStyle(
                              color: AppTheme.primaryGreen,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RoleCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _RoleCard({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.primaryGreen.withValues(alpha: 0.1)
              : AppTheme.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? AppTheme.primaryGreen : Colors.grey.shade300,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            Icon(
              icon,
              size: 32,
              color: selected ? AppTheme.primaryGreen : Colors.grey,
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: selected ? AppTheme.primaryGreen : Colors.grey,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../config/routes.dart';
import '../../../config/theme.dart';
import 'dart:io';
import 'simple_camera_screen.dart';
import '../../../core/services/cloudinary_service.dart';
import '../../../core/services/contact_service.dart';
import 'package:flutter/services.dart';

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
  String? _locationAddress;
  bool _agreedToTerms = false;

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
    super.dispose();
  }

  Widget _buildPasswordRequirement(bool isMet, String requirement) {
    return Row(
      children: [
        Icon(
          isMet ? Icons.check_circle : Icons.cancel,
          size: 14,
          color: isMet ? AppTheme.success : AppTheme.errorRed,
        ),
        const SizedBox(width: 6),
        Text(
          requirement,
          style: TextStyle(
            fontSize: 11,
            color: isMet ? AppTheme.success : AppTheme.errorRed,
            fontWeight: isMet ? FontWeight.w500 : FontWeight.normal,
          ),
        ),
      ],
    );
  }

  void _showTermsDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(
          'Terms & Conditions',
          textAlign: TextAlign.center,
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'TODA E-QUEUE+',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.primaryGreen,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Terms and Conditions & Privacy Policy',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: AppTheme.textMuted),
                ),
                const SizedBox(height: 20),

                const Text(
                  '1. ACCEPTANCE OF TERMS',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                  'By registering and using TODA E-QUEUE+ (the "App"), you agree to be bound by these Terms and Conditions. If you do not agree, you must not use the App.',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),

                const Text(
                  '2. DESCRIPTION OF SERVICE',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                  'TODA E-QUEUE+ is a geo-fenced queue management, booking, and safety system for the Federation of Baliwag City TODA. Features include automated queue management, passenger booking, GPS trip tracking, fare calculation, and emergency SOS.',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),

                const Text(
                  '3. DRIVER RESPONSIBILITIES',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                  '• Provide valid identification documents\n'
                  '• Maintain a valid tricycle franchise\n'
                  '• Follow TODA regulations and city ordinances\n'
                  '• Stay within assigned terminal geofence when queuing\n'
                  '• Complete accepted bookings in a timely manner\n'
                  '• Honor the fare calculated by the system\n'
                  '• Maintain professional conduct at all times\n'
                  '• Report incidents or violations promptly',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),

                const Text(
                  '4. PASSENGER RESPONSIBILITIES',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                  '• Provide accurate booking information\n'
                  '• Be at the designated pickup location on time\n'
                  '• Pay the calculated fare upon trip completion\n'
                  '• Treat drivers with respect\n'
                  '• Use SOS feature only for genuine emergencies\n'
                  '• Not engage in fraudulent activities',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),

                const Text(
                  '5. FARE POLICY',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                  '• Minimum fare: ₱35.00 (first 1 kilometer)\n'
                  '• Additional: ₱10.00 per succeeding kilometer\n'
                  '• Fares calculated based on GPS road distance\n'
                  '• Payment accepted: Cash or GCash QR code\n'
                  '• Fares are non-negotiable',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),

                const Text(
                  '6. QUEUE MANAGEMENT',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                  '• Drivers must be within designated geofence to join queue\n'
                  '• Queue follows FIFO (First-In, First-Out) order\n'
                  '• Drivers who leave queue go to the back upon re-entry\n'
                  '• 20-minute cooldown applies after leaving queue\n'
                  '• Unverified drivers are not permitted in the queue',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),

                const Text(
                  '7. CANCELLATION POLICY',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                  '• Passengers may cancel before driver accepts\n'
                  '• Cancellation restricted after driver acceptance\n'
                  '• Repeated cancellations may result in restrictions\n'
                  '• Drivers who cancel without valid reason face penalties',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),

                const Text(
                  '8. PRIVACY POLICY',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Information We Collect:\n'
                  '• Name, email, phone number\n'
                  '• GPS location during active trips\n'
                  '• Profile photos and verification documents\n'
                  '• Trip history and payment records\n'
                  '• Ratings and feedback',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'How We Use Your Information:\n'
                  '• To provide transportation services\n'
                  '• To verify driver credentials\n'
                  '• To process bookings and payments\n'
                  '• To send important notifications\n'
                  '• To respond to SOS emergencies',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Data Protection:\n'
                  '• Data stored securely in Firebase Cloud Firestore\n'
                  '• Personal information never sold to third parties\n'
                  '• GPS only active during trips or queue participation\n'
                  '• Users may request data deletion',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),

                const Text(
                  '9. EMERGENCY FEATURES',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                  '• SOS button sends alert with location to TODA admin\n'
                  '• SOS should only be used in genuine emergencies\n'
                  '• Misuse may result in account suspension',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),

                const Text(
                  '10. RATING SYSTEM',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                  '• Passengers may rate drivers 1-5 stars\n'
                  '• Drivers may respond to ratings\n'
                  '• Ratings are visible to other users\n'
                  '• Continuous low ratings may affect privileges',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),

                const Text(
                  '11. LIMITATION OF LIABILITY',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                  'TODA E-QUEUE+ is a platform connecting drivers and passengers. We do not provide transportation services directly and are not liable for incidents during trips.',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),

                const Text(
                  '12. TERMINATION',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                  'We reserve the right to suspend accounts for violation of terms, fraudulent activity, or misuse of emergency features.',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),

                const Text(
                  '13. CONTACT',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Federation of Baliwag City TODA\n'
                  'Email: fedbaliwagtoda@gmail.com\n'
                  'Baliwag City Hall, Bulacan',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 16),

                const Center(
                  child: Text(
                    'By tapping "I Agree", you acknowledge that you have read, understood, and agree to be bound by these Terms and Conditions.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 11,
                      color: AppTheme.warning,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          ElevatedButton(
            onPressed: () {
              setState(() => _agreedToTerms = true);
              Navigator.pop(ctx);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryGreen,
            ),
            child: const Text('I Agree', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _showTerminalPicker(
    BuildContext context,
    List<QueryDocumentSnapshot> terminals,
  ) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => DraggableScrollableSheet(
        initialChildSize: 0.5,
        minChildSize: 0.3,
        maxChildSize: 0.8,
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
              'Select Your Terminal',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                controller: controller,
                itemCount: terminals.length,
                itemBuilder: (context, index) {
                  final doc = terminals[index];
                  final data = doc.data() as Map<String, dynamic>;
                  final isSelected = _selectedTerminalId == doc.id;

                  return ListTile(
                    leading: Icon(
                      isSelected ? Icons.check_circle : Icons.location_on,
                      color: isSelected
                          ? AppTheme.primaryGreen
                          : AppTheme.textMuted,
                    ),
                    title: Text(data['name'] ?? 'Terminal'),
                    trailing: isSelected
                        ? const Icon(Icons.check, color: AppTheme.primaryGreen)
                        : const Icon(Icons.chevron_right),
                    onTap: () {
                      setState(() {
                        _selectedTerminalId = doc.id;
                        _selectedTerminalName = data['name'];
                      });
                      Navigator.pop(sheetContext);
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

  Future<void> _register() async {
    if (!_formKey.currentState!.validate()) return;

    if (!_agreedToTerms) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please agree to the Terms and Conditions first.'),
          backgroundColor: AppTheme.warning,
        ),
      );
      return;
    }

    // Password rules (8 chars, 1 uppercase, 1 number) are enforced by the
    // field validator above via _formKey.validate(), and mirrored in the
    // live requirement checklist under the field.

    // Check if driver has verification photos
    if (_selectedRole == 'driver') {
      if (_selfieFile == null || _idPhotoFile == null) {
        setState(() {
          _errorMessage = 'Please take a selfie and ID photo for verification.';
        });
        return;
      }
    }

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

      final uid = credential.user!.uid;
      String? selfieUrl;
      String? idPhotoUrl;

      if (_selectedRole == 'driver') {
        if (_selfieFile != null) {
          try {
            selfieUrl = await CloudinaryService.instance.uploadImage(
              _selfieFile!,
              'driver_verification/$uid',
            );
          } catch (e) {
            debugPrint('Selfie upload error: $e');
          }
        }
        if (_idPhotoFile != null) {
          try {
            idPhotoUrl = await CloudinaryService.instance.uploadImage(
              _idPhotoFile!,
              'driver_verification/$uid',
            );
          } catch (e) {
            debugPrint('ID photo upload error: $e');
          }
        }
      }

      // The public half of the profile. Phone, email, ID photograph and
      // selfie are deliberately not here — they go to the private
      // subdocument below, which only this person and an admin can read.
      await FirebaseFirestore.instance.collection('users').doc(uid).set({
        'uid': uid,
        'name': _nameController.text.trim(),
        'locationAddress': _locationAddress ?? '',
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
          // Whether the documents were supplied is public — an admin's
          // list needs it — but the photographs themselves are not.
          'hasSelfie': _selfieFile != null,
          'hasIdPhoto': _idPhotoFile != null,
          'assignedTerminalId': _selectedTerminalId,
          'assignedTerminalName': _selectedTerminalName,
        },
      });

      // Phone, email and the identity photographs: readable by this person
      // and by the admins who verify them, and by nobody else.
      await ContactService.instance.save(
        uid,
        Contact(
          phone: _phoneController.text.trim(),
          email: _emailController.text.trim(),
          selfieUrl: selfieUrl,
          idPhotoUrl: idPhotoUrl,
        ),
      );

      // Send verification email
      // await credential.user!.sendEmailVerification();

      // Send verification email using Firebase default template
      await credential.user!.sendEmailVerification();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Account created! Check your email to verify.'),
            backgroundColor: AppTheme.success,
          ),
        );
        Navigator.pushReplacementNamed(context, AppRoutes.verifyEmail);
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
    } catch (e) {
      setState(() {
        _errorMessage = 'Registration failed: ${e.toString()}';
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
          tooltip: 'Back',
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: SafeArea(
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
                    style: TextStyle(color: AppTheme.textMuted),
                  ),
                  const SizedBox(height: 32),

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
                  TextFormField(
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: 'Email',
                      prefixIcon: Icon(Icons.email_outlined),
                    ),
                    validator: (v) {
                      if (v == null || v.isEmpty) {
                        return 'Please enter your email';
                      }
                      final emailRegex = RegExp(
                        r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$',
                      );
                      if (!emailRegex.hasMatch(v)) {
                        return 'Please enter a valid email address';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _phoneController,
                    keyboardType: TextInputType.phone,
                    maxLength: 11,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: 'Phone Number',
                      prefixIcon: Icon(Icons.phone_outlined),
                      counterText: '',
                    ),
                    validator: (v) {
                      if (v == null || v.isEmpty) {
                        return 'Please enter your phone number';
                      }
                      if (v.length != 11) {
                        return 'Phone number must be exactly 11 digits';
                      }
                      if (!RegExp(r'^[0-9]+$').hasMatch(v)) {
                        return 'Phone number must be numbers only';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  // Location Address
                  TextFormField(
                    decoration: const InputDecoration(
                      labelText: 'Location Address',
                      prefixIcon: Icon(Icons.home_outlined),
                      hintText: 'House no., street, barangay, city',
                    ),
                    validator: (v) => v == null || v.isEmpty
                        ? 'Please enter your location address'
                        : null,
                    onChanged: (v) => _locationAddress = v.trim(),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _passwordController,
                    obscureText: _obscurePassword,
                    onChanged: (v) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: 'Password',
                      prefixIcon: const Icon(Icons.lock_outlined),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscurePassword
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                        onPressed: () => setState(
                          () => _obscurePassword = !_obscurePassword,
                        ),
                      ),
                    ),
                    validator: (v) {
                      if (v == null || v.isEmpty) {
                        return 'Please enter a password';
                      }
                      if (v.length < 8) {
                        return 'Password must be at least 8 characters';
                      }
                      if (!RegExp(r'[A-Z]').hasMatch(v)) {
                        return 'Must contain at least 1 uppercase letter';
                      }
                      if (!RegExp(r'[0-9]').hasMatch(v)) {
                        return 'Must contain at least 1 number';
                      }
                      return null;
                    },
                  ),
                  if (_passwordController.text.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    const SizedBox(height: 4),
                    _buildPasswordRequirement(
                      _passwordController.text.length >= 8,
                      'At least 8 characters',
                    ),
                    const SizedBox(height: 2),
                    _buildPasswordRequirement(
                      RegExp(r'[A-Z]').hasMatch(_passwordController.text),
                      'At least 1 uppercase letter',
                    ),
                    const SizedBox(height: 2),
                    _buildPasswordRequirement(
                      RegExp(r'[0-9]').hasMatch(_passwordController.text),
                      'At least 1 number',
                    ),
                  ],
                  const SizedBox(height: 16),
                  if (_selectedRole == 'driver') ...[
                    const SizedBox(height: 16),
                    const Divider(),
                    const SizedBox(height: 8),
                    const Text(
                      'Vehicle Information',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
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
                      keyboardType: TextInputType.number,
                      maxLength: 4,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(4),
                      ],
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
                    const Text(
                      'Valid ID Type',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      initialValue: _selectedIdType,
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
                    const Text(
                      'Assigned Terminal',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 8),
                    StreamBuilder<QuerySnapshot>(
                      stream: FirebaseFirestore.instance
                          .collection('terminals')
                          .snapshots(),
                      builder: (context, snapshot) {
                        if (snapshot.connectionState ==
                            ConnectionState.waiting) {
                          return const Center(
                            child: CircularProgressIndicator(),
                          );
                        }
                        final terminals = snapshot.data?.docs ?? [];
                        if (terminals.isEmpty) {
                          return const Text(
                            'No terminals available.',
                            style: TextStyle(
                              color: AppTheme.errorRed,
                              fontSize: 12,
                            ),
                          );
                        }

                        return InkWell(
                          onTap: () => _showTerminalPicker(context, terminals),
                          child: InputDecorator(
                            decoration: const InputDecoration(
                              prefixIcon: Icon(Icons.location_on_outlined),
                              suffixIcon: Icon(Icons.arrow_drop_down),
                            ),
                            child: Text(
                              _selectedTerminalName ?? 'Select your terminal',
                              style: TextStyle(
                                fontSize: 16,
                                color: _selectedTerminalName != null
                                    ? Colors.black
                                    : AppTheme.textMuted,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: _selfieFile != null && _idPhotoFile != null
                            ? Colors.green.withValues(alpha: 0.1)
                            : Colors.orange.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: _selfieFile != null && _idPhotoFile != null
                              ? AppTheme.success
                              : AppTheme.errorRed,
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
                                color:
                                    _selfieFile != null && _idPhotoFile != null
                                    ? AppTheme.success
                                    : AppTheme.errorRed,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                _selfieFile != null && _idPhotoFile != null
                                    ? 'Verification photos captured ✅'
                                    : 'Identity Verification Required',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color:
                                      _selfieFile != null &&
                                          _idPhotoFile != null
                                      ? AppTheme.success
                                      : AppTheme.warning,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Take a selfie and a photo of your ID for verification.',
                            style: TextStyle(
                              color: AppTheme.textMuted,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 12),
                          ElevatedButton.icon(
                            onPressed: () async {
                              final result =
                                  await Navigator.push<Map<String, dynamic>>(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          const SimpleCameraScreen(),
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
                              backgroundColor: AppTheme.warning,
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
                  // Terms and Conditions
                  Row(
                    children: [
                      Checkbox(
                        value: _agreedToTerms,
                        onChanged: (v) =>
                            setState(() => _agreedToTerms = v ?? false),
                        activeColor: AppTheme.primaryGreen,
                      ),
                      Expanded(
                        child: GestureDetector(
                          onTap: () => _showTermsDialog(context),
                          child: const Text(
                            'I agree to the Terms and Conditions and Privacy Policy',
                            style: TextStyle(
                              fontSize: 13,
                              color: AppTheme.primaryGreen,
                              decoration: TextDecoration.underline,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: (_isLoading || !_agreedToTerms)
                          ? null
                          : _register,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primaryGreen,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        disabledBackgroundColor: Colors.grey.shade300,
                        disabledForegroundColor: Colors.grey.shade500,
                      ),
                      child: _isLoading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2,
                              ),
                            )
                          : const Text(
                              'Create Account',
                              style: TextStyle(
                                fontSize: 16,
                                color: Colors.white,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Center(
                    child: TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text.rich(
                        TextSpan(
                          text: 'Already have an account? ',
                          style: TextStyle(color: AppTheme.textMuted),
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
              color: selected ? AppTheme.primaryGreen : AppTheme.textMuted,
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: selected ? AppTheme.primaryGreen : AppTheme.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The whole app for a rejected driver: why they were turned down, and the
/// form to put it right.
///
/// One screen, not a tab among five. A rejected driver cannot queue, take
/// trips or be seen by passengers, so the queue, map and history have
/// nothing to say to them — this is the only thing they can act on, and
/// they are sent straight here at sign-in.
///
/// Before this, a rejection was a dead end: "contact your TODA admin", no
/// reason, nothing to correct. Sending moves the account back to pending;
/// approving is still only the admin's to do (see `resubmits()` in the
/// security rules).
library;

import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../config/routes.dart';
import '../../../config/theme.dart';
import '../../../core/services/cloudinary_service.dart';
import '../../../core/services/contact_service.dart';
import '../../auth/screens/simple_camera_screen.dart';

/// The IDs a driver can register with, as registration offers them.
const Map<String, String> kIdTypes = {
  'drivers_license': "Driver's License",
  'voters_id': "Voter's ID",
  'philsys': 'PhilSys ID',
  'passport': 'Passport',
  'postal_id': 'Postal ID',
};

class ResubmitScreen extends StatefulWidget {
  const ResubmitScreen({super.key, required this.profile});

  /// The driver's profile as it stands, rejection reason included.
  final Map<String, dynamic> profile;

  @override
  State<ResubmitScreen> createState() => _ResubmitScreenState();
}

class _ResubmitScreenState extends State<ResubmitScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: _s('name'));
  late final _plate = TextEditingController(text: _s('plateNumber'));
  late final _body = TextEditingController(text: _s('bodyNumber'));
  late final _idNumber = TextEditingController(text: _s('idNumber'));
  late String _idType = kIdTypes.containsKey(_s('idType'))
      ? _s('idType')
      : 'drivers_license';

  File? _selfie;
  File? _idPhoto;
  bool _sending = false;
  String? _error;

  String _s(String key) => (widget.profile[key] as String?)?.trim() ?? '';

  @override
  void dispose() {
    _name.dispose();
    _plate.dispose();
    _body.dispose();
    _idNumber.dispose();
    super.dispose();
  }

  Future<void> _retakePhotos() async {
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(builder: (_) => const SimpleCameraScreen()),
    );
    if (result == null || !mounted) return;
    setState(() {
      _selfie = result['selfie'] as File? ?? _selfie;
      _idPhoto = result['idPhoto'] as File? ?? _idPhoto;
    });
  }

  Future<void> _send() async {
    if (!_formKey.currentState!.validate()) return;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      // New photos first. If one will not upload, stop here: sending the
      // details back without the photo the admin asked for would only be
      // rejected again.
      String? selfieUrl;
      String? idPhotoUrl;
      if (_selfie != null) {
        selfieUrl = await CloudinaryService.instance.uploadImage(
          _selfie!,
          'driver_verification/$uid',
        );
        if (selfieUrl == null) throw 'The selfie did not upload.';
      }
      if (_idPhoto != null) {
        idPhotoUrl = await CloudinaryService.instance.uploadImage(
          _idPhoto!,
          'driver_verification/$uid',
        );
        if (idPhotoUrl == null) throw 'The ID photo did not upload.';
      }
      if (selfieUrl != null || idPhotoUrl != null) {
        await ContactService.instance.save(
          uid,
          Contact(selfieUrl: selfieUrl, idPhotoUrl: idPhotoUrl),
        );
      }

      await FirebaseFirestore.instance.collection('users').doc(uid).update({
        'name': _name.text.trim().replaceAll(RegExp(r'\s+'), ' '),
        'plateNumber': _plate.text.trim(),
        'bodyNumber': _body.text.trim(),
        'idType': _idType,
        'idNumber': _idNumber.text.trim(),
        if (selfieUrl != null) 'hasSelfie': true,
        if (idPhotoUrl != null) 'hasIdPhoto': true,
        'verificationStatus': 'pending',
        'resubmittedAt': FieldValue.serverTimestamp(),
      });

      if (!mounted) return;
      // Pending now: the ordinary driver home says so while they wait.
      Navigator.pushNamedAndRemoveUntil(
        context,
        AppRoutes.driverHome,
        (_) => false,
      );
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Sent. Your TODA admin will review it again.'),
        ),
      );
    } catch (e) {
      debugPrint('Resubmit failed: $e');
      if (mounted) {
        setState(
          () => _error = e is String
              ? '$e Check your connection and try again.'
              : 'Could not send your details. Check your connection and '
                    'try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  String? _required(String? v, String what) =>
      (v == null || v.trim().isEmpty) ? 'Enter your $what' : null;

  @override
  Widget build(BuildContext context) {
    final reason = _s('rejectionReason');
    // Back would quietly close the app from here, since this screen
    // replaced the whole stack. Say what the ways out are instead.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Send your details for review, or sign out from the top right.',
            ),
          ),
        );
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Registration not approved'),
          automaticallyImplyLeading: false,
          actions: [
            IconButton(
              tooltip: 'Sign out',
              onPressed: () async {
                await FirebaseAuth.instance.signOut();
                if (context.mounted) {
                  Navigator.pushNamedAndRemoveUntil(
                    context,
                    AppRoutes.login,
                    (_) => false,
                  );
                }
              },
              icon: const Icon(Icons.logout),
            ),
          ],
        ),
        body: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Center(
                child: Column(
                  children: [
                    Image.asset(
                      'assets/images/toda_equeue_plus_logo.png',
                      height: 72,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'TODA E-QUEUE+',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              // What the admin said — it is the point of this screen.
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppTheme.errorRed.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: AppTheme.errorRed.withValues(alpha: 0.3),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.info_outline, color: AppTheme.errorRed),
                        SizedBox(width: 8),
                        Text(
                          'Why your registration was rejected',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      reason.isEmpty
                          ? 'Your TODA admin did not give a reason. Check your '
                                'details and photos, or ask them.'
                          : reason,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              TextFormField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Full name, as on your ID',
                  prefixIcon: Icon(Icons.person_outlined),
                ),
                validator: (v) => _required(v, 'full name'),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _plate,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: 'Plate Number',
                  prefixIcon: Icon(Icons.numbers_outlined),
                ),
                validator: (v) => _required(v, 'plate number'),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _body,
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
                validator: (v) => _required(v, 'body number'),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: _idType,
                decoration: const InputDecoration(
                  labelText: 'Valid ID Type',
                  prefixIcon: Icon(Icons.badge_outlined),
                ),
                items: [
                  for (final e in kIdTypes.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: (v) => setState(() => _idType = v ?? _idType),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _idNumber,
                decoration: InputDecoration(
                  labelText: _idType == 'drivers_license'
                      ? 'License Number'
                      : 'ID Number',
                  prefixIcon: const Icon(Icons.numbers_outlined),
                ),
                validator: (v) => _required(v, 'ID number'),
              ),
              const SizedBox(height: 24),
              // Photos: optional. Retake them only if the reason is about them
              // — otherwise the ones already sent are kept.
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.grey.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Selfie and ID photo',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _selfie != null || _idPhoto != null
                          ? 'New photos taken — they replace the old ones when '
                                'you send.'
                          : 'Your current photos are kept. Retake them if the '
                                'reason is about your photos.',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppTheme.textMuted,
                      ),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: _sending ? null : _retakePhotos,
                      icon: const Icon(Icons.camera_alt_outlined),
                      label: Text(
                        _selfie != null || _idPhoto != null
                            ? 'Retake again'
                            : 'Retake selfie and ID',
                      ),
                    ),
                  ],
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(_error!, style: const TextStyle(color: AppTheme.errorRed)),
              ],
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _sending ? null : _send,
                icon: _sending
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.send),
                label: Text(_sending ? 'Sending…' : 'Send for review'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryGreen,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

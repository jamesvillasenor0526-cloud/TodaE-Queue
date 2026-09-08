import 'dart:io';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import '../../../config/theme.dart';
import '../../../core/services/cloudinary_service.dart';

class SendTicketScreen extends StatefulWidget {
  const SendTicketScreen({super.key});

  @override
  State<SendTicketScreen> createState() => _SendTicketScreenState();
}

class _SendTicketScreenState extends State<SendTicketScreen> {
  final _subjectController = TextEditingController();
  final _descriptionController = TextEditingController();
  File? _screenshotFile;
  bool _isSending = false;

  @override
  void dispose() {
    _subjectController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1200,
      maxHeight: 1200,
      imageQuality: 80,
    );

    if (pickedFile != null) {
      setState(() => _screenshotFile = File(pickedFile.path));
    }
  }

  Future<void> _sendTicket() async {
    if (_subjectController.text.trim().isEmpty ||
        _descriptionController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill in subject and description')),
      );
      return;
    }

    setState(() => _isSending = true);

    try {
      final user = FirebaseAuth.instance.currentUser!;
      String? screenshotUrl;

      // Upload screenshot if provided
      if (_screenshotFile != null) {
        screenshotUrl = await CloudinaryService.instance.uploadImage(
          _screenshotFile!,
          'tickets/${user.uid}',
        );
      }

      // Save ticket to Firestore
      await FirebaseFirestore.instance.collection('tickets').add({
        'userId': user.uid,
        'userName': user.displayName ?? 'User',
        'subject': _subjectController.text.trim(),
        'description': _descriptionController.text.trim(),
        'screenshotUrl': screenshotUrl,
        'status': 'open',
        'createdAt': FieldValue.serverTimestamp(),
      });

      if (mounted) {
        setState(() => _isSending = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ Ticket sent! Admin will review it.'),
            backgroundColor: AppTheme.success,
          ),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSending = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to send ticket: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Send Ticket / Report Issue')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Report a Problem',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            const Text(
              'Describe the issue you\'re experiencing. Attach a screenshot if possible.',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 13),
            ),
            const SizedBox(height: 24),

            // Subject
            TextField(
              controller: _subjectController,
              decoration: const InputDecoration(
                labelText: 'Subject',
                prefixIcon: Icon(Icons.title),
                hintText: 'e.g., App crashes when booking',
              ),
            ),
            const SizedBox(height: 16),

            // Description
            TextField(
              controller: _descriptionController,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: 'Description',
                prefixIcon: Icon(Icons.description_outlined),
                hintText: 'Describe the issue in detail...',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 24),

            // Screenshot
            const Text(
              'Screenshot (Optional)',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: _pickImage,
              child: Container(
                width: double.infinity,
                height: 150,
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.grey.shade300,
                    style: BorderStyle.solid,
                  ),
                ),
                child: _screenshotFile != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.file(_screenshotFile!, fit: BoxFit.cover),
                      )
                    : const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.add_photo_alternate,
                            size: 48,
                            color: AppTheme.textMuted,
                          ),
                          SizedBox(height: 8),
                          Text(
                            'Tap to add screenshot',
                            style: TextStyle(color: AppTheme.textMuted),
                          ),
                        ],
                      ),
              ),
            ),
            if (_screenshotFile != null) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () => setState(() => _screenshotFile = null),
                icon: const Icon(Icons.delete, size: 16),
                label: const Text('Remove Screenshot'),
              ),
            ],
            const SizedBox(height: 24),

            // Submit button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _isSending ? null : _sendTicket,
                icon: _isSending
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.send),
                label: Text(_isSending ? 'Sending...' : 'Send Ticket'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryGreen,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

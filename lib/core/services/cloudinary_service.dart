import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

class CloudinaryService {
  static final CloudinaryService instance = CloudinaryService._();
  CloudinaryService._();

  static const String _cloudName = 'exx6kxvz';
  static const String _uploadPreset = 'toda_equeue_preset';

  Future<String?> uploadImage(File imageFile, String folder) async {
    try {
      final uri = Uri.parse(
        'https://api.cloudinary.com/v1_1/$_cloudName/image/upload',
      );

      final request = http.MultipartRequest('POST', uri)
        ..fields['upload_preset'] = _uploadPreset
        ..fields['folder'] = folder
        ..files.add(await http.MultipartFile.fromPath('file', imageFile.path));

      // A photo upload with no limit meant registration could sit on a
      // spinner indefinitely on a weak connection, with no way back.
      final response = await request.send().timeout(
        const Duration(seconds: 45),
      );
      final responseData = await response.stream.bytesToString();
      final jsonResponse = json.decode(responseData);

      if (response.statusCode == 200) {
        debugPrint(
          'Cloudinary upload success: ${jsonResponse['secure_url']}',
        );
        return jsonResponse['secure_url'];
      }
      debugPrint('Cloudinary upload failed: $responseData');
      return null;
    } catch (e) {
      debugPrint('Cloudinary upload error: $e');
      return null;
    }
  }
}

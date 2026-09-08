import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import '../../../config/theme.dart';

class SimpleCameraScreen extends StatefulWidget {
  const SimpleCameraScreen({super.key});

  @override
  State<SimpleCameraScreen> createState() => _SimpleCameraScreenState();
}

class _SimpleCameraScreenState extends State<SimpleCameraScreen> {
  CameraController? _controller;
  List<CameraDescription>? _cameras;
  File? _selfieFile;
  File? _idFile;
  String _status = 'Take a selfie for verification';
  int _step = 1; // 1 = selfie, 2 = ID photo
  bool _isCapturing = false;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    _cameras = await availableCameras();
    if (_cameras == null || _cameras!.isEmpty) return;

    // Use front camera for selfie
    final frontCamera = _cameras!.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => _cameras!.first,
    );

    _controller = CameraController(
      frontCamera,
      ResolutionPreset.medium,
      enableAudio: false,
    );

    await _controller!.initialize();
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _captureSelfie() async {
    if (_controller == null || _isCapturing) return;
    setState(() => _isCapturing = true);

    try {
      final photo = await _controller!.takePicture();
      setState(() {
        _selfieFile = File(photo.path);
        _step = 2;
        _status = 'Now take a photo of your ID';
        _isCapturing = false;
      });

      // Switch to back camera
      await _controller!.dispose();
      final backCamera = _cameras!.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => _cameras!.first,
      );
      _controller = CameraController(
        backCamera,
        ResolutionPreset.medium,
        enableAudio: false,
      );
      await _controller!.initialize();
      if (mounted) setState(() {});
    } catch (e) {
      setState(() => _isCapturing = false);
      _status = 'Error: $e';
    }
  }

  Future<void> _captureID() async {
    if (_controller == null || _isCapturing) return;
    setState(() => _isCapturing = true);

    try {
      final photo = await _controller!.takePicture();
      setState(() {
        _idFile = File(photo.path);
        _isCapturing = false;
      });
    } catch (e) {
      setState(() => _isCapturing = false);
      _status = 'Error: $e';
    }
  }

  void _submit() {
    if (_selfieFile == null || _idFile == null) return;
    Navigator.pop(context, {'selfie': _selfieFile, 'idPhoto': _idFile});
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(
          _step == 1 ? 'Step 1: Take a Selfie' : 'Step 2: Capture ID',
          style: const TextStyle(color: Colors.white),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Column(
        children: [
          LinearProgressIndicator(
            value: _step == 1 ? 0.5 : 1.0,
            backgroundColor: Colors.grey.shade800,
            color: AppTheme.primaryGreen,
          ),
          Expanded(
            child: _step == 2 && _idFile != null
                ? _buildIDConfirmation()
                : _buildCameraPreview(),
          ),
          Container(
            padding: const EdgeInsets.all(24),
            color: Colors.black,
            child: Column(
              children: [
                Text(
                  _status,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                ),
                const SizedBox(height: 16),
                if (_step == 1)
                  ElevatedButton.icon(
                    onPressed: _captureSelfie,
                    icon: _isCapturing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.camera_alt),
                    label: const Text('Capture Selfie'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primaryGreen,
                      foregroundColor: Colors.white,
                    ),
                  ),
                if (_step == 2 && _idFile == null)
                  ElevatedButton.icon(
                    onPressed: _captureID,
                    icon: _isCapturing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.camera_alt),
                    label: const Text('Capture ID Photo'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primaryGreen,
                      foregroundColor: Colors.white,
                    ),
                  ),
                if (_step == 2 && _idFile != null)
                  ElevatedButton.icon(
                    onPressed: _submit,
                    icon: const Icon(Icons.check_circle),
                    label: const Text('Submit Photos'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primaryGreen,
                      foregroundColor: Colors.white,
                    ),
                  ),
                if (_step == 2 && _idFile != null)
                  TextButton(
                    onPressed: () => setState(() => _idFile = null),
                    child: const Text(
                      'Retake ID Photo',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCameraPreview() {
    if (_controller == null || !_controller!.value.isInitialized) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        CameraPreview(_controller!),
        if (_step == 1)
          Center(
            child: Container(
              width: 220,
              height: 280,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white54, width: 3),
                borderRadius: BorderRadius.circular(140),
              ),
            ),
          ),
        if (_selfieFile != null)
          Positioned(
            top: 16,
            right: 16,
            child: Container(
              width: 60,
              height: 80,
              decoration: BoxDecoration(
                border: Border.all(color: AppTheme.success, width: 2),
                borderRadius: BorderRadius.circular(8),
                image: DecorationImage(
                  image: FileImage(_selfieFile!),
                  fit: BoxFit.cover,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildIDConfirmation() {
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.file(_idFile!, fit: BoxFit.contain),
        Positioned(
          top: 16,
          right: 16,
          child: Container(
            width: 60,
            height: 80,
            decoration: BoxDecoration(
              border: Border.all(color: AppTheme.success, width: 2),
              borderRadius: BorderRadius.circular(8),
              image: DecorationImage(
                image: FileImage(_selfieFile!),
                fit: BoxFit.cover,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

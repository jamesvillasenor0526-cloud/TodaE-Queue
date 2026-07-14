import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import '../../../config/theme.dart';

class FaceVerificationScreen extends StatefulWidget {
  const FaceVerificationScreen({super.key});

  @override
  State<FaceVerificationScreen> createState() => _FaceVerificationScreenState();
}

class _FaceVerificationScreenState extends State<FaceVerificationScreen> {
  CameraController? _controller;
  List<CameraDescription>? _cameras;
  bool _isDetecting = false;
  bool _faceDetected = false;
  bool _selfieCapturing = false;
  File? _selfieFile;
  File? _idFile;
  String _status = 'Position your face in the frame';
  int _step = 1; // 1 = selfie, 2 = ID photo

  late FaceDetector _faceDetector;

  @override
  void initState() {
    super.initState();
    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        enableClassification: true,
        minFaceSize: 0.3,
      ),
    );
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
    _startFaceDetection();
  }

  void _startFaceDetection() {
    _controller?.startImageStream((image) async {
      if (_isDetecting || _selfieFile != null) return;
      _isDetecting = true;

      try {
        final inputImage = _convertCameraImage(image);
        if (inputImage == null) return;

        final faces = await _faceDetector.processImage(inputImage);
        if (mounted) {
          setState(() {
            _faceDetected = faces.isNotEmpty;
            _status = faces.isNotEmpty
                ? '✅ Face detected! Ready to capture'
                : 'Position your face in the frame';
          });
        }
      } catch (_) {
      } finally {
        _isDetecting = false;
      }
    });
  }

  InputImage? _convertCameraImage(CameraImage image) {
    try {
      final camera = _cameras!.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => _cameras!.first,
      );

      final rotation = InputImageRotationValue.fromRawValue(
        camera.sensorOrientation,
      );
      if (rotation == null) return null;

      final format = InputImageFormatValue.fromRawValue(image.format.raw);
      if (format == null) return null;

      final plane = image.planes.first;
      return InputImage.fromBytes(
        bytes: plane.bytes,
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: rotation,
          format: format,
          bytesPerRow: plane.bytesPerRow,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _captureSelfie() async {
    if (!_faceDetected || _controller == null) return;
    setState(() => _selfieCapturing = true);

    try {
      await _controller!.stopImageStream();
      final photo = await _controller!.takePicture();
      setState(() {
        _selfieFile = File(photo.path);
        _step = 2;
        _status = 'Now take a photo of your Driver\'s License';
        _selfieCapturing = false;
      });

      // Switch to back camera for ID photo
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
      setState(() => _selfieCapturing = false);
    }
  }

  Future<void> _captureID() async {
    if (_controller == null) return;
    try {
      final photo = await _controller!.takePicture();
      setState(() {
        _idFile = File(photo.path);
      });
    } catch (e) {
      debugPrint('ID capture error: $e');
    }
  }

  void _submit() {
    if (_selfieFile == null || _idFile == null) return;
    Navigator.pop(context, {'selfie': _selfieFile, 'idPhoto': _idFile});
  }

  @override
  void dispose() {
    _controller?.dispose();
    _faceDetector.close();
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
          // Progress indicator
          LinearProgressIndicator(
            value: _step == 1 ? 0.5 : 1.0,
            backgroundColor: Colors.grey.shade800,
            color: AppTheme.primaryGreen,
          ),

          // Camera preview or captured image
          Expanded(
            child: _step == 2 && _idFile != null
                ? _buildIDConfirmation()
                : _buildCameraPreview(),
          ),

          // Status and button
          Container(
            padding: const EdgeInsets.all(24),
            color: Colors.black,
            child: Column(
              children: [
                Text(
                  _status,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _faceDetected || _step == 2
                        ? Colors.green
                        : Colors.white70,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 16),
                if (_step == 1)
                  ElevatedButton.icon(
                    onPressed: _faceDetected && !_selfieCapturing
                        ? _captureSelfie
                        : null,
                    icon: _selfieCapturing
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
                  ),
                if (_step == 2 && _idFile == null)
                  ElevatedButton.icon(
                    onPressed: _captureID,
                    icon: const Icon(Icons.camera_alt),
                    label: const Text('Capture ID Photo'),
                  ),
                if (_step == 2 && _idFile != null)
                  ElevatedButton.icon(
                    onPressed: _submit,
                    icon: const Icon(Icons.check_circle),
                    label: const Text('Submit for Verification'),
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
      return const Center(child: CircularProgressIndicator());
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        CameraPreview(_controller!),
        // Face outline guide
        if (_step == 1)
          Center(
            child: Container(
              width: 220,
              height: 280,
              decoration: BoxDecoration(
                border: Border.all(
                  color: _faceDetected ? Colors.green : Colors.white54,
                  width: 3,
                ),
                borderRadius: BorderRadius.circular(140),
              ),
            ),
          ),
        // Selfie preview thumbnail
        if (_selfieFile != null)
          Positioned(
            top: 16,
            right: 16,
            child: Container(
              width: 60,
              height: 80,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.green, width: 2),
                borderRadius: BorderRadius.circular(8),
                image: DecorationImage(
                  image: FileImage(_selfieFile!),
                  fit: BoxFit.cover,
                ),
              ),
              child: const Align(
                alignment: Alignment.topRight,
                child: Icon(Icons.check_circle, color: Colors.green, size: 16),
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
              border: Border.all(color: Colors.green, width: 2),
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

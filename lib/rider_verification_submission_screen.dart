import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

import 'config/rider_app_config.dart';
import 'services/rider_verification_service.dart';
import 'services/rider_verification_upload_service.dart';
import 'support/rider_trust_support.dart';

class RiderVerificationSubmissionResult {
  const RiderVerificationSubmissionResult({
    required this.verification,
    required this.trustSummary,
    required this.deviceFingerprints,
    required this.successMessage,
  });

  final Map<String, dynamic> verification;
  final Map<String, dynamic> trustSummary;
  final Map<String, dynamic> deviceFingerprints;
  final String successMessage;
}

class RiderVerificationSubmissionScreen extends StatefulWidget {
  const RiderVerificationSubmissionScreen({
    super.key,
    required this.riderId,
    required this.riderProfile,
    required this.verification,
    required this.riskFlags,
    required this.paymentFlags,
    required this.reputation,
    required this.deviceFingerprints,
  });

  final String riderId;
  final Map<String, dynamic> riderProfile;
  final Map<String, dynamic> verification;
  final Map<String, dynamic> riskFlags;
  final Map<String, dynamic> paymentFlags;
  final Map<String, dynamic> reputation;
  final Map<String, dynamic> deviceFingerprints;

  @override
  State<RiderVerificationSubmissionScreen> createState() =>
      _RiderVerificationSubmissionScreenState();
}

class _RiderVerificationSubmissionScreenState
    extends State<RiderVerificationSubmissionScreen> {
  static const Color _gold = Color(0xFFB57A2A);
  static const Color _cream = Color(0xFFF7F2EA);
  static const Color _dark = Color(0xFF111111);

  final ImagePicker _imagePicker = ImagePicker();
  final RiderVerificationWorkflowService _workflowService =
      const RiderVerificationWorkflowService();

  late final TextEditingController _identityNumberController;
  late final TextEditingController _noteController;

  RiderIdentityMethod _selectedMethod = RiderIdentityMethod.nin;
  RiderVerificationSelectedAsset? _selectedAsset;
  bool _submitting = false;
  double _uploadProgress = 0;

  @override
  void initState() {
    super.initState();
    final identityDocument = Map<String, dynamic>.from(
      (widget.verification['documents'] as Map<String, dynamic>? ??
                  const <String, dynamic>{})['identity']
              as Map? ??
          const <String, dynamic>{},
    );
    _selectedMethod = riderIdentityMethodFromKey(
      widget.verification['identityMethod']?.toString() ??
          identityDocument['documentMethod']?.toString(),
    );
    _identityNumberController = TextEditingController(
      text: identityDocument['documentNumber']?.toString() ?? '',
    );
    _noteController = TextEditingController(
      text: identityDocument['note']?.toString() ?? '',
    );
  }

  @override
  void dispose() {
    _identityNumberController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  void _showMessage(String message) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger == null) {
        return;
      }
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    });
  }

  Future<void> _pickFromCamera() async {
    final permission = await Permission.camera.request();
    if (!permission.isGranted) {
      _showMessage('Camera permission is required to capture your selfie.');
      return;
    }

    final image = await _imagePicker.pickImage(
      source: ImageSource.camera,
      maxWidth: 1800,
      imageQuality: 88,
      preferredCameraDevice: CameraDevice.front,
    );
    if (image == null || !mounted) {
      return;
    }

    setState(() {
      _selectedAsset = RiderVerificationSelectedAsset(
        localPath: image.path,
        fileName: image.name.isNotEmpty
            ? image.name
            : image.path.split('/').last,
        mimeType: _mimeTypeForPath(image.path),
        fileSizeBytes: File(image.path).lengthSync(),
        source: 'camera',
      );
    });
  }

  Future<void> _pickFromGallery() async {
    final image = await _imagePicker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1800,
      imageQuality: 88,
    );
    if (image == null || !mounted) {
      return;
    }

    setState(() {
      _selectedAsset = RiderVerificationSelectedAsset(
        localPath: image.path,
        fileName: image.name.isNotEmpty
            ? image.name
            : image.path.split('/').last,
        mimeType: _mimeTypeForPath(image.path),
        fileSizeBytes: File(image.path).lengthSync(),
        source: 'gallery',
      );
    });
  }

  String _mimeTypeForPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) {
      return 'image/png';
    }
    if (lower.endsWith('.heic')) {
      return 'image/heic';
    }
    if (lower.endsWith('.heif')) {
      return 'image/heif';
    }
    return 'image/jpeg';
  }

  String _formatFileSize(int bytes) {
    if (bytes >= 1000000) {
      return '${(bytes / 1000000).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1000) {
      return '${(bytes / 1000).toStringAsFixed(0)} KB';
    }
    return '$bytes B';
  }

  String? _validateIdentityNumber(String value) {
    final digits = value.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) {
      return '${_selectedMethod.label} is required.';
    }
    if (!RegExp(r'^\d{11}$').hasMatch(digits)) {
      return 'Enter the 11-digit ${_selectedMethod.label} exactly as issued.';
    }
    return null;
  }

  InputDecoration _inputDecoration({
    required String label,
    required String hint,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      labelStyle: TextStyle(color: Colors.black.withValues(alpha: 0.64)),
      hintStyle: TextStyle(color: Colors.black.withValues(alpha: 0.44)),
      filled: true,
      fillColor: _cream,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide(color: Colors.black.withValues(alpha: 0.08)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: const BorderSide(color: _gold, width: 1.4),
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide(color: Colors.black.withValues(alpha: 0.08)),
      ),
    );
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();

    final selectedAsset = _selectedAsset;
    if (selectedAsset == null) {
      _showMessage(
        'Add a selfie before submitting ${RiderVerificationCopy.titleLowercase}.',
      );
      return;
    }

    final normalizedNumber = _identityNumberController.text.replaceAll(
      RegExp(r'\D'),
      '',
    );
    final identityError = _validateIdentityNumber(normalizedNumber);
    if (identityError != null) {
      _showMessage(identityError);
      return;
    }

    setState(() {
      _submitting = true;
      _uploadProgress = 0.05;
    });

    debugPrint(
      '[RiderVerification] submit tapped riderId=${widget.riderId} method=${_selectedMethod.key}',
    );
    var completedWithPop = false;

    try {
      final bundle = await _workflowService.submitVerificationPackage(
        riderId: widget.riderId,
        riderProfile: widget.riderProfile,
        verification: widget.verification,
        riskFlags: widget.riskFlags,
        paymentFlags: widget.paymentFlags,
        reputation: widget.reputation,
        deviceFingerprints: widget.deviceFingerprints,
        identityMethod: _selectedMethod,
        identityNumber: normalizedNumber,
        note: _noteController.text.trim(),
        selfieAsset: selectedAsset,
        onUploadProgress: (double progress) {
          if (!mounted) {
            return;
          }
          setState(() {
            _uploadProgress = progress.clamp(0.08, 0.92);
          });
        },
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _uploadProgress = 1;
      });

      await Future<void>.delayed(const Duration(milliseconds: 180));
      if (!mounted) {
        return;
      }

      Navigator.of(context).pop(
        RiderVerificationSubmissionResult(
          verification: bundle.verification,
          trustSummary: bundle.trustSummary,
          deviceFingerprints: bundle.deviceFingerprints,
          successMessage:
              '${RiderVerificationCopy.title} submitted successfully. Reviews may take up to 3 days.',
        ),
      );
      completedWithPop = true;
    } catch (error, stackTrace) {
      debugPrint('[RiderVerification] submit failed: $error');
      debugPrintStack(
        label: '[RiderVerification] submit stack',
        stackTrace: stackTrace,
      );
      _showMessage('Unable to submit verification right now.');
    } finally {
      if (mounted && !completedWithPop) {
        setState(() {
          _submitting = false;
        });
      }
    }
  }

  Widget _buildActionCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: _submitting ? null : onTap,
        child: Ink(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: _gold.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: _gold),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: Colors.black.withValues(alpha: 0.62),
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSelectedImageCard() {
    final selectedAsset = _selectedAsset;
    if (selectedAsset == null) {
      return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x12000000),
            blurRadius: 16,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            'Selected selfie',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: Image.file(
              File(selectedAsset.localPath),
              height: 220,
              width: double.infinity,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            selectedAsset.fileName,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            '${_formatFileSize(selectedAsset.fileSizeBytes)} • ${selectedAsset.source.replaceAll('_', ' ')}',
            style: TextStyle(color: Colors.black.withValues(alpha: 0.58)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _cream,
      appBar: AppBar(
        backgroundColor: _gold,
        foregroundColor: Colors.black,
        centerTitle: true,
        title: const Text(RiderVerificationCopy.title),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: <Widget>[
            Container(
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                color: _dark,
                borderRadius: BorderRadius.circular(30),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Container(
                        width: 54,
                        height: 54,
                        decoration: BoxDecoration(
                          color: _gold.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: const Icon(
                          Icons.verified_user_outlined,
                          color: _gold,
                        ),
                      ),
                      const SizedBox(width: 14),
                      const Expanded(
                        child: Text(
                          RiderVerificationCopy.title,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Submit your NIN or BVN and a selfie. Reviews may take up to 3 days while identity and face checks are validated.',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.78),
                      height: 1.55,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(28),
                boxShadow: const <BoxShadow>[
                  BoxShadow(
                    color: Color(0x14000000),
                    blurRadius: 18,
                    offset: Offset(0, 12),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    'Identity method',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Use NIN if it is available. If not, you can submit BVN and continue with the same trust workflow.',
                    style: TextStyle(
                      color: Colors.black.withValues(alpha: 0.66),
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: RiderIdentityMethod.values
                        .map(
                          (RiderIdentityMethod method) => ChoiceChip(
                            label: Text(
                              method.label,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            selected: _selectedMethod == method,
                            selectedColor: _gold.withValues(alpha: 0.16),
                            side: BorderSide(
                              color: _selectedMethod == method
                                  ? _gold
                                  : Colors.black.withValues(alpha: 0.12),
                            ),
                            onSelected: _submitting
                                ? null
                                : (_) {
                                    setState(() {
                                      _selectedMethod = method;
                                    });
                                  },
                          ),
                        )
                        .toList(),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _identityNumberController,
                    enabled: !_submitting,
                    keyboardType: TextInputType.number,
                    decoration: _inputDecoration(
                      label: _selectedMethod.label,
                      hint: 'Enter your 11-digit ${_selectedMethod.label}',
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _selectedMethod.description,
                    style: TextStyle(
                      color: Colors.black.withValues(alpha: 0.58),
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(28),
                boxShadow: const <BoxShadow>[
                  BoxShadow(
                    color: Color(0x14000000),
                    blurRadius: 18,
                    offset: Offset(0, 12),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    'Selfie / face verification',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Use a clear face photo with good lighting. Raw file paths are never shown to riders and the upload is stored internally after submission.',
                    style: TextStyle(
                      color: Colors.black.withValues(alpha: 0.66),
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 18),
                  _buildActionCard(
                    icon: Icons.photo_camera_outlined,
                    title: 'Take selfie',
                    subtitle:
                        'Use the camera for a fresh front-facing capture.',
                    onTap: () {
                      unawaited(_pickFromCamera());
                    },
                  ),
                  const SizedBox(height: 12),
                  _buildActionCard(
                    icon: Icons.photo_library_outlined,
                    title: 'Choose from gallery',
                    subtitle: 'Pick an existing selfie or profile image.',
                    onTap: () {
                      unawaited(_pickFromGallery());
                    },
                  ),
                ],
              ),
            ),
            if (_selectedAsset != null) ...<Widget>[
              const SizedBox(height: 18),
              _buildSelectedImageCard(),
            ],
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(28),
                boxShadow: const <BoxShadow>[
                  BoxShadow(
                    color: Color(0x14000000),
                    blurRadius: 18,
                    offset: Offset(0, 12),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    'Notes for review',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _noteController,
                    enabled: !_submitting,
                    maxLines: 4,
                    decoration: _inputDecoration(
                      label: 'Optional note',
                      hint: 'Add any details that may help the review team.',
                    ),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: _cream,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Text(
                      'Reviews may take up to 3 days. Approved external KYC provider checks are prepared in the backend but are not marked as live inside the app yet.',
                      style: TextStyle(
                        color: Colors.black.withValues(alpha: 0.64),
                        height: 1.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (_submitting) ...<Widget>[
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Text(
                      'Uploading User Verification package',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        minHeight: 8,
                        value: _uploadProgress <= 0 ? null : _uploadProgress,
                        backgroundColor: Colors.black.withValues(alpha: 0.08),
                        valueColor: const AlwaysStoppedAnimation<Color>(_gold),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${(_uploadProgress * 100).clamp(0, 100).round()}% uploaded',
                      style: TextStyle(
                        color: Colors.black.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _submitting ? null : _submit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _gold,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
                child: _submitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2.2),
                      )
                    : const Text(
                        'Submit User Verification',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

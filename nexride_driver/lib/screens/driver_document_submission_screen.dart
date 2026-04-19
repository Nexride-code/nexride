import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/driver_verification_service.dart';
import '../services/driver_verification_upload_service.dart';
import '../support/driver_profile_support.dart';

class DriverDocumentSubmissionResult {
  const DriverDocumentSubmissionResult({
    required this.updatedVerification,
    required this.updatedDriverProfile,
    required this.successMessage,
  });

  final Map<String, dynamic> updatedVerification;
  final Map<String, dynamic> updatedDriverProfile;
  final String successMessage;
}

class DriverDocumentSubmissionScreen extends StatefulWidget {
  const DriverDocumentSubmissionScreen({
    super.key,
    required this.driverId,
    required this.driverProfile,
    required this.verification,
    required this.document,
    required this.currentDocument,
  });

  final String driverId;
  final Map<String, dynamic> driverProfile;
  final Map<String, dynamic> verification;
  final DriverRequiredDocument document;
  final Map<String, dynamic> currentDocument;

  @override
  State<DriverDocumentSubmissionScreen> createState() =>
      _DriverDocumentSubmissionScreenState();
}

class _DriverDocumentSubmissionScreenState
    extends State<DriverDocumentSubmissionScreen> {
  final ImagePicker _imagePicker = ImagePicker();
  final DriverVerificationWorkflowService _workflowService =
      const DriverVerificationWorkflowService();

  late final TextEditingController _numberController;
  late final TextEditingController _noteController;

  DriverVerificationSelectedAsset? _selectedAsset;
  bool _submitting = false;
  double _uploadProgress = 0;

  @override
  void initState() {
    super.initState();
    _numberController = TextEditingController(
      text: widget.currentDocument['documentNumber']?.toString() ?? '',
    );
    _noteController = TextEditingController(
      text: widget.currentDocument['note']?.toString() ?? '',
    );
  }

  @override
  void dispose() {
    _numberController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  bool get _isSelfieDocument => widget.document.key == 'selfie';

  String get _existingFileName =>
      widget.currentDocument['fileName']?.toString().trim() ?? '';

  String get _existingStatus =>
      widget.currentDocument['status']?.toString().trim() ?? 'missing';

  String get _existingLastUpdated {
    final rawValue = widget.currentDocument['updatedAt'] ??
        widget.currentDocument['submittedAt'];
    final timestamp = rawValue is num
        ? rawValue.toInt()
        : int.tryParse(rawValue?.toString() ?? '');
    if (timestamp == null || timestamp <= 0) {
      return 'Not submitted yet';
    }
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp).toLocal();
    return '${date.day}/${date.month}/${date.year}';
  }

  Future<void> _pickFromCamera() async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      _showMessage('Camera permission is required to capture this document.');
      return;
    }

    final image = await _imagePicker.pickImage(
      source: ImageSource.camera,
      maxWidth: 1800,
      imageQuality: 88,
    );
    if (image == null || !mounted) {
      return;
    }

    setState(() {
      _selectedAsset = DriverVerificationSelectedAsset(
        localPath: image.path,
        fileName:
            image.name.isNotEmpty ? image.name : image.path.split('/').last,
        mimeType: _mimeTypeForPath(image.path),
        fileSizeBytes: File(image.path).lengthSync(),
        source: 'camera',
        isImage: true,
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
      _selectedAsset = DriverVerificationSelectedAsset(
        localPath: image.path,
        fileName:
            image.name.isNotEmpty ? image.name : image.path.split('/').last,
        mimeType: _mimeTypeForPath(image.path),
        fileSizeBytes: File(image.path).lengthSync(),
        source: 'gallery',
        isImage: true,
      );
    });
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>[
        'jpg',
        'jpeg',
        'png',
        'heic',
        'heif',
        'pdf',
      ],
    );
    if (result == null || result.files.isEmpty || !mounted) {
      return;
    }

    final file = result.files.single;
    final localPath = file.path;
    if (localPath == null || localPath.isEmpty) {
      _showMessage('Unable to read the selected file on this device.');
      return;
    }

    setState(() {
      _selectedAsset = DriverVerificationSelectedAsset(
        localPath: localPath,
        fileName: file.name,
        mimeType: _mimeTypeForPath(localPath),
        fileSizeBytes: file.size,
        source: 'file_picker',
        isImage: _isImagePath(localPath),
      );
    });
  }

  String _mimeTypeForPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) {
      return 'image/png';
    }
    if (lower.endsWith('.pdf')) {
      return 'application/pdf';
    }
    if (lower.endsWith('.heic')) {
      return 'image/heic';
    }
    if (lower.endsWith('.heif')) {
      return 'image/heif';
    }
    return 'image/jpeg';
  }

  bool _isImagePath(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.heic') ||
        lower.endsWith('.heif');
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

  InputDecoration _decoration({
    required String label,
    required String hint,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      labelStyle: TextStyle(color: Colors.black.withValues(alpha: 0.64)),
      hintStyle: TextStyle(color: Colors.black.withValues(alpha: 0.44)),
      filled: true,
      fillColor: kDriverCream,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide(color: Colors.black.withValues(alpha: 0.08)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: const BorderSide(color: kDriverGold, width: 1.4),
      ),
    );
  }

  String? _validateDocumentNumber(String value) {
    if (!(widget.document.numberLabel?.isNotEmpty ?? false)) {
      return null;
    }

    if (value.isEmpty) {
      return '${widget.document.numberLabel} is required.';
    }

    if (widget.document.key == 'nin' && !RegExp(r'^\d{11}$').hasMatch(value)) {
      return 'Enter the 11-digit NIN exactly as issued.';
    }

    if (widget.document.key == 'drivers_license' && value.length < 6) {
      return 'Enter a valid licence number before submitting.';
    }

    if (widget.document.key == 'vehicle_documents' && value.length < 4) {
      return 'Enter a valid registration or plate number.';
    }

    return null;
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();

    final selectedAsset = _selectedAsset;
    if (selectedAsset == null) {
      _showMessage('Choose a file or capture a photo before submitting.');
      return;
    }

    final documentNumber = _numberController.text.trim();
    final numberError = _validateDocumentNumber(documentNumber);
    if (numberError != null) {
      _showMessage(numberError);
      return;
    }

    setState(() {
      _submitting = true;
      _uploadProgress = 0.05;
    });
    var completedWithPop = false;

    try {
      final bundle = await _workflowService.submitDocumentPackage(
        driverId: widget.driverId,
        driverProfile: widget.driverProfile,
        verification: widget.verification,
        document: widget.document,
        asset: selectedAsset,
        documentNumber: documentNumber,
        note: _noteController.text.trim(),
        onUploadProgress: (double progress) {
          if (!mounted) {
            return;
          }
          setState(() {
            _uploadProgress = progress.clamp(0.08, 0.9);
          });
        },
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _uploadProgress = 1;
      });

      await Future<void>.delayed(const Duration(milliseconds: 160));
      if (!mounted) {
        return;
      }

      Navigator.of(context).pop(
        DriverDocumentSubmissionResult(
          updatedVerification: bundle.profileVerification,
          updatedDriverProfile: buildDriverProfileDefaults(
            driverId: widget.driverId,
            existing: <String, dynamic>{
              ...widget.driverProfile,
              'verification': bundle.profileVerification,
            },
          ),
          successMessage:
              '${widget.document.label} submitted successfully. Review may take up to 3 days.',
        ),
      );
      completedWithPop = true;
    } catch (error, stackTrace) {
      debugPrint('[DriverDocumentSubmission] submit failed: $error');
      debugPrintStack(
        label: '[DriverDocumentSubmission] submit stack',
        stackTrace: stackTrace,
      );
      _showMessage('Unable to submit this document right now.');
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
                  color: kDriverGold.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: kDriverGold),
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

  Widget _buildSelectedFileCard() {
    final selectedAsset = _selectedAsset;
    if (selectedAsset == null && _existingFileName.isEmpty) {
      return const SizedBox.shrink();
    }

    final displayName = selectedAsset?.fileName ?? _existingFileName;
    final displaySource = selectedAsset?.source ?? 'existing submission';
    final displaySize = selectedAsset != null
        ? _formatFileSize(selectedAsset.fileSizeBytes)
        : 'Previously submitted';
    final previewIsImage = selectedAsset?.isImage ?? false;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            'Selected file',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 14),
          if (selectedAsset != null && previewIsImage) ...<Widget>[
            ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Image.file(
                File(selectedAsset.localPath),
                height: 180,
                width: double.infinity,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(height: 14),
          ],
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: kDriverCream,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Row(
              children: <Widget>[
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: kDriverGold.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    previewIsImage
                        ? Icons.image_outlined
                        : Icons.description_outlined,
                    color: kDriverGold,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        displayName,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '$displaySize • ${displaySource.replaceAll('_', ' ')}',
                        style: TextStyle(
                          color: Colors.black.withValues(alpha: 0.6),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kDriverCream,
      appBar: AppBar(
        backgroundColor: kDriverGold,
        foregroundColor: Colors.black,
        centerTitle: true,
        title: Text(widget.document.label),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: <Widget>[
            Container(
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                color: kDriverDark,
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
                          color: kDriverGold.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Icon(widget.document.icon, color: kDriverGold),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              widget.document.label,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 24,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              widget.document.description,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.78),
                                height: 1.45,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: <Widget>[
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: driverDocumentStatusColor(_existingStatus)
                              .withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          driverDocumentStatusLabel(_existingStatus),
                          style: TextStyle(
                            color: driverDocumentStatusColor(_existingStatus),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          'Last updated $_existingLastUpdated',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
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
                    color: Color(0x15000000),
                    blurRadius: 16,
                    offset: Offset(0, 10),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    'Upload document',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _isSelfieDocument
                        ? 'Capture or choose a clear selfie/profile photo. This helps identity and liveness review.'
                        : 'Capture a document photo or choose an existing file from your device. The backend stores the uploaded file reference internally after upload.',
                    style: TextStyle(
                      color: Colors.black.withValues(alpha: 0.66),
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 18),
                  _buildActionCard(
                    icon: Icons.photo_camera_outlined,
                    title: _isSelfieDocument ? 'Take selfie' : 'Take photo',
                    subtitle: _isSelfieDocument
                        ? 'Use the camera for a fresh live capture.'
                        : 'Capture the document directly with your camera.',
                    onTap: () {
                      unawaited(_pickFromCamera());
                    },
                  ),
                  const SizedBox(height: 12),
                  _buildActionCard(
                    icon: Icons.photo_library_outlined,
                    title: _isSelfieDocument
                        ? 'Choose from gallery'
                        : 'Choose image',
                    subtitle: _isSelfieDocument
                        ? 'Pick an existing profile photo from your device.'
                        : 'Pick a document image from your gallery.',
                    onTap: () {
                      unawaited(_pickFromGallery());
                    },
                  ),
                  if (!_isSelfieDocument) ...<Widget>[
                    const SizedBox(height: 12),
                    _buildActionCard(
                      icon: Icons.folder_open_outlined,
                      title: 'Choose file',
                      subtitle:
                          'Select a PDF or image file already stored on your device.',
                      onTap: () {
                        unawaited(_pickFile());
                      },
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 18),
            _buildSelectedFileCard(),
            if (_selectedAsset != null || _existingFileName.isNotEmpty)
              const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(28),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    'Document details',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 14),
                  if (widget.document.numberLabel != null) ...<Widget>[
                    TextField(
                      controller: _numberController,
                      enabled: !_submitting,
                      decoration: _decoration(
                        label: widget.document.numberLabel!,
                        hint:
                            'Enter ${widget.document.numberLabel!.toLowerCase()}',
                      ),
                    ),
                    const SizedBox(height: 14),
                  ],
                  TextField(
                    controller: _noteController,
                    enabled: !_submitting,
                    maxLines: 4,
                    decoration: _decoration(
                      label: 'Notes for review (optional)',
                      hint:
                          'Add any explanation that may help the review team.',
                    ),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: kDriverCream,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Text(
                      'Reviews may take up to 3 days. Some checks may go through manual review before approval for safety and accuracy.',
                      style: TextStyle(
                        color: Colors.black.withValues(alpha: 0.66),
                        height: 1.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            if (_submitting) ...<Widget>[
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
                      'Uploading verification package',
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
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          kDriverGold,
                        ),
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
              const SizedBox(height: 18),
            ],
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _submitting ? null : _submit,
                child: Text(
                  _existingStatus == 'missing'
                      ? 'Upload and submit'
                      : 'Resubmit document',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

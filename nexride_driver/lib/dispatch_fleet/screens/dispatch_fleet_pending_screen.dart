import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

import '../dispatch_fleet_account_gate.dart';
import '../dispatch_fleet_functions.dart';
import '../dispatch_fleet_routes.dart';
import '../dispatch_fleet_support.dart';
import '../dispatch_fleet_verification_upload_service.dart';
import '../fleet_upload_validation.dart';

class DispatchFleetPendingScreen extends StatefulWidget {
  const DispatchFleetPendingScreen({super.key});

  @override
  State<DispatchFleetPendingScreen> createState() =>
      _DispatchFleetPendingScreenState();
}

class _DispatchFleetPendingScreenState extends State<DispatchFleetPendingScreen> {
  final DispatchFleetFunctions _fleet = DispatchFleetFunctions();
  final DispatchFleetVerificationUploadService _uploadService =
      const DispatchFleetVerificationUploadService();
  final ImagePicker _imagePicker = ImagePicker();

  Map<String, dynamic>? _account;
  List<Map<String, dynamic>> _documents = const <Map<String, dynamic>>[];
  bool _refreshing = false;
  String? _error;
  String? _uploadingDocType;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final args = ModalRoute.of(context)?.settings.arguments;
      if (args is Map) {
        final response = args.map((k, v) => MapEntry(k.toString(), v));
        setState(() {
          _account = dfAccountMap(response);
        });
      }
      _refreshOnce();
    });
  }

  String? get _businessId => _account?['business_id']?.toString();

  String get _verificationType =>
      _account?['verification_type']?.toString() ?? 'cac_business';

  Map<String, dynamic>? get _docsReadiness {
    final raw = _account?['docs_readiness'];
    if (raw is Map) {
      return raw.map((k, v) => MapEntry(k.toString(), v));
    }
    return null;
  }

  Future<void> _refreshOnce() async {
    setState(() {
      _refreshing = true;
      _error = null;
    });
    try {
      final response = await _fleet.dispatchFleetGetMyAccount();
      if (!mounted) {
        return;
      }
      final dest = destinationForFleetAccountResponse(response);
      if (dest == DispatchFleetAccountDestination.invites) {
        await Navigator.of(context).pushNamedAndRemoveUntil(
          DispatchFleetRoutes.invites,
          (Route<dynamic> route) => false,
        );
        return;
      }
      if (dest == DispatchFleetAccountDestination.rejected) {
        await Navigator.of(context).pushNamedAndRemoveUntil(
          DispatchFleetRoutes.rejected,
          (Route<dynamic> route) => false,
          arguments: response,
        );
        return;
      }
      if (dest == DispatchFleetAccountDestination.suspended) {
        await Navigator.of(context).pushNamedAndRemoveUntil(
          DispatchFleetRoutes.suspended,
          (Route<dynamic> route) => false,
          arguments: response,
        );
        return;
      }
      if (dest == DispatchFleetAccountDestination.signup) {
        await Navigator.of(context).pushNamedAndRemoveUntil(
          DispatchFleetRoutes.signup,
          (Route<dynamic> route) => false,
        );
        return;
      }

      setState(() => _account = dfAccountMap(response));

      final docsRes = await _fleet.fleetListMyVerificationDocuments();
      if (docsRes['success'] == true && mounted) {
        final list = docsRes['documents'];
        if (list is List) {
          setState(() {
            _documents = list
                .whereType<Map>()
                .map((e) => e.map((k, v) => MapEntry(k.toString(), v)))
                .toList();
          });
        }
      }
    } catch (_) {
      setState(() => _error = 'Could not refresh status. Please try again.');
    } finally {
      if (mounted) {
        setState(() => _refreshing = false);
      }
    }
  }

  Future<void> _logout() async {
    await FirebaseAuth.instance.signOut();
    if (!mounted) {
      return;
    }
    await Navigator.of(context).pushNamedAndRemoveUntil(
      DispatchFleetRoutes.root,
      (Route<dynamic> route) => false,
    );
  }

  String _statusForDoc(String key) {
    for (final row in _documents) {
      if (row['document_type']?.toString() == key) {
        return row['status']?.toString() ?? 'not_submitted';
      }
    }
    final statuses = _docsReadiness?['document_statuses'];
    if (statuses is Map && statuses[key] != null) {
      return statuses[key].toString();
    }
    return 'not_submitted';
  }

  Future<FleetVerificationSelectedAsset?> _pickAsset(
    FleetVerificationDocumentType doc,
  ) async {
    if (doc.preferCamera) {
      final status = await Permission.camera.request();
      if (!status.isGranted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Camera permission is required for selfie.')),
          );
        }
        return null;
      }
      final picked = await _imagePicker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.front,
        imageQuality: 85,
      );
      if (picked == null) {
        return null;
      }
      final file = File(picked.path);
      final bytes = await file.length();
      const mime = 'image/jpeg';
      final validationError = FleetUploadValidation.validate(
        mimeType: mime,
        fileSizeBytes: bytes,
        fileName: picked.name,
      );
      if (validationError != null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(FleetUploadValidation.userMessageForReason(validationError)),
            ),
          );
        }
        return null;
      }
      return FleetVerificationSelectedAsset(
        localPath: picked.path,
        fileName: picked.name,
        mimeType: mime,
        fileSizeBytes: bytes,
      );
    }

    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['jpg', 'jpeg', 'png', 'pdf'],
      withData: false,
    );
    if (result == null || result.files.isEmpty) {
      return null;
    }
    final file = result.files.single;
    final path = file.path;
    if (path == null) {
      return null;
    }
    final name = file.name;
    final mime = FleetUploadValidation.mimeTypeForFileName(name);
    if (mime.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              FleetUploadValidation.userMessageForReason('invalid_file_type'),
            ),
          ),
        );
      }
      return null;
    }
    final size = file.size;
    final validationError = FleetUploadValidation.validate(
      mimeType: mime,
      fileSizeBytes: size,
      fileName: name,
    );
    if (validationError != null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(FleetUploadValidation.userMessageForReason(validationError)),
          ),
        );
      }
      return null;
    }
    return FleetVerificationSelectedAsset(
      localPath: path,
      fileName: name,
      mimeType: mime,
      fileSizeBytes: size,
    );
  }

  Future<void> _uploadDoc(FleetVerificationDocumentType doc) async {
    final businessId = _businessId;
    if (businessId == null || businessId.isEmpty) {
      return;
    }
    final asset = await _pickAsset(doc);
    if (asset == null || !mounted) {
      return;
    }

    setState(() {
      _uploadingDocType = doc.key;
      _error = null;
    });

    try {
      final uploaded = await _uploadService.uploadDocument(
        businessId: businessId,
        documentType: doc.key,
        asset: asset,
      );
      final registerRes = await _fleet.fleetUploadVerificationDocument(
        documentType: doc.key,
        storagePath: uploaded.storagePath,
        fileName: uploaded.fileName,
        contentType: uploaded.mimeType,
      );
      if (!dfSuccess(registerRes['success'])) {
        final reason = registerRes['reason']?.toString();
        if (reason == 'invalid_file_type' || reason == 'file_too_large') {
          throw FleetUploadValidationException(reason!);
        }
        throw StateError(reason ?? 'register_failed');
      }
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${doc.label} submitted for review.')),
      );
      await _refreshOnce();
    } on FleetUploadValidationException catch (e) {
      if (mounted) {
        setState(
          () => _error = FleetUploadValidation.userMessageForReason(e.reason),
        );
      }
    } catch (e) {
      if (mounted) {
        final msg = e.toString();
        if (msg.contains('invalid_file_type') || msg.contains('file_too_large')) {
          setState(
            () => _error = FleetUploadValidation.userMessageForReason(
              msg.contains('file_too_large') ? 'file_too_large' : 'invalid_file_type',
            ),
          );
        } else {
          setState(() => _error = 'Upload failed: $e');
        }
      }
    } finally {
      if (mounted) {
        setState(() => _uploadingDocType = null);
      }
    }
  }

  Widget _docTile(FleetVerificationDocumentType doc) {
    final status = _statusForDoc(doc.key).toLowerCase();
    final uploading = _uploadingDocType == doc.key;
    final canUpload = status == 'not_submitted' ||
        status == 'rejected' ||
        status == 'resubmission_required';

    IconData icon = Icons.description_outlined;
    Color statusColor = Colors.orange;
    if (status == 'approved') {
      icon = Icons.check_circle_outline;
      statusColor = Colors.green;
    } else if (status == 'pending') {
      icon = Icons.hourglass_top;
      statusColor = Colors.blue;
    } else if (status == 'not_submitted') {
      icon = Icons.upload_file;
      statusColor = Colors.grey;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(icon, color: statusColor),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(doc.label, style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text('Status: ${status.replaceAll('_', ' ')}'),
                ],
              ),
            ),
            if (canUpload)
              FilledButton(
                onPressed: uploading ? null : () => _uploadDoc(doc),
                child: uploading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Upload'),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final account = _account;
    final businessName = account?['business_name']?.toString() ?? 'Your fleet';
    final status = dfAccountStatus(account);
    final verification = account?['verification_status']?.toString() ?? '';
    final readable = _docsReadiness?['readable_message']?.toString();
    final requiredDocs =
        FleetVerificationDocumentType.forVerificationType(_verificationType);
    final pendingDocs = status == 'pending_documents';
    final pendingReview = status == 'pending_review';

    return Scaffold(
      appBar: AppBar(
        title: Text(pendingDocs ? 'Complete verification' : 'Application status'),
        actions: <Widget>[
          TextButton(onPressed: _logout, child: const Text('Log out')),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  businessName,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
                const SizedBox(height: 12),
                Text(
                  pendingDocs
                      ? 'Upload all required documents below. NexRide will review your fleet after submission.'
                      : pendingReview
                          ? 'Your documents are under review. You will be notified when your fleet is approved.'
                          : 'Your Dispatch Fleet application is being processed.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text('Status: ${status.isEmpty ? 'pending' : status}'),
                        const SizedBox(height: 6),
                        Text('Verification: $verification'),
                        Text(
                          'Type: ${_verificationType == 'nin_individual_business' ? 'NIN individual business' : 'CAC business'}',
                        ),
                        if (readable != null && readable.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 8),
                          Text(readable),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'Required documents',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
                const SizedBox(height: 8),
                ...requiredDocs.map(_docTile),
                if (_error != null) ...<Widget>[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _refreshing ? null : _refreshOnce,
                  child: _refreshing
                      ? const SizedBox(
                          height: 22,
                          width: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Refresh status'),
                ),
                const SizedBox(height: 12),
                const DispatchFleetSupportSection(
                  subject: 'Dispatch Fleet verification documents',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

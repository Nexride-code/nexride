import 'dart:io';

import 'package:firebase_storage/firebase_storage.dart';

import 'fleet_upload_validation.dart';

/// Fleet owner verification document keys (must match backend).
class FleetVerificationDocumentType {
  const FleetVerificationDocumentType({
    required this.key,
    required this.label,
    this.preferCamera = false,
  });

  final String key;
  final String label;
  final bool preferCamera;

  static const List<FleetVerificationDocumentType> cacBusiness = <FleetVerificationDocumentType>[
    FleetVerificationDocumentType(key: 'cac_document', label: 'CAC certificate'),
    FleetVerificationDocumentType(key: 'owner_id', label: 'Owner government ID'),
    FleetVerificationDocumentType(
      key: 'owner_selfie',
      label: 'Owner selfie',
      preferCamera: true,
    ),
    FleetVerificationDocumentType(key: 'address_proof', label: 'Address proof'),
  ];

  static const List<FleetVerificationDocumentType> ninBusiness = <FleetVerificationDocumentType>[
    FleetVerificationDocumentType(key: 'nin_document', label: 'NIN slip or card'),
    FleetVerificationDocumentType(
      key: 'owner_selfie',
      label: 'Owner selfie',
      preferCamera: true,
    ),
    FleetVerificationDocumentType(key: 'address_proof', label: 'Address proof'),
  ];

  static List<FleetVerificationDocumentType> forVerificationType(String? type) {
    final t = type?.trim().toLowerCase() ?? '';
    if (t == 'nin_individual_business') {
      return ninBusiness;
    }
    return cacBusiness;
  }
}

class FleetVerificationSelectedAsset {
  const FleetVerificationSelectedAsset({
    required this.localPath,
    required this.fileName,
    required this.mimeType,
    required this.fileSizeBytes,
  });

  final String localPath;
  final String fileName;
  final String mimeType;
  final int fileSizeBytes;
}

class FleetVerificationUploadedFile {
  const FleetVerificationUploadedFile({
    required this.storagePath,
    required this.fileName,
    required this.mimeType,
    required this.fileSizeBytes,
  });

  final String storagePath;
  final String fileName;
  final String mimeType;
  final int fileSizeBytes;
}

/// Storage upload only — registration with Firestore is via callable.
class DispatchFleetVerificationUploadService {
  const DispatchFleetVerificationUploadService();

  FirebaseStorage get _storage => FirebaseStorage.instance;

  Future<FleetVerificationUploadedFile> uploadDocument({
    required String businessId,
    required String documentType,
    required FleetVerificationSelectedAsset asset,
    void Function(double progress)? onProgress,
  }) async {
    final validationError = FleetUploadValidation.validate(
      mimeType: asset.mimeType,
      fileSizeBytes: asset.fileSizeBytes,
      fileName: asset.fileName,
    );
    if (validationError != null) {
      throw FleetUploadValidationException(validationError);
    }

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final safeFileName = _sanitizeFileName(asset.fileName);
    final storagePath =
        'fleet_verification_uploads/$businessId/$documentType/${timestamp}_$safeFileName';
    final reference = _storage.ref().child(storagePath);

    final uploadTask = reference.putFile(
      File(asset.localPath),
      SettableMetadata(
        contentType: asset.mimeType,
        customMetadata: <String, String>{
          'businessId': businessId,
          'documentType': documentType,
        },
      ),
    );

    final subscription = uploadTask.snapshotEvents.listen((TaskSnapshot event) {
      final totalBytes = event.totalBytes;
      if (totalBytes <= 0) {
        return;
      }
      onProgress?.call(event.bytesTransferred / totalBytes);
    });

    try {
      await uploadTask;
      onProgress?.call(1);
      return FleetVerificationUploadedFile(
        storagePath: storagePath,
        fileName: asset.fileName,
        mimeType: asset.mimeType,
        fileSizeBytes: asset.fileSizeBytes,
      );
    } finally {
      await subscription.cancel();
    }
  }

  String _sanitizeFileName(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      return 'document_upload';
    }
    return trimmed.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  }
}

class FleetUploadValidationException implements Exception {
  FleetUploadValidationException(this.reason);

  final String reason;

  @override
  String toString() => reason;
}

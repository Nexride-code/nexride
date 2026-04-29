import 'dart:io';

import 'package:firebase_storage/firebase_storage.dart';

import '../support/driver_profile_support.dart';

class DriverVerificationSelectedAsset {
  const DriverVerificationSelectedAsset({
    required this.localPath,
    required this.fileName,
    required this.mimeType,
    required this.fileSizeBytes,
    required this.source,
    required this.isImage,
  });

  final String localPath;
  final String fileName;
  final String mimeType;
  final int fileSizeBytes;
  final String source;
  final bool isImage;
}

class DriverVerificationUploadedFile {
  const DriverVerificationUploadedFile({
    required this.fileUrl,
    required this.fileReference,
    required this.fileName,
    required this.mimeType,
    required this.fileSizeBytes,
    required this.source,
    required this.isImage,
  });

  final String fileUrl;
  final String fileReference;
  final String fileName;
  final String mimeType;
  final int fileSizeBytes;
  final String source;
  final bool isImage;
}

class DriverVerificationUploadService {
  const DriverVerificationUploadService();

  FirebaseStorage get _storage => FirebaseStorage.instance;

  Future<DriverVerificationUploadedFile> uploadDocument({
    required String driverId,
    required DriverRequiredDocument document,
    required DriverVerificationSelectedAsset asset,
    void Function(double progress)? onProgress,
  }) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final safeFileName = _sanitizeFileName(asset.fileName);
    final storagePath =
        'driver_verification_uploads/$driverId/${document.key}/${timestamp}_$safeFileName';
    final reference = _storage.ref().child(storagePath);

    final uploadTask = reference.putFile(
      File(asset.localPath),
      SettableMetadata(
        contentType: asset.mimeType,
        customMetadata: <String, String>{
          'driverId': driverId,
          'documentType': document.key,
          'source': asset.source,
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
      final snapshot = await uploadTask;
      final fileUrl = await snapshot.ref.getDownloadURL();
      onProgress?.call(1);

      return DriverVerificationUploadedFile(
        fileUrl: fileUrl,
        fileReference: snapshot.ref.fullPath,
        fileName: asset.fileName,
        mimeType: asset.mimeType,
        fileSizeBytes: asset.fileSizeBytes,
        source: asset.source,
        isImage: asset.isImage,
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

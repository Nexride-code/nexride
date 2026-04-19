import 'dart:io';

import 'package:firebase_storage/firebase_storage.dart';

class RiderVerificationSelectedAsset {
  const RiderVerificationSelectedAsset({
    required this.localPath,
    required this.fileName,
    required this.mimeType,
    required this.fileSizeBytes,
    required this.source,
  });

  final String localPath;
  final String fileName;
  final String mimeType;
  final int fileSizeBytes;
  final String source;
}

class RiderVerificationUploadedFile {
  const RiderVerificationUploadedFile({
    required this.fileUrl,
    required this.fileReference,
    required this.fileName,
    required this.mimeType,
    required this.fileSizeBytes,
    required this.source,
  });

  final String fileUrl;
  final String fileReference;
  final String fileName;
  final String mimeType;
  final int fileSizeBytes;
  final String source;
}

class RiderVerificationUploadService {
  const RiderVerificationUploadService();

  FirebaseStorage get _storage => FirebaseStorage.instance;

  Future<RiderVerificationUploadedFile> uploadSelfie({
    required String riderId,
    required RiderVerificationSelectedAsset asset,
    void Function(double progress)? onProgress,
  }) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final safeFileName = _sanitizeFileName(asset.fileName);
    final storagePath =
        'rider_verification_uploads/$riderId/selfie/${timestamp}_$safeFileName';
    final reference = _storage.ref().child(storagePath);

    final uploadTask = reference.putFile(
      File(asset.localPath),
      SettableMetadata(
        contentType: asset.mimeType,
        customMetadata: <String, String>{
          'riderId': riderId,
          'documentType': 'selfie',
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
      return RiderVerificationUploadedFile(
        fileUrl: fileUrl,
        fileReference: snapshot.ref.fullPath,
        fileName: asset.fileName,
        mimeType: asset.mimeType,
        fileSizeBytes: asset.fileSizeBytes,
        source: asset.source,
      );
    } finally {
      await subscription.cancel();
    }
  }

  String _sanitizeFileName(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      return 'selfie_capture';
    }
    return trimmed.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  }
}

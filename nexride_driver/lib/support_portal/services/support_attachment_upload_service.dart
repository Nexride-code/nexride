import 'dart:typed_data';

import 'package:firebase_storage/firebase_storage.dart';

class SupportAttachmentSelection {
  const SupportAttachmentSelection({
    required this.fileName,
    required this.mimeType,
    required this.fileSizeBytes,
    required this.bytes,
  });

  final String fileName;
  final String mimeType;
  final int fileSizeBytes;
  final Uint8List bytes;
}

class SupportUploadedAttachment {
  const SupportUploadedAttachment({
    required this.fileUrl,
    required this.storagePath,
    required this.fileName,
    required this.mimeType,
    required this.fileSizeBytes,
  });

  final String fileUrl;
  final String storagePath;
  final String fileName;
  final String mimeType;
  final int fileSizeBytes;
}

class SupportAttachmentUploadService {
  const SupportAttachmentUploadService({
    FirebaseStorage? storage,
  }) : _storage = storage;

  final FirebaseStorage? _storage;

  FirebaseStorage get storage => _storage ?? FirebaseStorage.instance;

  Future<SupportUploadedAttachment> uploadAttachment({
    required String ticketDocumentId,
    required String actorId,
    required SupportAttachmentSelection asset,
    void Function(double progress)? onProgress,
  }) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final storagePath =
        'support_uploads/$ticketDocumentId/$actorId/${timestamp}_${_sanitizeFileName(asset.fileName)}';
    final reference = storage.ref().child(storagePath);
    final uploadTask = reference.putData(
      asset.bytes,
      SettableMetadata(
        contentType: asset.mimeType,
        customMetadata: <String, String>{
          'ticketDocumentId': ticketDocumentId,
          'actorId': actorId,
          'source': 'support_portal',
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
      final url = await snapshot.ref.getDownloadURL();
      onProgress?.call(1);
      return SupportUploadedAttachment(
        fileUrl: url,
        storagePath: snapshot.ref.fullPath,
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
      return 'support_attachment';
    }
    return trimmed.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  }
}

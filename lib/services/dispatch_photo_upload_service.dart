import 'dart:io';

import 'package:firebase_storage/firebase_storage.dart';

class DispatchPhotoSelectedAsset {
  const DispatchPhotoSelectedAsset({
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

class DispatchUploadedPhoto {
  const DispatchUploadedPhoto({
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

class DispatchPhotoUploadService {
  const DispatchPhotoUploadService();

  FirebaseStorage get _storage => FirebaseStorage.instance;

  Future<DispatchUploadedPhoto> uploadRidePhoto({
    required String rideId,
    required String actorId,
    required String category,
    required DispatchPhotoSelectedAsset asset,
    void Function(double progress)? onProgress,
  }) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final safeFileName = _sanitizeFileName(asset.fileName);
    final storagePath =
        'dispatch_uploads/$rideId/$category/${timestamp}_$safeFileName';
    final reference = _storage.ref().child(storagePath);

    final uploadTask = reference.putFile(
      File(asset.localPath),
      SettableMetadata(
        contentType: asset.mimeType,
        customMetadata: <String, String>{
          'rideId': rideId,
          'actorId': actorId,
          'category': category,
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

      return DispatchUploadedPhoto(
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

  Future<DispatchUploadedPhoto> uploadRideChatPhoto({
    required String rideId,
    required String actorId,
    required DispatchPhotoSelectedAsset asset,
    void Function(double progress)? onProgress,
  }) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final safeFileName = _sanitizeFileName(asset.fileName);
    final storagePath =
        'ride_chats/$rideId/$actorId/${timestamp}_$safeFileName';
    final reference = _storage.ref().child(storagePath);

    final uploadTask = reference.putFile(
      File(asset.localPath),
      SettableMetadata(
        contentType: asset.mimeType,
        customMetadata: <String, String>{
          'rideId': rideId,
          'actorId': actorId,
          'category': 'ride_chat',
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

      return DispatchUploadedPhoto(
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

  Future<DispatchUploadedPhoto> uploadRidePaymentProof({
    required String rideId,
    required String actorId,
    required DispatchPhotoSelectedAsset asset,
    void Function(double progress)? onProgress,
  }) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final safeFileName = _sanitizeFileName(asset.fileName);
    final storagePath =
        'ride_payment_proofs/$rideId/$actorId/${timestamp}_$safeFileName';
    final reference = _storage.ref().child(storagePath);

    final uploadTask = reference.putFile(
      File(asset.localPath),
      SettableMetadata(
        contentType: asset.mimeType,
        customMetadata: <String, String>{
          'rideId': rideId,
          'actorId': actorId,
          'category': 'ride_payment_proof',
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

      return DispatchUploadedPhoto(
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
      return 'dispatch_photo';
    }
    return trimmed.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  }
}

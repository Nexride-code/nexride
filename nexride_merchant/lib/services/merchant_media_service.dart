import 'dart:io';

import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';

import '../utils/nx_callable_messages.dart';
import 'merchant_gateway_service.dart';

/// Uploads a JPEG/PNG to the merchant-owned Storage prefix, then registers it via
/// [MerchantGatewayService.merchantAttachMenuOrProfileImage] so Firestore gets a signed URL.
class MerchantMediaService {
  MerchantMediaService._();

  static const int _maxBytes = 10 * 1024 * 1024;

  static Future<File> _jpegCompress(File src) async {
    final outPath =
        '${src.parent.path}/nx_cmp_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final x = await FlutterImageCompress.compressAndGetFile(
      src.absolute.path,
      outPath,
      quality: 82,
      minWidth: 1280,
      minHeight: 1280,
      format: CompressFormat.jpeg,
    );
    if (x == null) return src;
    final out = File(x.path);
    return out.existsSync() ? out : src;
  }

  static Future<XFile?> pickImage() async {
    final picker = ImagePicker();
    return picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
      maxWidth: 2048,
      maxHeight: 2048,
    );
  }

  static Future<String?> pickUploadAndAttach({
    required MerchantGatewayService gateway,
    required String merchantId,
    required String kind,
    String? entityId,
  }) async {
    final x = await pickImage();
    if (x == null) return null;
    return uploadLocalFileAndAttach(
      gateway: gateway,
      merchantId: merchantId,
      kind: kind,
      entityId: entityId,
      localPath: x.path,
    );
  }

  /// Upload a file already on disk (e.g. after creating a menu row so [entityId] exists).
  static Future<String?> uploadLocalFileAndAttach({
    required MerchantGatewayService gateway,
    required String merchantId,
    required String kind,
    String? entityId,
    required String localPath,
  }) async {
    final file = File(localPath);
    final len = await file.length();
    if (len <= 0 || len > _maxBytes) {
      throw StateError('Image must be under 10 MB.');
    }
    final lower = localPath.toLowerCase();
    var ext = lower.endsWith('.png') ? 'png' : 'jpg';
    var contentType = ext == 'png' ? 'image/png' : 'image/jpeg';
    File uploadFile = file;
    if (lower.endsWith('.png') || lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      try {
        final compressed = await _jpegCompress(file);
        if (compressed.path != file.path) {
          uploadFile = compressed;
          ext = 'jpg';
          contentType = 'image/jpeg';
        }
      } catch (_) {}
    }
    final uploadLen = await uploadFile.length();
    if (uploadLen <= 0 || uploadLen > _maxBytes) {
      throw StateError('Image must be under 10 MB.');
    }
    final ts = DateTime.now().millisecondsSinceEpoch;
    late final String path;
    switch (kind) {
      case 'category':
        if (entityId == null || entityId.isEmpty) {
          throw StateError('category id required');
        }
        path = 'merchant_uploads/$merchantId/menu/categories/$entityId/$ts.$ext';
      case 'item':
        if (entityId == null || entityId.isEmpty) {
          throw StateError('item id required');
        }
        path = 'merchant_uploads/$merchantId/menu/items/$entityId/$ts.$ext';
      case 'logo':
        path = 'merchant_uploads/$merchantId/profile/logo/$ts.$ext';
      case 'banner':
        path = 'merchant_uploads/$merchantId/profile/banner/$ts.$ext';
      default:
        throw StateError('invalid kind');
    }
    final ref = FirebaseStorage.instance.ref(path);
    await ref.putFile(
      uploadFile,
      SettableMetadata(contentType: contentType),
    );
    final res = await gateway.merchantAttachMenuOrProfileImage(<String, dynamic>{
      'kind': kind,
      if (entityId != null) 'entity_id': entityId,
      'storage_path': path,
    });
    if (res['success'] == true) {
      return res['image_url']?.toString();
    }
    throw StateError(
      nxMapFailureMessage(
        Map<String, dynamic>.from(res),
        'Image could not be saved to your menu.',
      ),
    );
  }
}

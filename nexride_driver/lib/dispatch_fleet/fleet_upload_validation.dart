/// Client-side validation for Dispatch Fleet verification uploads (must match backend).
class FleetUploadValidation {
  FleetUploadValidation._();

  static const int maxBytes = 10 * 1024 * 1024;

  static const Set<String> allowedMimeTypes = <String>{
    'image/jpeg',
    'image/png',
    'application/pdf',
  };

  static const Map<String, Set<String>> mimeExtensions = <String, Set<String>>{
    'image/jpeg': <String>{'jpg', 'jpeg'},
    'image/png': <String>{'png'},
    'application/pdf': <String>{'pdf'},
  };

  static const Set<String> blockedExtensions = <String>{
    'exe',
    'bat',
    'cmd',
    'com',
    'msi',
    'dll',
    'scr',
    'ps1',
    'sh',
    'bash',
    'apk',
    'jar',
    'js',
    'mjs',
    'html',
    'htm',
    'svg',
    'webp',
    'gif',
    'heic',
    'heif',
    'doc',
    'docx',
    'xls',
    'xlsx',
    'zip',
    'rar',
    '7z',
  };

  /// Returns `null` when valid, otherwise `invalid_file_type` or `file_too_large`.
  static String? validate({
    required String mimeType,
    required int fileSizeBytes,
    String? fileName,
  }) {
    final normalizedMime = mimeType.trim().toLowerCase();
    if (!allowedMimeTypes.contains(normalizedMime)) {
      return 'invalid_file_type';
    }

    final ext = _extension(fileName);
    if (ext.isNotEmpty && blockedExtensions.contains(ext)) {
      return 'invalid_file_type';
    }

    final allowedForMime = mimeExtensions[normalizedMime];
    if (ext.isNotEmpty && allowedForMime != null && !allowedForMime.contains(ext)) {
      return 'invalid_file_type';
    }

    if (fileSizeBytes <= 0 || fileSizeBytes > maxBytes) {
      return 'file_too_large';
    }

    return null;
  }

  static String mimeTypeForFileName(String fileName) {
    final ext = _extension(fileName);
    switch (ext) {
      case 'png':
        return 'image/png';
      case 'pdf':
        return 'application/pdf';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      default:
        return '';
    }
  }

  static String userMessageForReason(String? reason) {
    switch (reason?.trim().toLowerCase()) {
      case 'invalid_file_type':
        return 'Only JPEG, PNG, or PDF files are allowed.';
      case 'file_too_large':
        return 'File must be 10 MB or smaller.';
      default:
        return 'Could not upload this file. Please try again.';
    }
  }

  static String _extension(String? fileName) {
    final name = fileName?.trim() ?? '';
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) {
      return '';
    }
    return name.substring(dot + 1).toLowerCase();
  }
}

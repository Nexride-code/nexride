import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart' as rtdb;
import 'package:flutter/foundation.dart';

typedef StartupRtdbAction<T> = Future<T> Function();

class StartupRtdbException implements Exception {
  const StartupRtdbException({
    required this.source,
    required this.path,
    required this.requiredRead,
    required this.cause,
  });

  final String source;
  final String path;
  final bool requiredRead;
  final Object cause;

  @override
  String toString() {
    return 'StartupRtdbException('
        'source: $source, '
        'path: $path, '
        'requiredRead: $requiredRead, '
        'cause: $cause'
        ')';
  }
}

Future<T> runRequiredStartupRead<T>({
  required String source,
  required String path,
  required StartupRtdbAction<T> action,
}) async {
  _logStartupRtdb(source: source, path: path, optional: false, phase: 'start');
  try {
    final result = await action();
    _logStartupRtdb(
      source: source,
      path: path,
      optional: false,
      phase: 'success',
    );
    return result;
  } catch (error, stackTrace) {
    _logStartupRtdb(
      source: source,
      path: path,
      optional: false,
      phase: 'error',
      error: error,
      stackTrace: stackTrace,
    );
    throw StartupRtdbException(
      source: source,
      path: path,
      requiredRead: true,
      cause: error,
    );
  }
}

Future<T?> runOptionalStartupRead<T>({
  required String source,
  required String path,
  required StartupRtdbAction<T> action,
}) async {
  _logStartupRtdb(source: source, path: path, optional: true, phase: 'start');
  try {
    final result = await action();
    _logStartupRtdb(
      source: source,
      path: path,
      optional: true,
      phase: 'success',
    );
    return result;
  } catch (error, stackTrace) {
    _logStartupRtdb(
      source: source,
      path: path,
      optional: true,
      phase: 'error',
      error: error,
      stackTrace: stackTrace,
    );
    return null;
  }
}

Future<Map<String, dynamic>> readUserProfileWithFallback({
  required rtdb.DatabaseReference rootRef,
  required String uid,
  required String source,
}) async {
  final normalizedUid = uid.trim();
  if (normalizedUid.isEmpty) {
    return <String, dynamic>{};
  }

  final usersSnapshot = await runOptionalStartupRead<rtdb.DataSnapshot>(
    source: source,
    path: 'users/$normalizedUid',
    action: () => rootRef.child('users/$normalizedUid').get(),
  );
  final usersMap = usersSnapshot?.value is Map
      ? Map<String, dynamic>.from(usersSnapshot!.value as Map)
      : <String, dynamic>{};

  if (usersMap.isNotEmpty) {
    return usersMap;
  }

  final legacySnapshot = await runOptionalStartupRead<rtdb.DataSnapshot>(
    source: source,
    path: 'Users/$normalizedUid',
    action: () => rootRef.child('Users/$normalizedUid').get(),
  );
  final legacyMap = legacySnapshot?.value is Map
      ? Map<String, dynamic>.from(legacySnapshot!.value as Map)
      : <String, dynamic>{};
  return legacyMap;
}

Future<bool> hasRiderBootstrapArtifacts({
  required rtdb.DatabaseReference rootRef,
  required String riderId,
  required String source,
}) async {
  final normalizedRiderId = riderId.trim();
  if (normalizedRiderId.isEmpty) {
    return false;
  }

  final snapshots = await Future.wait(<Future<rtdb.DataSnapshot?>>[
    runOptionalStartupRead<rtdb.DataSnapshot>(
      source: source,
      path: 'rider_verifications/$normalizedRiderId',
      action: () => rootRef.child('rider_verifications/$normalizedRiderId').get(),
    ),
    runOptionalStartupRead<rtdb.DataSnapshot>(
      source: source,
      path: 'rider_device_fingerprints/$normalizedRiderId',
      action: () => rootRef.child('rider_device_fingerprints/$normalizedRiderId').get(),
    ),
  ]);

  return (snapshots[0]?.exists ?? false) && (snapshots[1]?.exists ?? false);
}

/// Writes a minimal rider row when full trust/bootstrap writes fail so login can proceed offline-first.
Future<void> persistRiderMinimalPresence({
  required rtdb.DatabaseReference rootRef,
  required String uid,
  required String email,
  String? name,
  required String source,
}) async {
  final normalizedUid = uid.trim();
  if (normalizedUid.isEmpty) return;

  final now = rtdb.ServerValue.timestamp;
  final displayName =
      name?.trim().isNotEmpty == true ? name!.trim() : email.split('@').first;
  final userPayload = <String, Object?>{
    'uid': normalizedUid,
    'email': email.trim(),
    'name': displayName,
    'role': 'rider',
    'status': 'active',
    'updated_at': now,
    'created_at': now,
  };

  final riderPointer = <String, Object?>{
    'uid': normalizedUid,
    'email': email.trim(),
    'role': 'rider',
    'status': 'active',
    'updated_at': now,
    'created_at': now,
  };

  try {
    await rootRef.child('users/$normalizedUid').update(<String, dynamic>{
      ...userPayload,
    });
    await rootRef.child('riders/$normalizedUid').update(<String, dynamic>{
      ...riderPointer,
    });
    _logStartupRtdb(
      source: source,
      path: 'users/$normalizedUid + riders/$normalizedUid',
      optional: false,
      phase: 'minimal_write_success',
    );
  } catch (error, stackTrace) {
    debugPrint('[RiderMinimal] source=$source uid=$normalizedUid error=$error');
    if (kDebugMode) {
      debugPrintStack(stackTrace: stackTrace);
    }
    _logStartupRtdb(
      source: source,
      path: 'users/$normalizedUid',
      optional: false,
      phase: 'minimal_write_error',
      error: error,
      stackTrace: stackTrace,
    );
  }
}

Future<void> persistRiderOwnedBootstrap({
  required rtdb.DatabaseReference rootRef,
  required String riderId,
  required Map<String, dynamic> userProfile,
  required Map<String, dynamic> verification,
  required Map<String, dynamic> deviceFingerprints,
  required String source,
}) async {
  final updates = buildRiderOwnedBootstrapUpdates(
    riderId: riderId,
    userProfile: userProfile,
    verification: verification,
    deviceFingerprints: deviceFingerprints,
  );
  final pathLabel =
      'users/$riderId + rider_verifications/$riderId + '
      'rider_device_fingerprints/$riderId';

  _logStartupRtdb(
    source: source,
    path: pathLabel,
    optional: false,
    phase: 'write_start',
  );
  try {
    await rootRef.update(updates);
    _logStartupRtdb(
      source: source,
      path: pathLabel,
      optional: false,
      phase: 'write_success',
    );
  } catch (error, stackTrace) {
    _logStartupRtdb(
      source: source,
      path: pathLabel,
      optional: false,
      phase: 'write_error',
      error: error,
      stackTrace: stackTrace,
    );
    throw StartupRtdbException(
      source: source,
      path: pathLabel,
      requiredRead: false,
      cause: error,
    );
  }
}

Map<String, Object?> buildRiderOwnedBootstrapUpdates({
  required String riderId,
  required Map<String, dynamic> userProfile,
  required Map<String, dynamic> verification,
  required Map<String, dynamic> deviceFingerprints,
}) {
  final createdAt =
      userProfile['created_at'] ??
      deviceFingerprints['createdAt'] ??
      rtdb.ServerValue.timestamp;
  final deviceFingerprintRecord = <String, Object?>{
    ...deviceFingerprints,
    'riderId': riderId,
    'createdAt': deviceFingerprints['createdAt'] ?? createdAt,
    'updatedAt': rtdb.ServerValue.timestamp,
  };

  return <String, Object?>{
    'users/$riderId/uid': riderId,
    'users/$riderId/name': _safeText(userProfile['name'], fallback: 'Rider'),
    'users/$riderId/email': _safeText(userProfile['email']),
    'users/$riderId/phone': _safeText(userProfile['phone']),
    'users/$riderId/role': _safeText(userProfile['role'], fallback: 'rider'),
    'users/$riderId/verification': verification,
    'users/$riderId/installFingerprint': _safeText(
      deviceFingerprints['installFingerprint'],
    ),
    'users/$riderId/created_at': createdAt,
    'users/$riderId/updated_at': rtdb.ServerValue.timestamp,
    'rider_verifications/$riderId': <String, Object?>{
      'riderId': riderId,
      ...verification,
      'createdAt': verification['createdAt'] ?? createdAt,
      'updatedAt': rtdb.ServerValue.timestamp,
    },
    'rider_device_fingerprints/$riderId': deviceFingerprintRecord,
  };
}

/// User-visible copy stays friendly; logs carry technical detail.
String startupDebugMessage(
  String userFacingMessage, {
  required String path,
  required Object error,
}) {
  debugPrint(
    '[Startup RTDB/user] message=$userFacingMessage path=$path error=$error',
  );
  return userFacingMessage;
}

bool isPermissionDeniedError(Object error) {
  return error.toString().toLowerCase().contains('permission-denied');
}

String _safeText(dynamic value, {String fallback = ''}) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? fallback : text;
}

void _logStartupRtdb({
  required String source,
  required String path,
  required bool optional,
  required String phase,
  Object? error,
  StackTrace? stackTrace,
}) {
  if (!kDebugMode) {
    return;
  }

  final uid = FirebaseAuth.instance.currentUser?.uid ?? 'unauthenticated';
  final permissionDenied = error != null && isPermissionDeniedError(error);
  debugPrint(
    '[RTDB startup][$phase] source=$source path=$path uid=$uid '
    'optional=$optional'
    '${error == null ? '' : ' error=$error'}',
  );
  if (optional && permissionDenied) {
    debugPrint(
      '[RTDB startup][fallback] source=$source path=$path '
      'reason=permission_denied using_defaults=true',
    );
    return;
  }
  if (error != null && stackTrace != null) {
    debugPrintStack(
      label: '[RTDB startup][$phase] source=$source path=$path',
      stackTrace: stackTrace,
    );
  }
}

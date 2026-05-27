import 'package:firebase_auth/firebase_auth.dart'
    show FirebaseAuth, FirebaseException;
import 'package:flutter/foundation.dart';

import 'realtime_database_write_queue.dart';

typedef RealtimeDatabaseAction<T> = Future<T> Function();

/// Server-authoritative keys under `drivers/{uid}` — client writes are denied by RTDB rules.
const Set<String> kDriverProfileBlockedRootKeys = {
  'canonical_market_id',
  'dispatch_market_id',
  'resolved_dispatch_market_id',
  'market_pool',
  'market',
  'city',
  'dispatch_market',
};

/// Blocked under `drivers/{uid}/service_area/*`.
const Set<String> kDriverProfileBlockedServiceAreaKeys = {
  'canonical_market_id',
  'dispatch_market_id',
  'market',
};

/// Removes dispatch-canonical fields before client profile writes.
Map<String, Object?> sanitizeDriverProfileRtdbUpdate(
  Map<String, Object?> updates,
) {
  final sanitized = Map<String, Object?>.from(updates);
  for (final key in kDriverProfileBlockedRootKeys) {
    sanitized.remove(key);
  }
  final serviceArea = sanitized['service_area'];
  if (serviceArea is Map) {
    final sa = Map<String, Object?>.from(serviceArea);
    for (final key in kDriverProfileBlockedServiceAreaKeys) {
      sa.remove(key);
    }
    sanitized['service_area'] = sa;
  }
  return sanitized;
}

/// Emits auth context before RTDB operations (always on).
void logRtdbAuthContext({String? role, String? path}) {
  final uid = FirebaseAuth.instance.currentUser?.uid ?? 'none';
  debugPrint('[AUTH_UID] uid=$uid');
  debugPrint('[AUTH_ROLE] role=${role ?? 'unknown'}');
  if (path != null && path.isNotEmpty) {
    debugPrint('[RTDB_PATH] path=$path');
  }
}

/// Structured log for RTDB permission failures (always emitted, not debug-only).
void logRtdbPermissionDenied({
  required String path,
  required String source,
  String? uid,
  Object? error,
}) {
  final authUid =
      uid ?? FirebaseAuth.instance.currentUser?.uid ?? 'unauthenticated';
  logRtdbAuthContext();
  debugPrint(
    '[RTDB_PERMISSION_DENIED] path=$path source=$source uid=$authUid'
    '${error == null ? '' : ' error=$error'}',
  );
}

/// Best-effort optional RTDB side write. Never throws; permission-denied is silent.
Future<void> runSilentOptionalWrite(
  Future<void> Function() op, {
  required String tag,
}) async {
  try {
    await op();
  } catch (e) {
    if (isRealtimeDatabasePermissionDenied(e)) {
      return;
    }
    final text = e.toString().toLowerCase();
    final permissionDenied = text.contains('permission-denied') ||
        text.contains('permission denied');
    if (!permissionDenied) {
      debugPrint('[$tag] optional write failed: $e');
    }
  }
}

bool isRealtimeDatabasePermissionDenied(Object error) {
  if (error is FirebaseException) {
    final code = error.code.trim().toLowerCase();
    if (code == 'permission-denied' || code.endsWith('/permission-denied')) {
      return true;
    }
  }

  final message = error.toString().toLowerCase();
  return message.contains('firebase_database/permission-denied') ||
      message.contains('permission-denied') ||
      message.contains("doesn't have permission to access the desired data") ||
      message.contains('does not have permission to access the desired data');
}

Future<T> runInstrumentedRtdbRead<T>({
  required String path,
  required String source,
  required RealtimeDatabaseAction<T> action,
  String? role,
}) async {
  logRtdbAuthContext(role: role, path: path);
  debugPrint('[RTDB_READ_ATTEMPT] path=$path source=$source');
  try {
    final result = await action();
    return result;
  } catch (error, stackTrace) {
    if (isRealtimeDatabasePermissionDenied(error)) {
      logRtdbPermissionDenied(path: path, source: source, error: error);
    }
    if (kDebugMode) {
      debugPrintStack(
        label: '[RTDB_READ_ATTEMPT] path=$path source=$source',
        stackTrace: stackTrace,
      );
    }
    rethrow;
  }
}

Future<void> runInstrumentedRtdbUpdate({
  required String path,
  required String source,
  required Map<String, Object?> updates,
  required Future<void> Function(Map<String, Object?> sanitized) action,
  String? role,
  bool sanitizeDriverProfile = true,
}) async {
  logRtdbAuthContext(role: role, path: path);
  debugPrint(
    '[RTDB_WRITE_ATTEMPT] path=$path source=$source '
    'keys=${updates.keys.join(",")}',
  );
  final payload = sanitizeDriverProfile
      ? sanitizeDriverProfileRtdbUpdate(updates)
      : updates;
  try {
    await action(payload);
    debugPrint('[RTDB_WRITE_OK] path=$path source=$source');
  } catch (error, stackTrace) {
    if (isRealtimeDatabasePermissionDenied(error)) {
      logRtdbPermissionDenied(path: path, source: source, error: error);
    }
    if (kDebugMode) {
      debugPrintStack(
        label: '[RTDB_WRITE_ATTEMPT] path=$path source=$source',
        stackTrace: stackTrace,
      );
    }
    rethrow;
  }
}

Future<T> runRequiredRealtimeDatabaseRead<T>({
  required String source,
  required String path,
  required RealtimeDatabaseAction<T> action,
  String? role,
}) {
  return runInstrumentedRtdbRead<T>(
    path: path,
    source: source,
    role: role,
    action: action,
  );
}

/// Best-effort RTDB write (telemetry, secondary indexes). Logs permission-denied
/// without throwing so trip UX is not torn down by optional paths.
Future<bool> runOptionalRealtimeDatabaseWrite({
  required String source,
  required String path,
  required String operation,
  required RealtimeDatabaseAction<void> action,
  String? rideId,
  String? dedupeKey,
  String? role,
  bool sanitizeDriverProfile = false,
}) async {
  logRtdbAuthContext(role: role, path: path);
  debugPrint(
    '[RTDB_WRITE_ATTEMPT] path=$path source=$source operation=$operation',
  );
  var succeeded = false;
  await runSilentOptionalWrite(() async {
    await RealtimeDatabaseWriteQueue.instance.run<void>(
      source: source,
      dedupeKey: dedupeKey ?? '$source|$path|$operation',
      action: action,
    );
    succeeded = true;
  }, tag: source);
  if (succeeded) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? 'unauthenticated';
    debugPrint(
      '[RTDB_WRITE_OK] path=$path source=$source operation=$operation '
      'uid=$uid rideId=${rideId ?? 'n/a'}',
    );
  }
  return succeeded;
}

Future<T?> runOptionalRealtimeDatabaseRead<T>({
  required String source,
  required String path,
  required RealtimeDatabaseAction<T> action,
  String? role,
}) async {
  logRtdbAuthContext(role: role, path: path);
  debugPrint('[RTDB_READ_ATTEMPT] path=$path source=$source optional=true');
  try {
    final result = await action();
    return result;
  } catch (error, stackTrace) {
    if (isRealtimeDatabasePermissionDenied(error)) {
      logRtdbPermissionDenied(path: path, source: source, error: error);
    }
    if (kDebugMode) {
      debugPrintStack(
        label: '[RTDB_READ_ATTEMPT] path=$path source=$source',
        stackTrace: stackTrace,
      );
    }
    return null;
  }
}

void logRealtimeDatabaseStreamSubscription({
  required String source,
  required String path,
  bool optional = true,
  String? role,
}) {
  logRtdbAuthContext(role: role, path: path);
  debugPrint(
    '[RTDB_READ_ATTEMPT] path=$path source=$source stream_subscribe=true '
    'optional=$optional',
  );
}

String realtimeDatabaseDebugMessage(
  String fallback, {
  required String path,
  required Object error,
}) {
  if (!kDebugMode) {
    return fallback;
  }
  return '$fallback\n[$path] $error';
}

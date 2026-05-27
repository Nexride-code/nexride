import 'package:firebase_auth/firebase_auth.dart'
    show FirebaseAuth, FirebaseException;
import 'package:flutter/foundation.dart';

import 'realtime_database_write_queue.dart';

typedef RealtimeDatabaseAction<T> = Future<T> Function();

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
    return await action();
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
  required Future<void> Function(Map<String, Object?> payload) action,
  String? role,
}) async {
  logRtdbAuthContext(role: role, path: path);
  debugPrint(
    '[RTDB_WRITE_ATTEMPT] path=$path source=$source '
    'keys=${updates.keys.join(",")}',
  );
  try {
    await action(updates);
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

Future<bool> runOptionalRealtimeDatabaseWrite({
  required String source,
  required String path,
  required String operation,
  required RealtimeDatabaseAction<void> action,
  String? rideId,
  String? dedupeKey,
  String? role,
}) async {
  logRtdbAuthContext(role: role, path: path);
  debugPrint(
    '[RTDB_WRITE_ATTEMPT] path=$path source=$source operation=$operation',
  );
  var succeeded = false;
  try {
    await RealtimeDatabaseWriteQueue.instance.run<void>(
      source: source,
      dedupeKey: dedupeKey ?? '$source|$path|$operation',
      action: action,
    );
    succeeded = true;
  } catch (error) {
    if (isRealtimeDatabasePermissionDenied(error)) {
      logRtdbPermissionDenied(path: path, source: source, error: error);
      return false;
    }
    rethrow;
  }
  if (succeeded) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? 'unauthenticated';
    debugPrint(
      '[RTDB_WRITE_OK] path=$path source=$source operation=$operation '
      'uid=$uid rideId=${rideId ?? 'n/a'}',
    );
  }
  return succeeded;
}

void logRealtimeDatabaseStreamSubscription({
  required String source,
  required String path,
  String? role,
}) {
  logRtdbAuthContext(role: role, path: path);
  debugPrint(
    '[RTDB_READ_ATTEMPT] path=$path source=$source stream_subscribe=true',
  );
}

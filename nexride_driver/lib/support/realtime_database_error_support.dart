import 'package:firebase_auth/firebase_auth.dart'
    show FirebaseAuth, FirebaseException;
import 'package:flutter/foundation.dart';

typedef RealtimeDatabaseAction<T> = Future<T> Function();

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

Future<T> runRequiredRealtimeDatabaseRead<T>({
  required String source,
  required String path,
  required RealtimeDatabaseAction<T> action,
}) async {
  _logRealtimeDatabaseAccess(
    source: source,
    path: path,
    optional: false,
    phase: 'start',
  );
  try {
    final result = await action();
    _logRealtimeDatabaseAccess(
      source: source,
      path: path,
      optional: false,
      phase: 'success',
    );
    return result;
  } catch (error, stackTrace) {
    _logRealtimeDatabaseAccess(
      source: source,
      path: path,
      optional: false,
      phase: 'error',
      error: error,
      stackTrace: stackTrace,
    );
    rethrow;
  }
}

Future<T?> runOptionalRealtimeDatabaseRead<T>({
  required String source,
  required String path,
  required RealtimeDatabaseAction<T> action,
}) async {
  _logRealtimeDatabaseAccess(
    source: source,
    path: path,
    optional: true,
    phase: 'start',
  );
  try {
    final result = await action();
    _logRealtimeDatabaseAccess(
      source: source,
      path: path,
      optional: true,
      phase: 'success',
    );
    return result;
  } catch (error, stackTrace) {
    _logRealtimeDatabaseAccess(
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

void logRealtimeDatabaseStreamSubscription({
  required String source,
  required String path,
  bool optional = true,
}) {
  _logRealtimeDatabaseAccess(
    source: source,
    path: path,
    optional: optional,
    phase: 'stream_subscribe',
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

void _logRealtimeDatabaseAccess({
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
  debugPrint(
    '[RTDB][$phase] source=$source path=$path uid=$uid optional=$optional'
    '${error == null ? '' : ' error=$error'}',
  );
  if (error != null && stackTrace != null) {
    debugPrintStack(
      label: '[RTDB][$phase] source=$source path=$path',
      stackTrace: stackTrace,
    );
  }
}

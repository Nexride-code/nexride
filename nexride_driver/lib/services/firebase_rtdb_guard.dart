import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

Future<User> waitForAuthenticatedUser({
  Duration timeout = const Duration(seconds: 15),
}) async {
  final current = FirebaseAuth.instance.currentUser;
  if (current != null) {
    return current;
  }

  final completer = Completer<User>();
  late final StreamSubscription<User?> sub;
  sub = FirebaseAuth.instance.authStateChanges().listen((user) {
    if (!completer.isCompleted && user != null) {
      completer.complete(user);
    }
  });

  try {
    return await completer.future.timeout(timeout);
  } finally {
    await sub.cancel();
  }
}

Future<T> runWithDatabaseRetry<T>({
  required String label,
  required Future<T> Function() action,
  int maxAttempts = 3,
  Duration initialDelay = const Duration(milliseconds: 350),
}) async {
  Object? lastError;
  var delay = initialDelay;

  for (var attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      return await action();
    } catch (error, stackTrace) {
      lastError = error;
      debugPrint(
        '[RTDB_RETRY] label=$label attempt=$attempt/$maxAttempts error=$error',
      );
      if (kDebugMode) {
        debugPrintStack(
          label: '[RTDB_RETRY] label=$label attempt=$attempt',
          stackTrace: stackTrace,
        );
      }
      if (attempt == maxAttempts) {
        rethrow;
      }
      await Future<void>.delayed(delay);
      delay *= 2;
    }
  }

  throw StateError('Unexpected retry failure: $label error=$lastError');
}

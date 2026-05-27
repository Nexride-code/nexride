import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../firebase_options.dart';

/// Idempotent rider Firebase bootstrap — safe across relaunch, retry, and races.
class RiderFirebaseInit {
  RiderFirebaseInit._();

  static Future<void>? _ensureFuture;

  /// Ensures the default Firebase app is ready. Concurrent callers share one init.
  static Future<void> ensure() {
    return _ensureFuture ??= _ensureOnce();
  }

  /// Clears the in-flight init so [ensure] can run again (bootstrap retry).
  static void resetForRetry() {
    _ensureFuture = null;
  }

  static Future<void> _ensureOnce() async {
    await _ensureDefaultApp();
    _configureRtdbPersistence();
  }

  static Future<FirebaseApp> _ensureDefaultApp() async {
    if (Firebase.apps.isNotEmpty) {
      final app = Firebase.app();
      debugPrint(
        'FIREBASE_INIT_REUSE app=${app.name} apps=${Firebase.apps.length}',
      );
      return app;
    }

    try {
      debugPrint('FIREBASE_INIT_CREATE app=[DEFAULT]');
      return await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      ).timeout(const Duration(seconds: 12));
    } catch (error) {
      if (!_isDuplicateAppError(error)) {
        _ensureFuture = null;
        rethrow;
      }
      debugPrint('FIREBASE_INIT_REUSE duplicate-app recovered error=$error');
      if (Firebase.apps.isNotEmpty) {
        return Firebase.app();
      }
      // Native default may exist before the Dart app registry is populated.
      return Firebase.app();
    }
  }

  static void _configureRtdbPersistence() {
    try {
      final database = FirebaseDatabase.instance;
      database.setPersistenceEnabled(true);
      database.setPersistenceCacheSizeBytes(10000000);
    } catch (e) {
      debugPrint('RTDB_PERSISTENCE_NON_FATAL error=$e');
    }
  }

  static bool _isDuplicateAppError(Object error) {
    if (error is FirebaseException && error.code == 'duplicate-app') {
      return true;
    }
    if (error is PlatformException) {
      final code = error.code.toLowerCase();
      final message = (error.message ?? '').toLowerCase();
      if (code.contains('duplicate') || message.contains('duplicate')) {
        return true;
      }
    }
    final text = error.toString();
    return text.contains('[core/duplicate-app]') ||
        text.contains('duplicate-app') ||
        text.contains('already exists');
  }
}

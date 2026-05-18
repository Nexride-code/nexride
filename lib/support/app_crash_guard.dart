import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../widgets/rider_startup_error_screen.dart';

bool _riderAppRendered = false;

/// Call after the first MaterialApp frame is scheduled.
void markRiderAppRendered() {
  _riderAppRendered = true;
}

bool get riderAppHasRendered => _riderAppRendered;

/// Top-level crash guard for rider app startup.
void configureRiderCrashGuard() {
  FlutterError.onError = (FlutterErrorDetails details) {
    debugPrint('RIDER_CRASH_GUARD ${details.exception}');
    if (details.stack != null) {
      debugPrintStack(
        label: 'RIDER_CRASH_GUARD flutter',
        stackTrace: details.stack,
      );
    }
    if (!_riderAppRendered) {
      runFatalRiderStartupApp(details.exception, details.stack);
      return;
    }
    if (kDebugMode) {
      FlutterError.presentError(details);
    }
  };

  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    debugPrint('RIDER_CRASH_GUARD $error');
    debugPrintStack(label: 'RIDER_CRASH_GUARD platform', stackTrace: stack);
    if (!_riderAppRendered) {
      runFatalRiderStartupApp(error, stack);
    }
    return true;
  };
}

void runFatalRiderStartupApp(Object error, StackTrace? stack) {
  try {
    WidgetsFlutterBinding.ensureInitialized();
  } catch (_) {}
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: RiderStartupErrorScreen(
        error: error,
        stackTrace: stack,
        onRetry: () {
          debugPrint('RIDER_STARTUP_RETRY requested after fatal error');
        },
      ),
    ),
  );
  markRiderAppRendered();
}

/// Runs [body] inside [runZonedGuarded] with async error logging.
void runRiderAppGuarded(Future<void> Function() body) {
  runZonedGuarded(
    () {
      unawaited(
        body().catchError((Object error, StackTrace stack) {
          startupError('bootstrap_uncaught', error, stackTrace: stack);
          if (!_riderAppRendered) {
            runFatalRiderStartupApp(error, stack);
          }
        }),
      );
    },
    (Object error, StackTrace stack) {
      startupError('zone_uncaught', error, stackTrace: stack);
      debugPrintStack(label: 'RIDER_CRASH_GUARD zone', stackTrace: stack);
      if (!_riderAppRendered) {
        runFatalRiderStartupApp(error, stack);
      }
    },
  );
}

void startupStep(
  String step, {
  Map<String, Object?> fields = const <String, Object?>{},
}) {
  final extras = fields.entries
      .where((e) => e.value != null)
      .map((e) => '${e.key}=${e.value}')
      .join(' ');
  if (extras.isEmpty) {
    debugPrint('STARTUP_STEP step=$step');
  } else {
    debugPrint('STARTUP_STEP step=$step $extras');
  }
}

void startupError(
  String step,
  Object error, {
  StackTrace? stackTrace,
  Map<String, Object?> fields = const <String, Object?>{},
}) {
  final extras = fields.entries
      .where((e) => e.value != null)
      .map((e) => '${e.key}=${e.value}')
      .join(' ');
  debugPrint(
    'STARTUP_ERROR step=$step error=$error${extras.isEmpty ? '' : ' $extras'}',
  );
  if (stackTrace != null) {
    debugPrintStack(label: 'STARTUP_ERROR step=$step', stackTrace: stackTrace);
  }
}

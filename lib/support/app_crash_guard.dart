import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

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
    FlutterError.presentError(details);
  };

  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    debugPrint('RIDER_CRASH_GUARD $error');
    debugPrintStack(label: 'RIDER_CRASH_GUARD platform', stackTrace: stack);
    return true;
  };
}

/// Runs [body] inside [runZonedGuarded] with async error logging.
void runRiderAppGuarded(Future<void> Function() body) {
  runZonedGuarded(
    () {
      unawaited(body());
    },
    (Object error, StackTrace stack) {
      startupError('zone_uncaught', error);
      debugPrintStack(label: 'RIDER_CRASH_GUARD zone', stackTrace: stack);
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

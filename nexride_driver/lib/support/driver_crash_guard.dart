import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'driver_startup_logs.dart';

/// Top-level crash guard for the driver app.
void configureDriverCrashGuard() {
  FlutterError.onError = (FlutterErrorDetails details) {
    driverFlowLog('DRIVER_CRASH_GUARD', {
      'kind': 'flutter_error',
      'error': details.exception.toString(),
    });
    if (details.stack != null) {
      debugPrintStack(
        label: 'DRIVER_CRASH_GUARD flutter',
        stackTrace: details.stack,
      );
    }
    FlutterError.presentError(details);
  };

  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    driverFlowLog('DRIVER_CRASH_GUARD', {
      'kind': 'platform_error',
      'error': error.toString(),
    });
    debugPrintStack(label: 'DRIVER_CRASH_GUARD platform', stackTrace: stack);
    return true;
  };
}

/// Runs [body] inside [runZonedGuarded] with async error logging.
void runDriverAppGuarded(Future<void> Function() body) {
  runZonedGuarded(
    () {
      unawaited(body());
    },
    (Object error, StackTrace stack) {
      driverStartupError('zone_uncaught', error);
      debugPrintStack(label: 'DRIVER_CRASH_GUARD zone', stackTrace: stack);
    },
  );
}

void driverStartupStep(
  String step, {
  Map<String, Object?> fields = const <String, Object?>{},
}) {
  driverFlowLog('DRIVER_STARTUP_STEP', {'step': step, ...fields});
}

void driverStartupError(
  String step,
  Object error, {
  StackTrace? stackTrace,
  Map<String, Object?> fields = const <String, Object?>{},
}) {
  driverFlowLog(
    'DRIVER_STARTUP_ERROR',
    {
      'step': step,
      'error': error.toString(),
      if (stackTrace != null) 'stack': stackTrace.toString(),
      ...fields,
    },
  );
}

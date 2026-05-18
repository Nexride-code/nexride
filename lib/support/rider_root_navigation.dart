import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../nex_ride_app.dart';

/// Pushes [page] on the root navigator after the current frame (avoids `!_debugLocked`).
Future<T?> riderRootPush<T extends Object?>(
  Widget page, {
  String logTag = 'RIDER_ROOT_NAV_PUSH',
}) async {
  await SchedulerBinding.instance.endOfFrame;
  final navigator = rootNavigatorKey.currentState;
  if (navigator == null) {
    debugPrint('${logTag}_FAIL reason=navigator_null');
    return null;
  }
  try {
    return await navigator.push<T>(
      MaterialPageRoute<T>(builder: (_) => page),
    );
  } catch (error, stackTrace) {
    debugPrint('${logTag}_FAIL error=$error');
    debugPrintStack(label: logTag, stackTrace: stackTrace);
    rethrow;
  }
}

/// Replaces the entire root stack with [page] after the current frame.
Future<void> riderRootReplaceAll(
  Widget page, {
  String logTag = 'RIDER_ROOT_NAV_REPLACE',
}) async {
  await SchedulerBinding.instance.endOfFrame;
  final navigator = rootNavigatorKey.currentState;
  if (navigator == null) {
    debugPrint('${logTag}_FAIL reason=navigator_null');
    return;
  }
  try {
    await navigator.pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => page),
      (route) => false,
    );
  } catch (error, stackTrace) {
    debugPrint('${logTag}_FAIL error=$error');
    debugPrintStack(label: logTag, stackTrace: stackTrace);
    rethrow;
  }
}

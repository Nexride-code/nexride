import 'package:flutter/foundation.dart';

import 'startup_rtdb_support.dart' show isPermissionDeniedError;

/// Best-effort optional RTDB side write. Never throws; permission-denied is silent.
Future<void> runSilentOptionalWrite(
  Future<void> Function() op, {
  required String tag,
}) async {
  try {
    await op();
  } catch (e) {
    if (isPermissionDeniedError(e)) {
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

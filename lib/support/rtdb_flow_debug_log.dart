import 'package:flutter/foundation.dart';

/// Temporary structured logs for rider/driver RTDB flows (debug only).
void rtdbFlowLog(String tag, String details) {
  if (kDebugMode) {
    debugPrint('$tag $details');
  }
}

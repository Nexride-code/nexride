import 'package:flutter/foundation.dart';

/// Debug-only guardrails for admin list surfaces ([AdminPerf]).
void adminPerfWarnRowBudget({
  required String surface,
  required int rowCount,
  int softLimit = 100,
}) {
  if (!kDebugMode) {
    return;
  }
  if (rowCount > softLimit) {
    debugPrint(
      '[AdminPerf][ROW_BUDGET] surface=$surface rows=$rowCount '
      'softLimit=$softLimit — use server pagination / smaller pages / virtualization.',
    );
  }
}

const int _adminPayloadSoftBytes = 100 * 1024;
const int _adminPayloadHardBytes = 1024 * 1024;

/// Phase 3M: approximate JSON UTF-8 size (debug) for callable payloads.
void adminPerfWarnPayloadApprox({
  required String surface,
  required String callableName,
  required int approxUtf8Bytes,
}) {
  if (!kDebugMode) {
    return;
  }
  if (approxUtf8Bytes >= _adminPayloadHardBytes) {
    debugPrint(
      '[AdminPerf][PAYLOAD_WARN] surface=$surface callable=$callableName '
      'bytes=$approxUtf8Bytes (>=${_adminPayloadHardBytes ~/ 1024}KB hard cap)',
    );
  } else if (approxUtf8Bytes > _adminPayloadSoftBytes) {
    debugPrint(
      '[AdminPerf][PAYLOAD_WARN] surface=$surface callable=$callableName '
      'bytes=$approxUtf8Bytes (soft target ${_adminPayloadSoftBytes ~/ 1024}KB)',
    );
  }
}

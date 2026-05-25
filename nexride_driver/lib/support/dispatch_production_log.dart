import 'package:flutter/foundation.dart';

/// Verbose dispatch/discovery traces (logcat filters, RTDB attach spam).
/// Off in release unless explicitly enabled for QA.
const bool dispatchVerboseLogsEnabled = false;

bool get _dispatchVerbose => kDebugMode || dispatchVerboseLogsEnabled;

/// Gated debug-only dispatch logs (discovery attach, RTDB traces, accept debug).
void dispatchVerboseLog(String message) {
  if (_dispatchVerbose) {
    debugPrint(message);
  }
}

/// Alias for dispatch paths migrating off raw debugPrint/print.
void dispatchDebugLog(String message) => dispatchVerboseLog(message);

/// Allowed production dispatch events (always emitted).
const Set<String> _dispatchProdEvents = <String>{
  'OFFER_RECEIVED',
  'OFFER_ACCEPTED',
  'OFFER_EXPIRED',
  'MATCH_ASSIGNED',
  'ACCEPT_FAILED',
  'MATCH_TIMEOUT',
};

void dispatchOfferEvent(
  String event, {
  String? rideId,
  String? detail,
}) {
  if (!_dispatchProdEvents.contains(event)) {
    return;
  }
  final rid = rideId?.trim() ?? '';
  final extra = detail?.trim() ?? '';
  if (rid.isEmpty && extra.isEmpty) {
    debugPrint(event);
    return;
  }
  if (extra.isEmpty) {
    debugPrint('$event rideId=$rid');
    return;
  }
  debugPrint('$event rideId=$rid $extra');
}

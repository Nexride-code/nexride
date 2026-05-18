import 'package:flutter/foundation.dart';

/// Structured driver startup / listener diagnostics for production triage.
void driverRestoreLog(
  String event, {
  String? rideId,
  String? deliveryId,
  String? source,
  String? state,
}) {
  driverFlowLog(event, <String, Object?>{
    if (rideId != null && rideId.isNotEmpty) 'rideId': rideId,
    if (deliveryId != null && deliveryId.isNotEmpty) 'deliveryId': deliveryId,
    if (source != null && source.isNotEmpty) 'source': source,
    if (state != null && state.isNotEmpty) 'state': state,
  });
}

void driverFlowLog(String event, [Map<String, Object?> fields = const {}]) {
  final extras = fields.entries
      .where((e) => e.value != null)
      .map((e) => '${e.key}=${e.value}')
      .join(' ');
  if (extras.isEmpty) {
    debugPrint('$event');
  } else {
    debugPrint('$event $extras');
  }
}

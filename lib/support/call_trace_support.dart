import 'package:flutter/foundation.dart';

/// Standard voice-call trace lines for rider/driver log diagnosis.
void callTraceLog(
  String event, {
  required String rideId,
  required String role,
  String? channel,
  String? uid,
  int? remoteUid,
  String? error,
  int? elapsedMs,
  bool? speakerOn,
  bool? muted,
}) {
  final normalizedRideId = rideId.trim();
  final normalizedRole = role.trim();
  if (normalizedRideId.isEmpty || normalizedRole.isEmpty) {
    return;
  }

  final parts = <String>[
    event,
    'rideId=$normalizedRideId',
    'role=$normalizedRole',
  ];
  final normalizedChannel = channel?.trim();
  if (normalizedChannel != null && normalizedChannel.isNotEmpty) {
    parts.add('channel=$normalizedChannel');
  }
  final normalizedUid = uid?.trim();
  if (normalizedUid != null && normalizedUid.isNotEmpty) {
    parts.add('uid=$normalizedUid');
  }
  if (remoteUid != null) {
    parts.add('remoteUid=$remoteUid');
  }
  if (elapsedMs != null) {
    parts.add('elapsedMs=$elapsedMs');
  }
  if (speakerOn != null) {
    parts.add('speaker=${speakerOn ? 'on' : 'off'}');
  }
  if (muted != null) {
    parts.add('mic=${muted ? 'muted' : 'live'}');
  }
  final normalizedError = error?.trim();
  if (normalizedError != null && normalizedError.isNotEmpty) {
    parts.add('error=$normalizedError');
  }

  debugPrint(parts.join(' '));
}

/// Temporary production diagnostics — log before every local call teardown.
void callCleanupDiagnostics({
  required String cleanupSource,
  required String endReason,
  required String rideId,
  required String role,
  String? rtdbState,
  String? remoteState,
}) {
  final normalizedRideId = rideId.trim();
  final normalizedRole = role.trim();
  if (normalizedRideId.isEmpty || normalizedRole.isEmpty) {
    return;
  }
  debugPrint(
    'CALL_CLEANUP_SOURCE rideId=$normalizedRideId role=$normalizedRole '
    'source=$cleanupSource',
  );
  debugPrint(
    'CALL_END_REASON rideId=$normalizedRideId role=$normalizedRole '
    'reason=$endReason',
  );
  debugPrint(
    'CALL_RTDB_STATE rideId=$normalizedRideId role=$normalizedRole '
    'state=${rtdbState ?? 'unknown'}',
  );
  debugPrint(
    'CALL_REMOTE_STATE rideId=$normalizedRideId role=$normalizedRole '
    'state=${remoteState ?? 'unknown'}',
  );
}

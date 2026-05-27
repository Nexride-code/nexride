import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Structured end-to-end trace logging for NexRide stabilization.
class NexTrace {
  NexTrace._();

  static final Map<String, int> _marks = <String, int>{};

  static void mark(String key) {
    _marks[key] = DateTime.now().millisecondsSinceEpoch;
  }

  static int? elapsedMs(String key) {
    final start = _marks[key];
    if (start == null) {
      return null;
    }
    return DateTime.now().millisecondsSinceEpoch - start;
  }

  static void log({
    required String event,
    String? rideId,
    String? uid,
    String? role,
    String? path,
    String? tripState,
    String? status,
    String? listenerOwner,
    String? source,
    int? elapsedMs,
    Map<String, String>? extra,
  }) {
    final resolvedUid = uid ?? FirebaseAuth.instance.currentUser?.uid ?? '';
    final buffer = StringBuffer('[TRACE]\n')
      ..write('event=$event\n')
      ..write('rideId=${rideId ?? ''}\n')
      ..write('uid=$resolvedUid\n')
      ..write('role=${role ?? ''}\n')
      ..write('path=${path ?? ''}\n')
      ..write('trip_state=${tripState ?? ''}\n')
      ..write('status=${status ?? ''}\n')
      ..write('listener_owner=${listenerOwner ?? ''}\n')
      ..write('source=${source ?? ''}\n')
      ..write('elapsedMs=${elapsedMs ?? ''}');
    if (extra != null && extra.isNotEmpty) {
      for (final entry in extra.entries) {
        buffer.write('\n${entry.key}=${entry.value}');
      }
    }
    debugPrint(buffer.toString());
  }

  static void rtdbListenerAttach({
    required String path,
    required String listenerOwner,
    String? rideId,
    String? role,
    String? source,
  }) {
    log(
      event: 'RTDB_LISTENER_ATTACH',
      rideId: rideId,
      role: role,
      path: path,
      listenerOwner: listenerOwner,
      source: source,
    );
  }

  static void rtdbListenerDispose({
    required String path,
    required String listenerOwner,
    String? rideId,
    String? role,
    String? source,
  }) {
    log(
      event: 'RTDB_LISTENER_DISPOSE',
      rideId: rideId,
      role: role,
      path: path,
      listenerOwner: listenerOwner,
      source: source,
    );
  }

  static void rtdbWrite({
    required String path,
    String? rideId,
    String? role,
    String? tripState,
    String? status,
    String? source,
    int? elapsedMs,
  }) {
    log(
      event: 'RTDB_WRITE',
      rideId: rideId,
      role: role,
      path: path,
      tripState: tripState,
      status: status,
      source: source,
      elapsedMs: elapsedMs,
    );
  }

  static void rtdbRead({
    required String path,
    String? rideId,
    String? role,
    String? source,
    int? elapsedMs,
  }) {
    log(
      event: 'RTDB_READ',
      rideId: rideId,
      role: role,
      path: path,
      source: source,
      elapsedMs: elapsedMs,
    );
  }

  static void rtdbPermissionDenied({
    required String path,
    String? rideId,
    String? role,
    String? source,
    Object? error,
  }) {
    log(
      event: 'RTDB_PERMISSION_DENIED',
      rideId: rideId,
      role: role,
      path: path,
      source: source,
      extra: error == null ? null : <String, String>{'error': error.toString()},
    );
  }
}

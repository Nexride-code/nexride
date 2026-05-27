import 'package:flutter/foundation.dart';

import '../trip_sync/trip_state_machine.dart';
import 'nex_trace.dart';

/// Validates whether a driver may hydrate UI from [ride_requests/{rideId}].
///
/// Pointers ([driver_active_ride], [drivers.activeRideId]) are hints only;
/// canonical lifecycle always comes from the ride document.
class DriverActiveRideRestoreSupport {
  DriverActiveRideRestoreSupport._();

  /// Mirrors server [ASSIGNED_NOT_STARTED_STALE_MS].
  static const Duration assignedStaleTtl = Duration(minutes: 3);

  /// Mirrors server [ENROUTE_IN_TRIP_STALE_MS] for arrived / on_trip.
  static const Duration enrouteStaleTtl = Duration(minutes: 30);

  /// Hard cap for any startup restore hydration.
  static const Duration hardRestoreMaxAge = Duration(hours: 2);

  static const Set<String> _driverRestorableStates = <String>{
    TripLifecycleState.assigned,
    TripLifecycleState.arrived,
    TripLifecycleState.onTrip,
  };

  static const Set<String> _terminalStatusTokens = <String>{
    'cancelled',
    'canceled',
    'completed',
    'trip_completed',
    'payment_completed',
    'ended',
    'expired',
    'no_show',
    'no-show',
    'driver_cancelled',
    'rider_cancelled',
  };

  static void traceStartupCheck({required String driverId, String? source}) {
    NexTrace.log(
      event: 'DRIVER_STARTUP_ACTIVE_RIDE_CHECK',
      uid: driverId,
      role: 'driver',
      source: source ?? 'driver_startup',
    );
  }

  static void tracePointerFound({
    required String driverId,
    required String rideId,
    int? pointerUpdatedAt,
    String? source,
  }) {
    NexTrace.log(
      event: 'DRIVER_ACTIVE_RIDE_POINTER_FOUND',
      rideId: rideId,
      uid: driverId,
      role: 'driver',
      source: source ?? 'driver_startup',
      extra: <String, String>{
        if (pointerUpdatedAt != null && pointerUpdatedAt > 0)
          'pointer_updated_at': '$pointerUpdatedAt',
      },
    );
    debugPrint(
      '[TRACE][DRIVER_ACTIVE_RIDE_POINTER_FOUND] uid=$driverId rideId=$rideId',
    );
  }

  static void traceValidated({
    required String driverId,
    required String rideId,
    required String tripState,
    String? source,
  }) {
    NexTrace.log(
      event: 'DRIVER_ACTIVE_RIDE_VALIDATED',
      rideId: rideId,
      uid: driverId,
      role: 'driver',
      tripState: tripState,
      source: source ?? 'driver_startup',
    );
    debugPrint(
      '[TRACE][DRIVER_ACTIVE_RIDE_VALIDATED] uid=$driverId rideId=$rideId trip_state=$tripState',
    );
  }

  static void traceStale({
    required String driverId,
    required String rideId,
    required String reason,
    String? source,
  }) {
    NexTrace.log(
      event: 'DRIVER_ACTIVE_RIDE_STALE',
      rideId: rideId,
      uid: driverId,
      role: 'driver',
      source: source ?? 'driver_startup',
      extra: <String, String>{'reason': reason},
    );
    debugPrint(
      '[TRACE][DRIVER_ACTIVE_RIDE_STALE] uid=$driverId rideId=$rideId reason=$reason',
    );
  }

  static void traceCleared({
    required String driverId,
    String? rideId,
    required String reason,
    String? source,
  }) {
    NexTrace.log(
      event: 'DRIVER_ACTIVE_RIDE_CLEARED',
      rideId: rideId,
      uid: driverId,
      role: 'driver',
      source: source ?? 'driver_startup',
      extra: <String, String>{'reason': reason},
    );
    debugPrint(
      '[TRACE][DRIVER_ACTIVE_RIDE_CLEARED] uid=$driverId rideId=${rideId ?? ''} reason=$reason',
    );
  }

  static void traceUiRestored({
    required String driverId,
    required String rideId,
    required String tripState,
    String? source,
  }) {
    NexTrace.log(
      event: 'DRIVER_ACTIVE_RIDE_UI_RESTORED',
      rideId: rideId,
      uid: driverId,
      role: 'driver',
      tripState: tripState,
      source: source ?? 'driver_startup',
    );
    debugPrint(
      '[TRACE][DRIVER_ACTIVE_RIDE_UI_RESTORED] uid=$driverId rideId=$rideId trip_state=$tripState',
    );
  }

  static void logRestoreCandidate({
    required String rideId,
    required String state,
    required String status,
    required String api,
    required String socket,
    required int updatedAt,
  }) {
    debugPrint(
      'DRIVER_RESTORE_CANDIDATE rideId=$rideId state=$state status=$status '
      'api=$api socket=$socket updatedAt=$updatedAt',
    );
  }

  static void logRestoreReject({
    required String rideId,
    required String reason,
  }) {
    debugPrint('DRIVER_RESTORE_REJECT rideId=$rideId reason=$reason');
  }

  static void logRestoreClearLocal({
    required String rideId,
    required String reason,
  }) {
    debugPrint('DRIVER_RESTORE_CLEAR_LOCAL rideId=$rideId reason=$reason');
  }

  static void logRestoreAccept({
    required String rideId,
    required String state,
    required String status,
  }) {
    debugPrint(
      'DRIVER_RESTORE_ACCEPT rideId=$rideId state=$state status=$status',
    );
  }

  /// Returns a rejection reason when the ride must not hydrate UI; null if OK.
  static String? staleRestoreReason({
    required Map<String, dynamic> rideData,
    required String driverId,
    required String rideId,
    bool localSessionExplicitlyCleared = false,
    String? apiStatus,
    String? socketStatus,
  }) {
    final normalizedDriverId = driverId.trim();
    final normalizedRideId = rideId.trim();
    if (normalizedDriverId.isEmpty) {
      return 'missing_driver_id';
    }
    if (normalizedRideId.isEmpty) {
      return 'ride_id_missing';
    }

    if (localSessionExplicitlyCleared) {
      return 'local_session_explicitly_cleared';
    }

    if (!_isAssignedToDriver(rideData, normalizedDriverId)) {
      return 'driver_mismatch';
    }

    if (_rideSnapshotIndicatesTerminal(rideData)) {
      final canon = TripStateMachine.canonicalStateFromSnapshot(rideData);
      return 'terminal_$canon';
    }

    final canon = TripStateMachine.normalizeTripState(rideData['trip_state']);
    if (!_driverRestorableStates.contains(canon)) {
      return 'non_restorable_$canon';
    }

    if (!TripStateMachine.isDriverActiveState(canon)) {
      return 'not_driver_active_$canon';
    }

    final lifecycleProof = TripStateMachine.lifecycleProofReason(
      rideData,
      canonicalState: canon,
    );
    if (lifecycleProof != null) {
      return lifecycleProof;
    }

    final referenceMs = _referenceActivityMs(rideData);
    if (referenceMs <= 0) {
      return 'missing_activity_timestamp';
    }

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final ageMs = nowMs - referenceMs;
    if (ageMs > hardRestoreMaxAge.inMilliseconds) {
      return 'stale_hard_cap_2h ageMs=$ageMs';
    }

    final ttl = _ttlForCanonicalState(canon);
    if (ageMs > ttl.inMilliseconds) {
      return 'stale_activity ageMs=$ageMs ttlMs=${ttl.inMilliseconds} trip_state=$canon';
    }

    if (canon == TripLifecycleState.arrived) {
      if (ageMs > enrouteStaleTtl.inMilliseconds) {
        return 'stale_arrived ageMs=$ageMs';
      }
      final riderId = rideData['rider_id']?.toString().trim() ?? '';
      if (riderId.isEmpty) {
        return 'stale_arrived_no_rider';
      }
    }

    final api = apiStatus?.trim().toLowerCase() ?? '';
    final socket = socketStatus?.trim().toLowerCase() ?? '';
    if (api == 'idle' && socket == 'active_trip') {
      return 'inconsistent_idle_api_active_trip_socket';
    }

    return null;
  }

  static int referenceActivityMs(Map<String, dynamic> ride) =>
      _referenceActivityMs(ride);

  static bool _rideSnapshotIndicatesTerminal(Map<String, dynamic> ride) {
    final canon = TripStateMachine.canonicalStateFromSnapshot(ride);
    if (TripStateMachine.isTerminal(canon)) {
      return true;
    }
    if (ride['trip_completed'] == true) {
      return true;
    }
    for (final key in <String>[
      'completed_at',
      'completedAt',
      'cancelled_at',
      'cancelledAt',
      'canceled_at',
      'canceledAt',
      'ended_at',
      'endedAt',
    ]) {
      final ts = _parsePositiveInt(ride[key]);
      if (ts != null && ts > 0) {
        return true;
      }
    }
    final status = TripStateMachine.uiStatusFromSnapshot(ride).trim().toLowerCase();
    final rawStatus = ride['status']?.toString().trim().toLowerCase() ?? '';
    final rawTripState = ride['trip_state']?.toString().trim().toLowerCase() ?? '';
    if (_terminalStatusTokens.contains(status) ||
        _terminalStatusTokens.contains(rawStatus) ||
        _terminalStatusTokens.contains(rawTripState)) {
      return true;
    }
    return false;
  }

  static bool _isAssignedToDriver(
    Map<String, dynamic> ride,
    String driverId,
  ) {
    for (final key in <String>[
      'driver_id',
      'matched_driver_id',
      'accepted_driver_id',
    ]) {
      final value = ride[key]?.toString().trim() ?? '';
      if (value.isNotEmpty && value == driverId) {
        return true;
      }
    }
    return false;
  }

  static int _referenceActivityMs(Map<String, dynamic> ride) {
    var best = 0;
    for (final key in <String>[
      'updated_at',
      'updated_at_ms',
      'last_seen_ms',
      'driver_last_seen_ms',
      'arrived_at',
      'arrivedAt',
      'driver_arrived_at',
      'started_at',
      'startedAt',
      'accepted_at',
      'accepted_at_ms',
      'acceptedAt',
      'driver_assigned_at',
      'driver_assigned_at_ms',
      'created_at',
      'createdAt',
    ]) {
      final ts = _parsePositiveInt(ride[key]);
      if (ts != null && ts > best) {
        best = ts;
      }
    }
    return best;
  }

  static Duration _ttlForCanonicalState(String canon) {
    switch (canon) {
      case TripLifecycleState.assigned:
        return assignedStaleTtl;
      case TripLifecycleState.arrived:
      case TripLifecycleState.onTrip:
        return enrouteStaleTtl;
      default:
        return hardRestoreMaxAge;
    }
  }

  static int? _parsePositiveInt(dynamic value) {
    if (value is num) {
      final n = value.toInt();
      return n > 0 ? n : null;
    }
    final parsed = int.tryParse(value?.toString() ?? '');
    if (parsed == null || parsed <= 0) {
      return null;
    }
    return parsed;
  }

  static int pointerUpdatedAtMs(Map<String, dynamic>? pointer) {
    if (pointer == null) {
      return 0;
    }
    return _parsePositiveInt(
          pointer['updated_at'] ?? pointer['updatedAt'],
        ) ??
        0;
  }

  static String? pointerRideId(Map<String, dynamic>? pointer) {
    if (pointer == null) {
      return null;
    }
    final rideId = pointer['ride_id']?.toString().trim() ??
        pointer['rideId']?.toString().trim() ??
        '';
    return rideId.isEmpty ? null : rideId;
  }
}

import 'dart:developer' as developer;

class TripLifecycleState {
  /// RTDB canonical `trip_state` values — sole lifecycle authority (Cloud Functions).
  static const String searching = 'searching';
  static const String assigned = 'assigned';
  static const String arrived = 'arrived';
  static const String onTrip = 'on_trip';
  static const String completed = 'completed';
  static const String cancelled = 'cancelled';
  static const String expired = 'expired';

  static const Set<String> all = <String>{
    searching,
    assigned,
    arrived,
    onTrip,
    completed,
    cancelled,
    expired,
  };

  /// UI-only — no matching `trip_state` in RTDB (no ride document loaded locally).
  static const String planning = 'planning';

  /// Legacy read aliases (normalize to canonical via [TripStateMachine.normalizeTripState]).
  static const String driverAssigned = assigned;
  static const String driverArriving = assigned;
  static const String inProgress = onTrip;
  static const String requested = searching;
  static const String searchingDriver = searching;
  static const String pendingDriverAction = assigned;
  static const String driverAccepted = assigned;
  static const String driverArrived = arrived;
  static const String tripStarted = onTrip;
  static const String tripCompleted = completed;
  static const String tripCancelled = cancelled;
}

class TripTimeoutCancellationDecision {
  const TripTimeoutCancellationDecision({
    required this.reason,
    required this.transitionSource,
    required this.cancelSource,
    required this.effectiveAt,
    required this.canonicalState,
    this.invalidTrip = false,
  });

  final String reason;
  final String transitionSource;
  final String cancelSource;
  final int effectiveAt;
  final String canonicalState;
  final bool invalidTrip;
}

class TripStateMachine {
  static const int schemaVersion = 2;
  static const Duration acceptedToStartTimeout = Duration(minutes: 10);
  static const Duration routeLogTimeout = Duration(minutes: 3);

  static const Set<String> restorableStates = <String>{
    TripLifecycleState.searching,
    TripLifecycleState.assigned,
    TripLifecycleState.arrived,
    TripLifecycleState.onTrip,
  };

  static const Set<String> activeDriverStates = <String>{
    TripLifecycleState.assigned,
    TripLifecycleState.arrived,
    TripLifecycleState.onTrip,
  };

  static const Set<String> terminalStates = <String>{
    TripLifecycleState.completed,
    TripLifecycleState.cancelled,
    TripLifecycleState.expired,
  };

  static const Map<String, Set<String>> _allowedTransitions =
      <String, Set<String>>{
    TripLifecycleState.searching: <String>{
      TripLifecycleState.assigned,
      TripLifecycleState.cancelled,
      TripLifecycleState.expired,
    },
    TripLifecycleState.assigned: <String>{
      TripLifecycleState.arrived,
      TripLifecycleState.cancelled,
    },
    TripLifecycleState.arrived: <String>{
      TripLifecycleState.onTrip,
      TripLifecycleState.cancelled,
    },
    TripLifecycleState.onTrip: <String>{
      TripLifecycleState.completed,
      TripLifecycleState.cancelled,
    },
    TripLifecycleState.completed: <String>{},
    TripLifecycleState.cancelled: <String>{},
    TripLifecycleState.expired: <String>{},
  };

  /// Normalize legacy RTDB tokens to canonical [trip_state] values.
  static String normalizeTripState(dynamic raw) {
    final token = _normalizeText(raw);
    return switch (token) {
      '' || 'idle' || 'requested' || 'requesting' => TripLifecycleState.searching,
      'searching_driver' ||
      'matching' ||
      'awaiting_match' ||
      'offered' ||
      'offer_pending' ||
      'pending_driver_action' ||
      'pending_driver_acceptance' ||
      'driver_reviewing_request' =>
        TripLifecycleState.searching,
      'assigned' ||
      'matched' ||
      'accepted' ||
      'driver_accepted' ||
      'driver_assigned' ||
      'driver_found' ||
      'driver_matched' ||
      'driver_arriving' ||
      'arriving' ||
      'enroute_to_pickup' =>
        TripLifecycleState.assigned,
      'arrived' || 'driver_arrived' => TripLifecycleState.arrived,
      'on_trip' ||
      'ontrip' ||
      'in_progress' ||
      'trip_started' =>
        TripLifecycleState.onTrip,
      'completed' || 'trip_completed' || 'complete' => TripLifecycleState.completed,
      'cancelled' ||
      'canceled' ||
      'trip_cancelled' ||
      'driver_cancelled' ||
      'rider_cancelled' =>
        TripLifecycleState.cancelled,
      'expired' => TripLifecycleState.expired,
      _ => TripLifecycleState.all.contains(token)
          ? token
          : TripLifecycleState.searching,
    };
  }

  /// Canonical lifecycle authority: [trip_state] on ride_requests / mirrors.
  static bool tripStateIndicatesArrived(dynamic tripState) {
    return normalizeTripState(tripState) == TripLifecycleState.arrived;
  }

  static bool tripStateIndicatesArrivedSnapshot(Map<String, dynamic>? rideData) {
    if (rideData == null || rideData.isEmpty) {
      return false;
    }
    return tripStateIndicatesArrived(
      rideData['trip_state'] ?? rideData['tripState'],
    );
  }

  static String canonicalStateFromSnapshot(Map<String, dynamic>? rideData) {
    if (rideData == null) {
      return canonicalStateFromValues(
        tripState: null,
        status: null,
        assignedDriverId: null,
      );
    }
    final d = _normalizeText(rideData['driver_id']);
    dynamic assignedDriverId = rideData['driver_id'];
    if (d.isEmpty ||
        d == 'waiting' ||
        d == 'pending' ||
        d == 'null' ||
        d == 'undefined' ||
        d == 'none') {
      assignedDriverId = rideData['matched_driver_id'] ??
          rideData['matchedDriverId'] ??
          rideData['accepted_driver_id'] ??
          rideData['acceptedDriverId'];
    }
    return canonicalStateFromValues(
      tripState: rideData['trip_state'],
      status: rideData['status'] ?? rideData['request_status'],
      assignedDriverId: assignedDriverId,
    );
  }

  /// Legacy [status] only — used when [trip_state] is absent or not a known canonical value.
  static String _canonicalFromLegacyNormalizedStatus(String normalizedStatus) {
    return switch (normalizedStatus) {
      '' || 'idle' => TripLifecycleState.searching,
      'requested' || 'requesting' => TripLifecycleState.searching,
      'searching' ||
      'searching_driver' ||
      'matching' ||
      'offered' ||
      'offer_pending' =>
        TripLifecycleState.searching,
      'assigned' ||
      'matched' ||
      'pending_driver_acceptance' ||
      'pending_driver_action' ||
      'driver_reviewing_request' ||
      'accepted' ||
      'driver_accepted' ||
      'driver_found' ||
      'driver_matched' ||
      'driver_found_pending' ||
      'driver_assigned' =>
        TripLifecycleState.driverAssigned,
      'arriving' ||
      'driver_arriving' ||
      'driver_on_the_way' =>
        TripLifecycleState.driverArriving,
      'arrived' || 'driver_arrived' => TripLifecycleState.arrived,
      'on_trip' ||
      'ontrip' ||
      'in_progress' ||
      'trip_started' =>
        TripLifecycleState.inProgress,
      'completed' ||
      'completed_with_payment_issue' ||
      'trip_completed' =>
        TripLifecycleState.completed,
      'cancelled' ||
      'canceled' ||
      'trip_cancelled' ||
      'driver_cancelled' ||
      'rider_cancelled' =>
        TripLifecycleState.cancelled,
      'expired' => TripLifecycleState.expired,
      _ => TripLifecycleState.searching,
    };
  }

  /// Canonical lifecycle from [trip_state] only (status is display-only legacy).
  static String canonicalStateFromValues({
    dynamic tripState,
    dynamic status,
    dynamic assignedDriverId,
  }) {
    final normalizedTripState = _normalizeText(tripState);
    final assignedNorm = _normalizeText(assignedDriverId);
    final hasConcreteDriver = assignedNorm.isNotEmpty &&
        assignedNorm != 'waiting';

    var resolved = normalizedTripState.isEmpty
        ? TripLifecycleState.searching
        : normalizeTripState(normalizedTripState);

    const needsDriver = <String>{
      TripLifecycleState.assigned,
      TripLifecycleState.arrived,
      TripLifecycleState.onTrip,
    };
    if (needsDriver.contains(resolved) && !hasConcreteDriver) {
      resolved = TripLifecycleState.searching;
    }

    developer.log(
      'CANONICAL_STATE_RESOLVE raw_trip_state=$normalizedTripState '
      'resolved=$resolved driver_bound=$hasConcreteDriver',
      name: 'nexride.trip_state',
    );
    return resolved;
  }

  static String legacyStatusForCanonical(String canonicalState) {
    return switch (canonicalState) {
      TripLifecycleState.searching => 'searching',
      TripLifecycleState.assigned => 'accepted',
      TripLifecycleState.arrived => 'arrived',
      TripLifecycleState.onTrip => 'on_trip',
      TripLifecycleState.completed => 'completed',
      TripLifecycleState.cancelled => 'cancelled',
      TripLifecycleState.expired => 'cancelled',
      _ => 'searching',
    };
  }

  static String uiStatusFromSnapshot(Map<String, dynamic>? rideData) {
    return legacyStatusForCanonical(canonicalStateFromSnapshot(rideData));
  }

  static bool isChatEligibleUiStatus(String status) {
    final normalized = _normalizeText(status);
    return normalized == 'pending_driver_action' ||
        normalized == 'assigned' ||
        normalized == 'accepted' ||
        normalized == 'driver_accepted' ||
        normalized == 'arriving' ||
        normalized == 'arrived' ||
        normalized == 'on_trip' ||
        normalized == 'in_progress';
  }

  static bool isChatEligibleRideSnapshot(Map<String, dynamic>? rideData) {
    if (rideData == null || rideData.isEmpty) {
      return false;
    }
    final canonical = canonicalStateFromSnapshot(rideData);
    final pm = _normalizePaymentMethodKey(rideData['payment_method']);
    if (pm == 'bank_transfer' && canonical == TripLifecycleState.searching) {
      return true;
    }
    final uiStatus = uiStatusFromSnapshot(rideData);
    return isChatEligibleUiStatus(uiStatus);
  }

  static String _normalizePaymentMethodKey(dynamic raw) {
    final s = raw?.toString().trim().toLowerCase() ?? '';
    return s.replaceAll(RegExp(r'[\s-]+'), '_');
  }

  /// When RTDB uses legacy `status: cancelled`, infer who cancelled for rider UI.
  static String? refinedRiderTerminalCancelStatus(
    Map<String, dynamic> rideData,
  ) {
    final canonical = canonicalStateFromSnapshot(rideData);
    if (canonical != TripLifecycleState.cancelled) {
      return null;
    }
    final by = _firstNonEmptyLower(<dynamic>[
      rideData['cancelled_by'],
      rideData['cancel_actor'],
    ]);
    if (by == 'driver') {
      return 'driver_cancelled';
    }
    if (by == 'rider' || by == 'rider_user' || by == 'user') {
      return 'rider_cancelled';
    }
    final rawTripState = _normalizeText(rideData['trip_state']);
    if (rawTripState == 'driver_cancelled') {
      return 'driver_cancelled';
    }
    if (rawTripState == 'rider_cancelled') {
      return 'rider_cancelled';
    }
    final cancelReason = _normalizeText(rideData['cancel_reason']);
    if (cancelReason == 'driver_cancelled') {
      return 'driver_cancelled';
    }
    if (cancelReason == 'rider_cancelled' || cancelReason == 'user_cancelled') {
      return 'rider_cancelled';
    }
    return null;
  }

  static String _firstNonEmptyLower(List<dynamic> values) {
    for (final v in values) {
      final s = _normalizeText(v);
      if (s.isNotEmpty) {
        return s;
      }
    }
    return '';
  }

  /// Rider-facing status (distinguishes `expired` from generic `cancelled` UI).
  static String riderUiStatusFromRideData(Map<String, dynamic> rideData) {
    final refinedCancel = refinedRiderTerminalCancelStatus(rideData);
    if (refinedCancel != null) {
      return refinedCancel;
    }
    if (canonicalStateFromSnapshot(rideData) == TripLifecycleState.expired) {
      return 'expired';
    }
    final rawTripState = _normalizeText(rideData['trip_state']);
    final rawStatus = _normalizeText(rideData['status']);
    final cancelReason = _normalizeText(rideData['cancel_reason']);
    if (rawTripState == 'driver_cancelled' ||
        cancelReason == 'driver_cancelled') {
      return 'driver_cancelled';
    }
    if (rawTripState == 'rider_cancelled' ||
        cancelReason == 'rider_cancelled') {
      return 'rider_cancelled';
    }
    if (rawTripState == 'expired' ||
        rawStatus == 'expired' ||
        cancelReason == 'expired') {
      return 'expired';
    }
    return uiStatusFromSnapshot(rideData);
  }

  static bool isTerminal(String canonicalState) {
    return terminalStates.contains(canonicalState);
  }

  static bool isRestorable(String canonicalState) {
    return restorableStates.contains(canonicalState);
  }

  static bool requiresAssignedDriver(String canonicalState) {
    return activeDriverStates.contains(canonicalState);
  }

  /// Open-pool “offer” reserve is no longer written server-side; always false.
  static bool isPendingDriverAssignmentState(String canonicalState) {
    return false;
  }

  static bool isDriverActiveState(String canonicalState) {
    return activeDriverStates.contains(canonicalState);
  }

  static int acceptedStartTimeoutAt(Map<String, dynamic> rideData) {
    for (final key in <String>[
      'start_timeout_at',
      'startTimeoutAt',
      'accepted_timeout_at',
    ]) {
      final explicitTimeout = _asInt(rideData[key]);
      if (explicitTimeout != null && explicitTimeout > 0) {
        return explicitTimeout;
      }
    }

    final acceptedAt = _asInt(rideData['accepted_at']);
    if (acceptedAt == null || acceptedAt <= 0) {
      return 0;
    }

    return acceptedAt + acceptedToStartTimeout.inMilliseconds;
  }

  static int routeLogTimeoutAt(Map<String, dynamic> rideData) {
    for (final key in <String>[
      'route_log_timeout_at',
      'routeLogTimeoutAt',
      'movement_timeout_at',
    ]) {
      final explicitTimeout = _asInt(rideData[key]);
      if (explicitTimeout != null && explicitTimeout > 0) {
        return explicitTimeout;
      }
    }

    final startedAt =
        _asInt(rideData['started_at']) ?? _asInt(rideData['pickupConfirmedAt']);
    if (startedAt == null || startedAt <= 0) {
      return 0;
    }

    return startedAt + routeLogTimeout.inMilliseconds;
  }

  static bool hasRouteCheckpoint(Map<String, dynamic> rideData) {
    if (rideData['has_started_route_checkpoints'] == true ||
        rideData['hasStartedRouteCheckpoints'] == true) {
      return true;
    }

    for (final key in <String>[
      'route_log_trip_started_checkpoint_at',
      'routeLogTripStartedCheckpointAt',
    ]) {
      final timestamp = _asInt(rideData[key]);
      if (timestamp != null && timestamp > 0) {
        return true;
      }
    }

    final lastCheckpointStatus =
        _normalizeText(rideData['route_log_last_checkpoint_status']);
    if (lastCheckpointStatus == 'on_trip') {
      final lastCheckpointAt = _asInt(rideData['route_log_last_checkpoint_at']);
      if (lastCheckpointAt != null && lastCheckpointAt > 0) {
        return true;
      }
    }

    return false;
  }

  static TripTimeoutCancellationDecision? timeoutCancellationDecision(
    Map<String, dynamic> rideData, {
    int? nowMs,
  }) {
    final canonicalState = canonicalStateFromSnapshot(rideData);
    if (isTerminal(canonicalState)) {
      return null;
    }

    final effectiveNow = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    if (canonicalState == TripLifecycleState.assigned ||
        canonicalState == TripLifecycleState.arrived) {
      final timeoutAt = acceptedStartTimeoutAt(rideData);
      if (timeoutAt > 0 && effectiveNow >= timeoutAt) {
        return TripTimeoutCancellationDecision(
          reason: 'driver_start_timeout',
          transitionSource: 'system_start_timeout',
          cancelSource: 'system_start_timeout',
          effectiveAt: timeoutAt,
          canonicalState: canonicalState,
        );
      }
    }

    if (canonicalState == TripLifecycleState.onTrip &&
        !hasRouteCheckpoint(rideData)) {
      final timeoutAt = routeLogTimeoutAt(rideData);
      if (timeoutAt > 0 && effectiveNow >= timeoutAt) {
        return TripTimeoutCancellationDecision(
          reason: 'no_route_logs',
          transitionSource: 'system_route_log_timeout',
          cancelSource: 'system_route_log_timeout',
          effectiveAt: timeoutAt,
          canonicalState: canonicalState,
          invalidTrip: true,
        );
      }
    }

    return null;
  }

  static bool canTransition({
    required String? fromCanonicalState,
    required String toCanonicalState,
  }) {
    if (!TripLifecycleState.all.contains(toCanonicalState)) {
      return false;
    }

    final fromState = fromCanonicalState == null || fromCanonicalState.isEmpty
        ? TripLifecycleState.searching
        : fromCanonicalState;
    if (fromState == toCanonicalState) {
      return true;
    }

    return _allowedTransitions[fromState]?.contains(toCanonicalState) ?? false;
  }

  static String? invalidTransitionReason({
    required String? fromCanonicalState,
    required String toCanonicalState,
  }) {
    if (canTransition(
      fromCanonicalState: fromCanonicalState,
      toCanonicalState: toCanonicalState,
    )) {
      return null;
    }

    final fromState = fromCanonicalState == null || fromCanonicalState.isEmpty
        ? TripLifecycleState.searching
        : fromCanonicalState;
    return 'transition_${fromState}_to_${toCanonicalState}_not_allowed';
  }

  static int? _intFromRideData(
    Map<String, dynamic> rideData,
    List<String> keys,
  ) {
    for (final key in keys) {
      final v = _asInt(rideData[key]);
      if (v != null && v > 0) {
        return v;
      }
    }
    return null;
  }

  static String? lifecycleProofReason(
    Map<String, dynamic> rideData, {
    String? canonicalState,
  }) {
    final state = canonicalState ?? canonicalStateFromSnapshot(rideData);
    final requestedAt = _intFromRideData(rideData, [
      'requested_at',
      'requestedAt',
    ]);
    final searchStartedAt = _intFromRideData(rideData, [
      'search_started_at',
      'searchStartedAt',
    ]);
    final acceptedAt = _intFromRideData(rideData, [
      'accepted_at',
      'acceptedAt',
    ]);
    final arrivingAt = _intFromRideData(rideData, [
      'arriving_at',
      'arrivingAt',
    ]);
    final arrivedAt =
        _intFromRideData(rideData, ['arrived_at', 'arrivedAt']);
    final startedAt = _intFromRideData(rideData, [
          'started_at',
          'startedAt',
        ]) ??
        _asInt(rideData['pickupConfirmedAt']);
    final completedAt = _intFromRideData(rideData, [
      'completed_at',
      'completedAt',
    ]);
    final cancelledAt = _intFromRideData(rideData, [
      'cancelled_at',
      'cancelledAt',
      'canceled_at',
      'canceledAt',
    ]);

    if (state == TripLifecycleState.searching &&
        requestedAt == null &&
        searchStartedAt == null) {
      return 'missing_search_started_at';
    }

    if ((state == TripLifecycleState.assigned ||
            state == TripLifecycleState.arrived ||
            state == TripLifecycleState.onTrip ||
            state == TripLifecycleState.completed) &&
        acceptedAt == null) {
      return 'missing_accepted_at';
    }

    if ((state == TripLifecycleState.arrived ||
            state == TripLifecycleState.onTrip ||
            state == TripLifecycleState.completed) &&
        arrivedAt == null) {
      return 'missing_arrived_at';
    }

    if ((state == TripLifecycleState.onTrip ||
            state == TripLifecycleState.completed) &&
        startedAt == null) {
      return 'missing_started_at';
    }

    if (state == TripLifecycleState.completed && completedAt == null) {
      return 'missing_completed_at';
    }

    if (state == TripLifecycleState.cancelled && cancelledAt == null) {
      return 'missing_cancelled_at';
    }

    return null;
  }

  static Map<String, dynamic> buildTransitionUpdate({
    required Map<String, dynamic> currentRide,
    required String nextCanonicalState,
    required dynamic timestampValue,
    required String transitionSource,
    required String transitionActor,
    String? cancellationActor,
    String? cancellationReason,
  }) {
    final currentCanonicalState = canonicalStateFromSnapshot(currentRide);
    final invalidReason = invalidTransitionReason(
      fromCanonicalState: currentCanonicalState,
      toCanonicalState: nextCanonicalState,
    );
    if (invalidReason != null) {
      throw StateError(invalidReason);
    }

    final updates = <String, dynamic>{
      'trip_state': nextCanonicalState,
      'status': legacyStatusForCanonical(nextCanonicalState),
      'state_machine_version': schemaVersion,
      'last_transition_actor': transitionActor,
      'last_transition_source': transitionSource,
      'updated_at': timestampValue,
    };

    void setTransitionTimestamp(String field) {
      if (currentRide[field] == null) {
        updates[field] = timestampValue;
      }
    }

    switch (nextCanonicalState) {
      case TripLifecycleState.searching:
        setTransitionTimestamp('requested_at');
        setTransitionTimestamp('search_started_at');
        break;
      case TripLifecycleState.assigned:
        setTransitionTimestamp('requested_at');
        setTransitionTimestamp('search_started_at');
        setTransitionTimestamp('assigned_at');
        setTransitionTimestamp('accepted_at');
        break;
      case TripLifecycleState.arrived:
        setTransitionTimestamp('requested_at');
        setTransitionTimestamp('search_started_at');
        setTransitionTimestamp('assigned_at');
        setTransitionTimestamp('accepted_at');
        setTransitionTimestamp('arriving_at');
        setTransitionTimestamp('arrived_at');
        break;
      case TripLifecycleState.onTrip:
        setTransitionTimestamp('requested_at');
        setTransitionTimestamp('search_started_at');
        setTransitionTimestamp('assigned_at');
        setTransitionTimestamp('accepted_at');
        setTransitionTimestamp('arriving_at');
        setTransitionTimestamp('arrived_at');
        setTransitionTimestamp('started_at');
        break;
      case TripLifecycleState.completed:
        setTransitionTimestamp('requested_at');
        setTransitionTimestamp('search_started_at');
        setTransitionTimestamp('assigned_at');
        setTransitionTimestamp('accepted_at');
        setTransitionTimestamp('arriving_at');
        setTransitionTimestamp('arrived_at');
        setTransitionTimestamp('started_at');
        setTransitionTimestamp('completed_at');
        break;
      case TripLifecycleState.cancelled:
      case TripLifecycleState.expired:
        setTransitionTimestamp('cancelled_at');
        if (_normalizeText(cancellationActor).isNotEmpty) {
          updates['cancel_actor'] = _normalizeText(cancellationActor);
        }
        if (_normalizeText(cancellationReason).isNotEmpty) {
          updates['cancel_reason'] = _normalizeText(cancellationReason);
        }
        break;
    }

    return updates;
  }

  static int? _asInt(dynamic value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value);
    }
    return null;
  }

  static String _normalizeText(dynamic value) {
    return value?.toString().trim().toLowerCase() ?? '';
  }
}

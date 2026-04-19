class TripLifecycleState {
  static const String requested = 'requested';
  static const String searchingDriver = 'searching_driver';
  static const String pendingDriverAction = 'pending_driver_action';
  static const String driverAccepted = 'driver_accepted';
  static const String driverArriving = 'driver_arriving';
  static const String driverArrived = 'driver_arrived';
  static const String tripStarted = 'trip_started';
  static const String tripCompleted = 'trip_completed';
  static const String tripCancelled = 'trip_cancelled';

  static const Set<String> all = <String>{
    requested,
    searchingDriver,
    pendingDriverAction,
    driverAccepted,
    driverArriving,
    driverArrived,
    tripStarted,
    tripCompleted,
    tripCancelled,
  };
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
    TripLifecycleState.searchingDriver,
    TripLifecycleState.pendingDriverAction,
    TripLifecycleState.driverAccepted,
    TripLifecycleState.driverArriving,
    TripLifecycleState.driverArrived,
    TripLifecycleState.tripStarted,
  };

  static const Set<String> activeDriverStates = <String>{
    TripLifecycleState.driverAccepted,
    TripLifecycleState.driverArriving,
    TripLifecycleState.driverArrived,
    TripLifecycleState.tripStarted,
  };

  static const Set<String> terminalStates = <String>{
    TripLifecycleState.tripCompleted,
    TripLifecycleState.tripCancelled,
  };

  static const Map<String, Set<String>> _allowedTransitions =
      <String, Set<String>>{
        TripLifecycleState.requested: <String>{
          TripLifecycleState.searchingDriver,
          TripLifecycleState.tripCancelled,
        },
        TripLifecycleState.searchingDriver: <String>{
          TripLifecycleState.pendingDriverAction,
          TripLifecycleState.tripCancelled,
        },
        TripLifecycleState.pendingDriverAction: <String>{
          TripLifecycleState.searchingDriver,
          TripLifecycleState.driverAccepted,
          TripLifecycleState.tripCancelled,
        },
        TripLifecycleState.driverAccepted: <String>{
          TripLifecycleState.driverArriving,
          TripLifecycleState.driverArrived,
          TripLifecycleState.tripCancelled,
        },
        TripLifecycleState.driverArriving: <String>{
          TripLifecycleState.driverArrived,
          TripLifecycleState.tripCancelled,
        },
        TripLifecycleState.driverArrived: <String>{
          TripLifecycleState.tripStarted,
          TripLifecycleState.tripCancelled,
        },
        TripLifecycleState.tripStarted: <String>{
          TripLifecycleState.tripCompleted,
          TripLifecycleState.tripCancelled,
        },
        TripLifecycleState.tripCompleted: <String>{},
        TripLifecycleState.tripCancelled: <String>{},
      };

  static String canonicalStateFromSnapshot(Map<String, dynamic>? rideData) {
    return canonicalStateFromValues(
      tripState: rideData?['trip_state'],
      status: rideData?['status'],
    );
  }

  static String canonicalStateFromValues({dynamic tripState, dynamic status}) {
    final normalizedTripState = _normalizeText(tripState);
    final normalizedStatus = _normalizeText(status);
    if (normalizedTripState == 'pending_driver_acceptance') {
      return TripLifecycleState.pendingDriverAction;
    }
    if (TripLifecycleState.all.contains(normalizedTripState)) {
      if (normalizedTripState == TripLifecycleState.requested &&
          (normalizedStatus == 'searching' ||
              normalizedStatus == 'searching_driver')) {
        return TripLifecycleState.searchingDriver;
      }
      return normalizedTripState;
    }

    return switch (normalizedStatus) {
      '' || 'idle' => TripLifecycleState.requested,
      'requested' => TripLifecycleState.requested,
      'searching' || 'searching_driver' => TripLifecycleState.searchingDriver,
      'assigned' ||
      'driver_assigned' ||
      'matched' ||
      'pending_driver_acceptance' ||
      'pending_driver_action' => TripLifecycleState.pendingDriverAction,
      'accepted' || 'driver_accepted' => TripLifecycleState.driverAccepted,
      'arriving' || 'driver_arriving' => TripLifecycleState.driverArriving,
      'arrived' || 'driver_arrived' => TripLifecycleState.driverArrived,
      'on_trip' ||
      'ontrip' ||
      'in_progress' ||
      'trip_started' => TripLifecycleState.tripStarted,
      'completed' ||
      'completed_with_payment_issue' ||
      'trip_completed' => TripLifecycleState.tripCompleted,
      'cancelled' ||
      'canceled' ||
      'trip_cancelled' => TripLifecycleState.tripCancelled,
      _ => TripLifecycleState.requested,
    };
  }

  static String legacyStatusForCanonical(String canonicalState) {
    return switch (canonicalState) {
      TripLifecycleState.requested => 'requested',
      TripLifecycleState.searchingDriver => 'searching',
      TripLifecycleState.pendingDriverAction => 'pending_driver_action',
      TripLifecycleState.driverAccepted => 'accepted',
      TripLifecycleState.driverArriving => 'arriving',
      TripLifecycleState.driverArrived => 'arrived',
      TripLifecycleState.tripStarted => 'on_trip',
      TripLifecycleState.tripCompleted => 'completed',
      TripLifecycleState.tripCancelled => 'cancelled',
      _ => 'searching',
    };
  }

  static String uiStatusFromSnapshot(Map<String, dynamic>? rideData) {
    return legacyStatusForCanonical(canonicalStateFromSnapshot(rideData));
  }

  static bool isTerminal(String canonicalState) {
    return terminalStates.contains(canonicalState);
  }

  static bool isRestorable(String canonicalState) {
    return restorableStates.contains(canonicalState);
  }

  static bool requiresAssignedDriver(String canonicalState) {
    return activeDriverStates.contains(canonicalState) ||
        canonicalState == TripLifecycleState.pendingDriverAction;
  }

  static bool isPendingDriverAssignmentState(String canonicalState) {
    return canonicalState == TripLifecycleState.pendingDriverAction;
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

    final lastCheckpointStatus = _normalizeText(
      rideData['route_log_last_checkpoint_status'],
    );
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
    if (canonicalState == TripLifecycleState.driverAccepted ||
        canonicalState == TripLifecycleState.driverArriving ||
        canonicalState == TripLifecycleState.driverArrived) {
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

    if (canonicalState == TripLifecycleState.tripStarted &&
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
        ? TripLifecycleState.requested
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
        ? TripLifecycleState.requested
        : fromCanonicalState;
    return 'transition_${fromState}_to_${toCanonicalState}_not_allowed';
  }

  static String? lifecycleProofReason(
    Map<String, dynamic> rideData, {
    String? canonicalState,
  }) {
    final state = canonicalState ?? canonicalStateFromSnapshot(rideData);
    final requestedAt = _asInt(rideData['requested_at']);
    final searchStartedAt = _asInt(rideData['search_started_at']);
    final assignedAt = _asInt(rideData['assigned_at']);
    final acceptedAt = _asInt(rideData['accepted_at']);
    final arrivingAt = _asInt(rideData['arriving_at']);
    final arrivedAt = _asInt(rideData['arrived_at']);
    final startedAt =
        _asInt(rideData['started_at']) ?? _asInt(rideData['pickupConfirmedAt']);
    final completedAt = _asInt(rideData['completed_at']);
    final cancelledAt = _asInt(rideData['cancelled_at']);

    if (state == TripLifecycleState.requested && requestedAt == null) {
      return 'missing_requested_at';
    }

    if (state == TripLifecycleState.searchingDriver &&
        requestedAt == null &&
        searchStartedAt == null) {
      return 'missing_search_started_at';
    }

    if (state == TripLifecycleState.pendingDriverAction &&
        (assignedAt == null ||
            requestedAt == null && searchStartedAt == null)) {
      return 'missing_assigned_at';
    }

    if ((state == TripLifecycleState.driverAccepted ||
            state == TripLifecycleState.driverArriving ||
            state == TripLifecycleState.driverArrived ||
            state == TripLifecycleState.tripStarted ||
            state == TripLifecycleState.tripCompleted) &&
        acceptedAt == null) {
      return 'missing_accepted_at';
    }

    if (state == TripLifecycleState.driverArriving && arrivingAt == null) {
      return 'missing_arriving_at';
    }

    if ((state == TripLifecycleState.driverArrived ||
            state == TripLifecycleState.tripStarted ||
            state == TripLifecycleState.tripCompleted) &&
        arrivedAt == null) {
      return 'missing_arrived_at';
    }

    if ((state == TripLifecycleState.tripStarted ||
            state == TripLifecycleState.tripCompleted) &&
        startedAt == null) {
      return 'missing_started_at';
    }

    if (state == TripLifecycleState.tripCompleted && completedAt == null) {
      return 'missing_completed_at';
    }

    if (state == TripLifecycleState.tripCancelled && cancelledAt == null) {
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
      case TripLifecycleState.requested:
        setTransitionTimestamp('requested_at');
        break;
      case TripLifecycleState.searchingDriver:
        setTransitionTimestamp('requested_at');
        setTransitionTimestamp('search_started_at');
        break;
      case TripLifecycleState.pendingDriverAction:
        setTransitionTimestamp('requested_at');
        setTransitionTimestamp('search_started_at');
        setTransitionTimestamp('assigned_at');
        break;
      case TripLifecycleState.driverAccepted:
        setTransitionTimestamp('requested_at');
        setTransitionTimestamp('search_started_at');
        setTransitionTimestamp('assigned_at');
        setTransitionTimestamp('accepted_at');
        break;
      case TripLifecycleState.driverArriving:
        setTransitionTimestamp('requested_at');
        setTransitionTimestamp('search_started_at');
        setTransitionTimestamp('assigned_at');
        setTransitionTimestamp('accepted_at');
        setTransitionTimestamp('arriving_at');
        break;
      case TripLifecycleState.driverArrived:
        setTransitionTimestamp('requested_at');
        setTransitionTimestamp('search_started_at');
        setTransitionTimestamp('assigned_at');
        setTransitionTimestamp('accepted_at');
        setTransitionTimestamp('arriving_at');
        setTransitionTimestamp('arrived_at');
        break;
      case TripLifecycleState.tripStarted:
        setTransitionTimestamp('requested_at');
        setTransitionTimestamp('search_started_at');
        setTransitionTimestamp('assigned_at');
        setTransitionTimestamp('accepted_at');
        setTransitionTimestamp('arriving_at');
        setTransitionTimestamp('arrived_at');
        setTransitionTimestamp('started_at');
        break;
      case TripLifecycleState.tripCompleted:
        setTransitionTimestamp('requested_at');
        setTransitionTimestamp('search_started_at');
        setTransitionTimestamp('assigned_at');
        setTransitionTimestamp('accepted_at');
        setTransitionTimestamp('arriving_at');
        setTransitionTimestamp('arrived_at');
        setTransitionTimestamp('started_at');
        setTransitionTimestamp('completed_at');
        break;
      case TripLifecycleState.tripCancelled:
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

import 'package:flutter_test/flutter_test.dart';
import 'package:nexride/trip_sync/trip_state_machine.dart';

void main() {
  test('driver trip state treats idle as neutral', () {
    expect(
      TripStateMachine.canonicalStateFromValues(status: 'idle'),
      TripLifecycleState.searching,
    );
    expect(
      TripStateMachine.canonicalStateFromValues(status: ''),
      TripLifecycleState.searching,
    );
  });

  test('requested trip_state reconciles with searching status', () {
    expect(
      TripStateMachine.canonicalStateFromValues(
        tripState: TripLifecycleState.requested,
        status: 'searching',
      ),
      TripLifecycleState.searchingDriver,
    );
    expect(
      TripStateMachine.uiStatusFromSnapshot(<String, dynamic>{
        'trip_state': TripLifecycleState.requested,
        'status': 'searching',
      }),
      'searching',
    );
  });

  test(
    'driver_assigned reconciles legacy status tokens; no client offer-reserve state',
    () {
      expect(
        TripStateMachine.canonicalStateFromValues(
          status: 'assigned',
          assignedDriverId: 'driver_1',
        ),
        TripLifecycleState.driverAssigned,
      );
      expect(
        TripStateMachine.canonicalStateFromValues(
          status: 'pending_driver_acceptance',
          assignedDriverId: 'driver_1',
        ),
        TripLifecycleState.driverAssigned,
      );
      expect(
        TripStateMachine.canonicalStateFromValues(
          status: 'pending_driver_action',
          assignedDriverId: 'driver_1',
        ),
        TripLifecycleState.driverAssigned,
      );
      expect(
        TripLifecycleState.pendingDriverAction,
        TripLifecycleState.driverAssigned,
      );
      expect(
        TripStateMachine.legacyStatusForCanonical(
          TripLifecycleState.pendingDriverAction,
        ),
        'accepted',
      );
      expect(
        TripStateMachine.isPendingDriverAssignmentState(
          TripLifecycleState.pendingDriverAction,
        ),
        isFalse,
      );
      expect(
        TripStateMachine.isDriverActiveState(
          TripLifecycleState.pendingDriverAction,
        ),
        isTrue,
      );
      expect(
        TripStateMachine.isRestorable(
          TripLifecycleState.pendingDriverAction,
        ),
        isTrue,
      );
      expect(
        TripStateMachine.canTransition(
          fromCanonicalState: TripLifecycleState.searchingDriver,
          toCanonicalState: TripLifecycleState.driverAccepted,
        ),
        isTrue,
      );
      expect(
        TripStateMachine.canTransition(
          fromCanonicalState: TripLifecycleState.pendingDriverAction,
          toCanonicalState: TripLifecycleState.driverAccepted,
        ),
        isTrue,
      );
    },
  );

  test('accepted driver rides time out when pickup never starts', () {
    final acceptedAt = DateTime(2026, 1, 1, 12).millisecondsSinceEpoch;
    final decision = TripStateMachine.timeoutCancellationDecision(
      <String, dynamic>{
        'trip_state': TripLifecycleState.driverAccepted,
        'status': 'accepted',
        'accepted_at': acceptedAt,
        'driver_id': 'driver_1',
      },
      nowMs:
          acceptedAt + TripStateMachine.acceptedToStartTimeout.inMilliseconds,
    );

    expect(decision, isNotNull);
    expect(decision!.reason, 'driver_start_timeout');
    expect(
      decision.effectiveAt,
      acceptedAt + TripStateMachine.acceptedToStartTimeout.inMilliseconds,
    );
  });

  test('started driver rides without started checkpoints time out', () {
    final startedAt = DateTime(2026, 1, 1, 12).millisecondsSinceEpoch;
    final timeoutAt =
        startedAt + TripStateMachine.routeLogTimeout.inMilliseconds;
    final decision = TripStateMachine.timeoutCancellationDecision(
      <String, dynamic>{
        'trip_state': TripLifecycleState.tripStarted,
        'status': 'on_trip',
        'started_at': startedAt,
        'route_log_timeout_at': timeoutAt,
        'driver_id': 'driver_1',
      },
      nowMs: timeoutAt,
    );

    expect(decision, isNotNull);
    expect(decision!.reason, 'no_route_logs');
    expect(decision.invalidTrip, isTrue);
  });

  test('searching transitions to driver_assigned then driver_arriving', () {
    final assignedAt = DateTime(2026, 1, 1, 12).millisecondsSinceEpoch;
    final assignmentUpdate = TripStateMachine.buildTransitionUpdate(
      currentRide: <String, dynamic>{
        'trip_state': TripLifecycleState.searchingDriver,
        'status': 'searching',
      },
      nextCanonicalState: TripLifecycleState.driverAssigned,
      timestampValue: assignedAt,
      transitionSource: 'acceptRideRequest',
      transitionActor: 'driver',
    );

    expect(
      assignmentUpdate['trip_state'],
      TripLifecycleState.driverAssigned,
    );
    expect(assignmentUpdate['status'], 'accepted');
    expect(assignmentUpdate['assigned_at'], assignedAt);
    expect(assignmentUpdate['accepted_at'], assignedAt);

    final enrouteAt = assignedAt + 1500;
    final enrouteUpdate = TripStateMachine.buildTransitionUpdate(
      currentRide: <String, dynamic>{
        'trip_state': TripLifecycleState.driverAssigned,
        'status': 'accepted',
        'assigned_at': assignedAt,
        'accepted_at': assignedAt,
        'driver_id': 'driver_1',
      },
      nextCanonicalState: TripLifecycleState.driverArriving,
      timestampValue: enrouteAt,
      transitionSource: 'driverEnroute',
      transitionActor: 'driver',
    );

    expect(enrouteUpdate['trip_state'], TripLifecycleState.driverArriving);
    expect(enrouteUpdate['status'], 'arriving');
    expect(enrouteUpdate['arriving_at'], enrouteAt);
  });

  test('legacy driver_found status maps to driver accepted', () {
    expect(
      TripStateMachine.canonicalStateFromValues(
        status: 'driver_found',
        assignedDriverId: 'd1',
      ),
      TripLifecycleState.driverAccepted,
    );
    expect(
      TripStateMachine.uiStatusFromSnapshot(<String, dynamic>{
        'status': 'driver_found',
        'driver_id': 'd1',
      }),
      'accepted',
    );
  });

  test('lifecycle proof accepts camelCase acceptedAt', () {
    expect(
      TripStateMachine.lifecycleProofReason(
        <String, dynamic>{
          'trip_state': TripLifecycleState.driverAccepted,
          'acceptedAt': 1700000000000,
          'driver_id': 'driver_1',
          'search_started_at': 1699990000000,
        },
      ),
      isNull,
    );
  });

  test(
      'bound driver_id uplifts stale searching trip_state for rider stability', () {
    expect(
      TripStateMachine.canonicalStateFromValues(
        tripState: TripLifecycleState.searchingDriver,
        status: 'searching',
        assignedDriverId: 'driver_abc',
      ),
      TripLifecycleState.pendingDriverAction,
    );
  });
}

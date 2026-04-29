import 'package:flutter_test/flutter_test.dart';
import 'package:nexride_driver/trip_sync/trip_state_machine.dart';

void main() {
  test('driver trip state treats idle as neutral', () {
    expect(
      TripStateMachine.canonicalStateFromValues(status: 'idle'),
      TripLifecycleState.requested,
    );
    expect(
      TripStateMachine.canonicalStateFromValues(status: ''),
      TripLifecycleState.requested,
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

  test('pending driver action remains distinct while allowing atomic accept', () {
    expect(
      TripStateMachine.canonicalStateFromValues(status: 'assigned'),
      TripLifecycleState.pendingDriverAction,
    );
    expect(
      TripStateMachine.canonicalStateFromValues(
        status: 'pending_driver_acceptance',
      ),
      TripLifecycleState.pendingDriverAction,
    );
    expect(
      TripStateMachine.canonicalStateFromValues(
          status: 'pending_driver_action'),
      TripLifecycleState.pendingDriverAction,
    );
    expect(
      TripStateMachine.legacyStatusForCanonical(
        TripLifecycleState.pendingDriverAction,
      ),
      'pending_driver_action',
    );
    expect(
      TripStateMachine.isPendingDriverAssignmentState(
        TripLifecycleState.pendingDriverAction,
      ),
      isTrue,
    );
    expect(
      TripStateMachine.isDriverActiveState(
        TripLifecycleState.pendingDriverAction,
      ),
      isFalse,
    );
    expect(
      TripStateMachine.isRestorable(
        TripLifecycleState.pendingDriverAction,
      ),
      isFalse,
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
  });

  test('accepted driver rides time out when pickup never starts', () {
    final acceptedAt = DateTime(2026, 1, 1, 12).millisecondsSinceEpoch;
    final decision = TripStateMachine.timeoutCancellationDecision(
      <String, dynamic>{
        'trip_state': TripLifecycleState.driverAccepted,
        'status': 'accepted',
        'accepted_at': acceptedAt,
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
      },
      nowMs: timeoutAt,
    );

    expect(decision, isNotNull);
    expect(decision!.reason, 'no_route_logs');
    expect(decision.invalidTrip, isTrue);
  });

  test('driver reservation transitions cleanly into acceptance', () {
    final assignedAt = DateTime(2026, 1, 1, 12).millisecondsSinceEpoch;
    final assignmentUpdate = TripStateMachine.buildTransitionUpdate(
      currentRide: <String, dynamic>{
        'trip_state': TripLifecycleState.searchingDriver,
        'status': 'searching',
      },
      nextCanonicalState: TripLifecycleState.pendingDriverAction,
      timestampValue: assignedAt,
      transitionSource: 'driver_assignment_reserve',
      transitionActor: 'system',
    );

    expect(
      assignmentUpdate['trip_state'],
      TripLifecycleState.pendingDriverAction,
    );
    expect(assignmentUpdate['status'], 'pending_driver_action');
    expect(assignmentUpdate['assigned_at'], assignedAt);

    final acceptedAt = assignedAt + 1500;
    final acceptUpdate = TripStateMachine.buildTransitionUpdate(
      currentRide: <String, dynamic>{
        'trip_state': TripLifecycleState.pendingDriverAction,
        'status': 'pending_driver_action',
        'assigned_at': assignedAt,
      },
      nextCanonicalState: TripLifecycleState.driverAccepted,
      timestampValue: acceptedAt,
      transitionSource: 'driver_accept',
      transitionActor: 'driver',
    );

    expect(acceptUpdate['trip_state'], TripLifecycleState.driverAccepted);
    expect(acceptUpdate['status'], 'accepted');
    expect(acceptUpdate['accepted_at'], acceptedAt);
    expect(acceptUpdate.containsKey('assigned_at'), isFalse);
  });

  test('legacy driver_found status maps to driver accepted', () {
    expect(
      TripStateMachine.canonicalStateFromValues(status: 'driver_found'),
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
        },
      ),
      isNull,
    );
  });

  test('bound driver_id uplifts stale searching trip_state for rider stability', () {
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

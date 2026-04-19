import 'package:flutter_test/flutter_test.dart';
import 'package:nexride/trip_sync/trip_state_machine.dart';

void main() {
  test('idle status stays neutral instead of searching', () {
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

  test('rider keeps pending driver action separate from acceptance', () {
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
        status: 'pending_driver_action',
      ),
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
      TripStateMachine.isRestorable(TripLifecycleState.pendingDriverAction),
      isTrue,
    );
    expect(
      TripStateMachine.canTransition(
        fromCanonicalState: TripLifecycleState.searchingDriver,
        toCanonicalState: TripLifecycleState.driverAccepted,
      ),
      isFalse,
    );
    expect(
      TripStateMachine.canTransition(
        fromCanonicalState: TripLifecycleState.pendingDriverAction,
        toCanonicalState: TripLifecycleState.driverAccepted,
      ),
      isTrue,
    );
  });

  test('accepted rides expire if pickup never starts', () {
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

  test('started rides without started-route checkpoints expire quickly', () {
    final startedAt = DateTime(2026, 1, 1, 12).millisecondsSinceEpoch;
    final timeoutAt =
        startedAt + TripStateMachine.routeLogTimeout.inMilliseconds;
    final decision =
        TripStateMachine.timeoutCancellationDecision(<String, dynamic>{
          'trip_state': TripLifecycleState.tripStarted,
          'status': 'on_trip',
          'started_at': startedAt,
          'route_log_timeout_at': timeoutAt,
        }, nowMs: timeoutAt);

    expect(decision, isNotNull);
    expect(decision!.reason, 'no_route_logs');
    expect(decision.invalidTrip, isTrue);
  });

  test('pending driver assignment advances cleanly into accepted', () {
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
}

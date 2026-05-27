import 'package:flutter_test/flutter_test.dart';
import 'package:nexride/trip_sync/trip_state_machine.dart';

void main() {
  test('normalizeTripState maps legacy tokens to canonical', () {
    expect(
      TripStateMachine.normalizeTripState('driver_assigned'),
      TripLifecycleState.assigned,
    );
    expect(
      TripStateMachine.normalizeTripState('in_progress'),
      TripLifecycleState.onTrip,
    );
    expect(
      TripStateMachine.normalizeTripState('driver_arriving'),
      TripLifecycleState.assigned,
    );
  });

  test('canonical state uses trip_state only', () {
    expect(
      TripStateMachine.canonicalStateFromValues(
        tripState: TripLifecycleState.assigned,
        status: 'searching',
        assignedDriverId: 'driver_1',
      ),
      TripLifecycleState.assigned,
    );
    expect(
      TripStateMachine.canonicalStateFromValues(
        tripState: TripLifecycleState.searching,
        status: 'accepted',
        assignedDriverId: 'driver_1',
      ),
      TripLifecycleState.searching,
    );
  });

  test('assigned without driver_id coerces to searching', () {
    expect(
      TripStateMachine.canonicalStateFromValues(
        tripState: TripLifecycleState.assigned,
      ),
      TripLifecycleState.searching,
    );
  });

  test('restorable states match stabilization contract', () {
    expect(TripStateMachine.restorableStates, <String>{
      TripLifecycleState.searching,
      TripLifecycleState.assigned,
      TripLifecycleState.arrived,
      TripLifecycleState.onTrip,
    });
  });

  test('searching transitions to assigned then arrived then on_trip', () {
    final assignedAt = DateTime(2026, 1, 1, 12).millisecondsSinceEpoch;
    final assignmentUpdate = TripStateMachine.buildTransitionUpdate(
      currentRide: <String, dynamic>{
        'trip_state': TripLifecycleState.searching,
        'status': 'searching',
      },
      nextCanonicalState: TripLifecycleState.assigned,
      timestampValue: assignedAt,
      transitionSource: 'acceptRideRequest',
      transitionActor: 'driver',
    );

    expect(assignmentUpdate['trip_state'], TripLifecycleState.assigned);
    expect(assignmentUpdate['status'], 'accepted');

    final arrivedAt = assignedAt + 1500;
    final arrivedUpdate = TripStateMachine.buildTransitionUpdate(
      currentRide: <String, dynamic>{
        'trip_state': TripLifecycleState.assigned,
        'status': 'accepted',
        'assigned_at': assignedAt,
        'accepted_at': assignedAt,
        'driver_id': 'driver_1',
      },
      nextCanonicalState: TripLifecycleState.arrived,
      timestampValue: arrivedAt,
      transitionSource: 'driverArrived',
      transitionActor: 'driver',
    );

    expect(arrivedUpdate['trip_state'], TripLifecycleState.arrived);
    expect(arrivedUpdate['status'], 'arrived');
  });

  test('accepted driver rides time out when pickup never starts', () {
    final acceptedAt = DateTime(2026, 1, 1, 12).millisecondsSinceEpoch;
    final decision = TripStateMachine.timeoutCancellationDecision(
      <String, dynamic>{
        'trip_state': TripLifecycleState.assigned,
        'status': 'accepted',
        'accepted_at': acceptedAt,
        'driver_id': 'driver_1',
      },
      nowMs:
          acceptedAt + TripStateMachine.acceptedToStartTimeout.inMilliseconds,
    );

    expect(decision, isNotNull);
    expect(decision!.reason, 'driver_start_timeout');
  });

  test('on_trip without route checkpoints times out', () {
    final startedAt = DateTime(2026, 1, 1, 12).millisecondsSinceEpoch;
    final timeoutAt =
        startedAt + TripStateMachine.routeLogTimeout.inMilliseconds;
    final decision = TripStateMachine.timeoutCancellationDecision(
      <String, dynamic>{
        'trip_state': TripLifecycleState.onTrip,
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

  test('trip_state arrived is detected', () {
    expect(
      TripStateMachine.tripStateIndicatesArrived('driver_arrived'),
      isTrue,
    );
    expect(
      TripStateMachine.tripStateIndicatesArrivedSnapshot(<String, dynamic>{
        'trip_state': 'arrived',
      }),
      isTrue,
    );
  });
}

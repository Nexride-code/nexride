import 'package:flutter_test/flutter_test.dart';
import 'package:nexride_driver/trip_sync/trip_state_machine.dart';

void main() {
  test('normalizeTripState maps legacy driver_assigned to assigned', () {
    expect(
      TripStateMachine.normalizeTripState('driver_assigned'),
      TripLifecycleState.assigned,
    );
  });
}

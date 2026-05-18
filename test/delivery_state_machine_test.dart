import 'package:flutter_test/flutter_test.dart';
import 'package:nexride/trip_sync/delivery_state_machine.dart';

void main() {
  test('canonicalAssignedDriverId resolves matched over waiting', () {
    final id = DeliveryStateMachine.canonicalAssignedDriverId(<String, dynamic>{
      'driver_id': 'waiting',
      'matched_driver_id': 'drv_99',
    });
    expect(id, 'drv_99');
  });

  test('canonicalState maps legacy accepted to driverAssigned', () {
    final state = DeliveryStateMachine.canonicalStateFromSnapshot(
      <String, dynamic>{'delivery_state': 'accepted'},
    );
    expect(state, DeliveryLifecycleState.driverAssigned);
  });

  test('isChatEligible after assignment', () {
    expect(
      DeliveryStateMachine.isChatEligible(<String, dynamic>{
        'delivery_state': 'driver_assigned',
        'matched_driver_id': 'drv_1',
      }),
      isTrue,
    );
    expect(
      DeliveryStateMachine.isChatEligible(<String, dynamic>{
        'delivery_state': 'searching',
        'driver_id': 'waiting',
      }),
      isFalse,
    );
  });
}

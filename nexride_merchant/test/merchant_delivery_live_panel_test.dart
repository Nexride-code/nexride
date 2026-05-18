import 'package:flutter_test/flutter_test.dart';
import 'package:nexride_merchant/domain/delivery_state_machine.dart';

void main() {
  test('merchant leaves waiting when driver is assigned', () {
    final data = <String, dynamic>{
      'delivery_state': 'driver_assigned',
      'matched_driver_id': 'drv_1',
      'driver_name': 'Ada',
    };
    expect(DeliveryStateMachine.snapshotShowsAssignedDriver(data), isTrue);
    expect(
      DeliveryStateMachine.uiStatusLabel(data),
      isNot(contains('Waiting')),
    );
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:nexride_driver/support/driver_accept_timeout_reconcile.dart';

void main() {
  test('timeout reconcile success when ride assigned to driver', () {
    final result = reconcileAcceptAfterCallableTimeout(
      driverId: 'drv1',
      rideData: <String, dynamic>{
        'ride_id': 'ride1',
        'driver_id': 'drv1',
        'trip_state': 'driver_assigned',
      },
      driverActiveRideData: null,
      offerQueueExists: false,
    );
    expect(result.isSuccess, isTrue);
  });

  test('timeout reconcile already taken when another driver assigned', () {
    final result = reconcileAcceptAfterCallableTimeout(
      driverId: 'drv1',
      rideData: <String, dynamic>{
        'ride_id': 'ride1',
        'driver_id': 'drv2',
        'trip_state': 'driver_assigned',
      },
      driverActiveRideData: null,
      offerQueueExists: false,
    );
    expect(
      result.outcome,
      DriverAcceptTimeoutReconcileOutcome.alreadyTaken,
    );
  });

  test('timeout reconcile retry when still searching and queue exists', () {
    final result = reconcileAcceptAfterCallableTimeout(
      driverId: 'drv1',
      rideData: <String, dynamic>{
        'ride_id': 'ride1',
        'driver_id': 'waiting',
        'trip_state': 'searching',
      },
      driverActiveRideData: null,
      offerQueueExists: true,
    );
    expect(result.retryAllowed, isTrue);
  });

  test('timeout reconcile failed when searching but queue gone', () {
    final result = reconcileAcceptAfterCallableTimeout(
      driverId: 'drv1',
      rideData: <String, dynamic>{
        'ride_id': 'ride1',
        'trip_state': 'searching',
      },
      driverActiveRideData: null,
      offerQueueExists: false,
    );
    expect(result.outcome, DriverAcceptTimeoutReconcileOutcome.failed);
  });
}

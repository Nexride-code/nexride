import 'package:flutter_test/flutter_test.dart';
import 'package:nexride_driver/support/driver_active_delivery_restore_support.dart';
import 'package:nexride_driver/support/driver_active_ride_restore_support.dart';

void main() {
  test('startup restore with active delivery pointer returns delivery id', () {
    final deliveryId = DriverActiveDeliveryRestoreSupport.resolveStartupDeliveryRestore(
      pointer: <String, dynamic>{
        'delivery_id': 'del_restore_1',
        'updated_at': 1700400000000,
      },
      rideWasRestored: false,
    );

    expect(deliveryId, 'del_restore_1');
    expect(
      DriverActiveDeliveryRestoreSupport.pointerDeliveryId(
        const <String, dynamic>{'deliveryId': 'del_restore_2'},
      ),
      'del_restore_2',
    );
  });

  test('startup restore with no pointer returns null', () {
    expect(
      DriverActiveDeliveryRestoreSupport.resolveStartupDeliveryRestore(
        pointer: null,
        rideWasRestored: false,
      ),
      isNull,
    );
    expect(
      DriverActiveDeliveryRestoreSupport.resolveStartupDeliveryRestore(
        pointer: const <String, dynamic>{},
        rideWasRestored: false,
      ),
      isNull,
    );
    expect(
      DriverActiveDeliveryRestoreSupport.pointerDeliveryId(
        const <String, dynamic>{'delivery_id': '  '},
      ),
      isNull,
    );
  });

  test('duplicate restore attempts do not create duplicate listeners', () {
    expect(
      DriverActiveDeliveryRestoreSupport.shouldSkipTrackingAttach(
        trackedDeliveryId: 'del_dup_1',
        hasActiveDeliverySubscription: true,
        candidateDeliveryId: 'del_dup_1',
      ),
      isTrue,
    );
    expect(
      DriverActiveDeliveryRestoreSupport.shouldSkipTrackingAttach(
        trackedDeliveryId: 'del_dup_1',
        hasActiveDeliverySubscription: false,
        candidateDeliveryId: 'del_dup_1',
      ),
      isFalse,
    );
    expect(
      DriverActiveDeliveryRestoreSupport.shouldSkipTrackingAttach(
        trackedDeliveryId: 'del_other',
        hasActiveDeliverySubscription: true,
        candidateDeliveryId: 'del_dup_1',
      ),
      isFalse,
    );
  });

  test('ride restore behavior unchanged when delivery pointer also exists', () {
    expect(
      DriverActiveDeliveryRestoreSupport.resolveStartupDeliveryRestore(
        pointer: const <String, dynamic>{'delivery_id': 'del_parallel'},
        rideWasRestored: true,
      ),
      isNull,
    );
    expect(
      DriverActiveRideRestoreSupport.pointerRideId(
        const <String, dynamic>{'ride_id': 'ride_restore_1'},
      ),
      'ride_restore_1',
    );
    expect(
      DriverActiveRideRestoreSupport.pointerRideId(
        const <String, dynamic>{'delivery_id': 'del_parallel'},
      ),
      isNull,
    );
  });
}

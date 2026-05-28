import 'package:flutter_test/flutter_test.dart';
import 'package:nexride_driver/support/driver_profile_support.dart';

void main() {
  group('inferServiceTypeFromLegacyProfile', () {
    test('ride-only legacy profile infers car_ride', () {
      expect(
        inferServiceTypeFromLegacyProfile(const <String, dynamic>{
          'serviceTypes': <String>['ride'],
          'driver_service_types': <String>['car_driver'],
        }),
        kServiceTypeCarRide,
      );
    });

    test('empty legacy profile infers car_ride', () {
      expect(
        inferServiceTypeFromLegacyProfile(const <String, dynamic>{}),
        kServiceTypeCarRide,
      );
    });

    test('dispatch legacy profile with no vehicle infers unknown_dispatch', () {
      expect(
        inferServiceTypeFromLegacyProfile(const <String, dynamic>{
          'serviceTypes': <String>['dispatch_delivery'],
          'driver_service_types': <String>['dispatch_driver'],
        }),
        kServiceTypeUnknownDispatch,
      );
    });

    test('explicit bike vehicle infers bike_dispatch', () {
      expect(
        inferServiceTypeFromLegacyProfile(const <String, dynamic>{
          'serviceTypes': <String>['dispatch_delivery'],
          'dispatch_vehicle_type': 'bike',
        }),
        kServiceTypeBikeDispatch,
      );
    });

    test('explicit van vehicle infers van_dispatch', () {
      expect(
        inferServiceTypeFromLegacyProfile(const <String, dynamic>{
          'serviceTypes': <String>['dispatch_delivery'],
          'dispatch_vehicle_type': 'van',
        }),
        kServiceTypeVanDispatch,
      );
    });

    test('existing canonical service_type is preserved', () {
      expect(
        inferServiceTypeFromLegacyProfile(const <String, dynamic>{
          'service_type': 'bike_dispatch',
          'serviceTypes': <String>['ride'],
        }),
        kServiceTypeBikeDispatch,
      );
    });
  });

  group('normalizers', () {
    test('normalizeDriverServiceType maps aliases and rejects unknowns', () {
      expect(normalizeDriverServiceType('CAR'), kServiceTypeCarRide);
      expect(normalizeDriverServiceType('okada'), kServiceTypeBikeDispatch);
      expect(normalizeDriverServiceType('van'), kServiceTypeVanDispatch);
      expect(normalizeDriverServiceType('dispatch'), kServiceTypeUnknownDispatch);
      expect(normalizeDriverServiceType('spaceship'), '');
      expect(normalizeDriverServiceType(null), '');
    });

    test('normalizeOwnershipMode maps aliases and rejects unknowns', () {
      expect(normalizeOwnershipMode('business_managed'), kOwnershipBusinessManaged);
      expect(normalizeOwnershipMode('fleet'), kOwnershipBusinessManaged);
      expect(normalizeOwnershipMode('individual'), kOwnershipIndividual);
      expect(normalizeOwnershipMode('weird'), '');
    });

    test('normalizeDispatchRole maps aliases and rejects unknowns', () {
      expect(normalizeDispatchRole('independent'), kDispatchRoleIndependent);
      expect(normalizeDispatchRole('fleet_employee'), kDispatchRoleFleetEmployee);
      expect(normalizeDispatchRole('none'), kDispatchRoleNone);
      expect(normalizeDispatchRole('boss'), '');
    });

    test('normalizeVerificationScope maps aliases and rejects unknowns', () {
      expect(
        normalizeVerificationScope('ride_hailing'),
        kVerificationScopeRideHailing,
      );
      expect(normalizeVerificationScope('dispatch'), kVerificationScopeDispatch);
      expect(normalizeVerificationScope('both'), kVerificationScopeMultiService);
      expect(normalizeVerificationScope('nope'), '');
    });
  });

  group('ownership defaults', () {
    test('ownership_mode business_managed is preserved', () {
      expect(
        defaultOwnershipModeForProfile(const <String, dynamic>{
          'ownership_mode': 'business_managed',
        }),
        kOwnershipBusinessManaged,
      );
    });

    test('missing ownership_mode defaults to individual', () {
      expect(
        defaultOwnershipModeForProfile(const <String, dynamic>{}),
        kOwnershipIndividual,
      );
    });

    test('never promotes an individual driver to business_managed', () {
      expect(
        defaultOwnershipModeForProfile(const <String, dynamic>{
          'ownership_mode': 'individual',
        }),
        kOwnershipIndividual,
      );
    });
  });

  group('derived defaults', () {
    test('dispatch role: car_ride is none, individual dispatch is independent', () {
      expect(
        defaultDispatchRoleForProfile(kServiceTypeCarRide, kOwnershipIndividual),
        kDispatchRoleNone,
      );
      expect(
        defaultDispatchRoleForProfile(
          kServiceTypeBikeDispatch,
          kOwnershipIndividual,
        ),
        kDispatchRoleIndependent,
      );
      expect(
        defaultDispatchRoleForProfile(
          kServiceTypeBikeDispatch,
          kOwnershipBusinessManaged,
        ),
        kDispatchRoleFleetEmployee,
      );
    });

    test('verification scope reflects service mix', () {
      expect(
        defaultVerificationScopeForProfile(
          const <String, dynamic>{'serviceTypes': <String>['ride']},
          kServiceTypeCarRide,
        ),
        kVerificationScopeRideHailing,
      );
      expect(
        defaultVerificationScopeForProfile(
          const <String, dynamic>{'serviceTypes': <String>['dispatch_delivery']},
          kServiceTypeBikeDispatch,
        ),
        kVerificationScopeDispatch,
      );
      expect(
        defaultVerificationScopeForProfile(
          const <String, dynamic>{
            'serviceTypes': <String>['ride', 'dispatch_delivery'],
          },
          kServiceTypeUnknownDispatch,
        ),
        kVerificationScopeMultiService,
      );
    });
  });

  group('compatibility helpers', () {
    test('serviceTypes derived correctly from canonical service type', () {
      expect(serviceTypesForDriverServiceType(kServiceTypeCarRide),
          <String>['ride']);
      expect(serviceTypesForDriverServiceType(kServiceTypeBikeDispatch),
          <String>['dispatch_delivery']);
      expect(serviceTypesForDriverServiceType(kServiceTypeVanDispatch),
          <String>['dispatch_delivery']);
      expect(serviceTypesForDriverServiceType(kServiceTypeUnknownDispatch),
          <String>['dispatch_delivery']);
    });

    test('dispatch vehicle type derived from canonical service type', () {
      expect(dispatchVehicleTypeForServiceType(kServiceTypeBikeDispatch), 'bike');
      expect(dispatchVehicleTypeForServiceType(kServiceTypeVanDispatch), 'van');
      expect(dispatchVehicleTypeForServiceType(kServiceTypeCarRide), 'car');
      expect(dispatchVehicleTypeForServiceType(kServiceTypeUnknownDispatch), '');
    });
  });

  group('buildDriverProfileRecord mirror fields', () {
    test('adds safe mirror fields for a fresh profile without wallet change', () {
      final profile = buildDriverProfileRecord(
        driverId: 'driver_fresh',
        existing: const <String, dynamic>{'name': 'Ada'},
      );

      expect(profile['service_type'], kServiceTypeCarRide);
      expect(profile['ownership_mode'], kOwnershipIndividual);
      expect(profile['dispatch_role'], kDispatchRoleNone);
      expect(profile['verification_scope'], kVerificationScopeRideHailing);
      // serviceTypes compatibility list is untouched (still defaulted).
      expect(profile['serviceTypes'], kDriverServiceTypes);
      // Wallet block contract is unchanged: individual drivers stay individual.
      expect(profile['wallet'], isA<Map<String, dynamic>>());
    });

    test('preserves an existing business_managed ownership_mode', () {
      final profile = buildDriverProfileRecord(
        driverId: 'driver_fleet',
        existing: const <String, dynamic>{
          'name': 'Biker',
          'ownership_mode': 'business_managed',
          'service_type': 'bike_dispatch',
        },
      );

      expect(profile['ownership_mode'], kOwnershipBusinessManaged);
      expect(profile['service_type'], kServiceTypeBikeDispatch);
      expect(profile['dispatch_role'], kDispatchRoleFleetEmployee);
    });

    test('does not overwrite an existing canonical service_type', () {
      final profile = buildDriverProfileRecord(
        driverId: 'driver_keep',
        existing: const <String, dynamic>{
          'service_type': 'van_dispatch',
          'serviceTypes': <String>['ride'],
        },
      );

      expect(profile['service_type'], kServiceTypeVanDispatch);
    });
  });
}

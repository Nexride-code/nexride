/// Slice 0 onboarding schema helpers.
///
/// Pure, side-effect-free normalization + inference for the future
/// service-type / ownership model. These helpers DO NOT change any live
/// behavior on their own: the values they produce are written as mirror
/// fields on the driver profile and are not yet read by dispatch matching,
/// wallet/withdrawal, or verification gates.
library;

/// Canonical service types.
const String kServiceTypeCarRide = 'car_ride';
const String kServiceTypeBikeDispatch = 'bike_dispatch';
const String kServiceTypeVanDispatch = 'van_dispatch';
const String kServiceTypeUnknownDispatch = 'unknown_dispatch';

const Set<String> kDriverServiceTypeValues = <String>{
  kServiceTypeCarRide,
  kServiceTypeBikeDispatch,
  kServiceTypeVanDispatch,
  kServiceTypeUnknownDispatch,
};

/// Canonical ownership modes.
const String kOwnershipIndividual = 'individual';
const String kOwnershipBusinessManaged = 'business_managed';

const Set<String> kOwnershipModeValues = <String>{
  kOwnershipIndividual,
  kOwnershipBusinessManaged,
};

/// Canonical dispatch roles.
const String kDispatchRoleIndependent = 'independent_dispatch';
const String kDispatchRoleFleetEmployee = 'fleet_employee';
const String kDispatchRoleNone = 'none';

const Set<String> kDispatchRoleValues = <String>{
  kDispatchRoleIndependent,
  kDispatchRoleFleetEmployee,
  kDispatchRoleNone,
};

/// Canonical verification scopes.
const String kVerificationScopeRideHailing = 'ride_hailing';
const String kVerificationScopeDispatch = 'dispatch';
const String kVerificationScopeMultiService = 'multi_service';

const Set<String> kVerificationScopeValues = <String>{
  kVerificationScopeRideHailing,
  kVerificationScopeDispatch,
  kVerificationScopeMultiService,
};

String _normText(dynamic value) =>
    value?.toString().trim().toLowerCase().replaceAll(RegExp(r'[\s-]+'), '_') ??
    '';

List<String> _stringListLower(dynamic value) {
  if (value is! List) {
    return const <String>[];
  }
  return value
      .map((dynamic entry) => entry?.toString().trim().toLowerCase() ?? '')
      .where((String entry) => entry.isNotEmpty)
      .toList(growable: false);
}

/// Normalizes a raw service-type value to one of the canonical service types.
///
/// Returns an empty string when the value is missing or unrecognized so the
/// caller can decide whether to infer a default.
String normalizeDriverServiceType(dynamic value) {
  final v = _normText(value);
  if (v.isEmpty) {
    return '';
  }
  switch (v) {
    case kServiceTypeCarRide:
    case 'car':
    case 'car_driver':
    case 'ride':
    case 'ride_hailing':
    case 'car_ride_hailing':
      return kServiceTypeCarRide;
    case kServiceTypeBikeDispatch:
    case 'bike':
    case 'okada':
    case 'motorcycle':
    case 'motorbike':
    case 'dispatch_bike':
      return kServiceTypeBikeDispatch;
    case kServiceTypeVanDispatch:
    case 'van':
    case 'minivan':
    case 'dispatch_van':
      return kServiceTypeVanDispatch;
    case kServiceTypeUnknownDispatch:
    case 'dispatch':
    case 'dispatch_driver':
    case 'dispatch_delivery':
      return kServiceTypeUnknownDispatch;
    default:
      return '';
  }
}

/// Normalizes a raw ownership-mode value. Returns empty string when missing or
/// unrecognized.
String normalizeOwnershipMode(dynamic value) {
  final v = _normText(value);
  switch (v) {
    case kOwnershipBusinessManaged:
    case 'business':
    case 'fleet':
    case 'fleet_managed':
      return kOwnershipBusinessManaged;
    case kOwnershipIndividual:
    case 'self':
    case 'personal':
      return kOwnershipIndividual;
    default:
      return '';
  }
}

/// Normalizes a raw dispatch-role value. Returns empty string when missing or
/// unrecognized.
String normalizeDispatchRole(dynamic value) {
  final v = _normText(value);
  switch (v) {
    case kDispatchRoleIndependent:
    case 'independent':
      return kDispatchRoleIndependent;
    case kDispatchRoleFleetEmployee:
    case 'fleet':
    case 'employee':
      return kDispatchRoleFleetEmployee;
    case kDispatchRoleNone:
    case 'na':
      return kDispatchRoleNone;
    default:
      return '';
  }
}

/// Normalizes a raw verification-scope value. Returns empty string when missing
/// or unrecognized.
String normalizeVerificationScope(dynamic value) {
  final v = _normText(value);
  switch (v) {
    case kVerificationScopeRideHailing:
    case 'ride':
    case 'ride_only':
      return kVerificationScopeRideHailing;
    case kVerificationScopeDispatch:
    case 'dispatch_only':
      return kVerificationScopeDispatch;
    case kVerificationScopeMultiService:
    case 'multi':
    case 'both':
      return kVerificationScopeMultiService;
    default:
      return '';
  }
}

String _dispatchVehicleHint(Map<String, dynamic> profile) {
  for (final dynamic raw in <dynamic>[
    profile['dispatch_vehicle_type'],
    profile['dispatchVehicleType'],
    profile['vehicle_type'],
    profile['vehicleType'],
  ]) {
    final v = _normText(raw);
    if (v.isEmpty) {
      continue;
    }
    switch (v) {
      case 'bike':
      case 'bicycle':
      case 'ebike':
      case 'e_bike':
      case 'motorcycle':
      case 'motorbike':
      case 'okada':
      case 'tricycle':
      case 'dispatch_bike':
        return 'bike';
      case 'van':
      case 'minivan':
      case 'mpv':
        return 'van';
      case 'car':
      case 'sedan':
      case 'suv':
      case 'saloon':
      case 'hatchback':
      case 'wagon':
        return 'car';
    }
  }
  return '';
}

bool _legacyHasRide(Map<String, dynamic> profile) {
  final serviceTypes = <String>[
    ..._stringListLower(profile['serviceTypes']),
    ..._stringListLower(profile['service_types']),
    ..._stringListLower(profile['services']),
  ];
  if (serviceTypes.contains('ride')) {
    return true;
  }
  final driverServiceTypes = <String>[
    ..._stringListLower(profile['driver_service_types']),
    ..._stringListLower(profile['driverServiceTypes']),
  ];
  return driverServiceTypes.contains('car_driver');
}

bool _legacyHasDispatch(Map<String, dynamic> profile) {
  final serviceTypes = <String>[
    ..._stringListLower(profile['serviceTypes']),
    ..._stringListLower(profile['service_types']),
    ..._stringListLower(profile['services']),
  ];
  if (serviceTypes.any(
    (String s) => s == 'dispatch_delivery' || s.startsWith('dispatch'),
  )) {
    return true;
  }
  final driverServiceTypes = <String>[
    ..._stringListLower(profile['driver_service_types']),
    ..._stringListLower(profile['driverServiceTypes']),
  ];
  return driverServiceTypes.contains('dispatch_driver');
}

/// Infers a canonical service type from a (possibly legacy) driver profile
/// without ever overwriting an explicit canonical value.
///
/// Rules:
/// - An existing canonical `service_type` is preserved.
/// - An explicit bike/van/car vehicle hint maps to the matching service type.
/// - Dispatch with no clear vehicle infers `unknown_dispatch` (never bike).
/// - Ride-only or empty profiles infer `car_ride`.
String inferServiceTypeFromLegacyProfile(Map<String, dynamic> profile) {
  final canonical = normalizeDriverServiceType(
    profile['service_type'] ?? profile['serviceType'],
  );
  if (canonical.isNotEmpty) {
    return canonical;
  }

  final vehicle = _dispatchVehicleHint(profile);
  if (vehicle == 'bike') {
    return kServiceTypeBikeDispatch;
  }
  if (vehicle == 'van') {
    return kServiceTypeVanDispatch;
  }
  if (vehicle == 'car') {
    return kServiceTypeCarRide;
  }

  if (_legacyHasDispatch(profile)) {
    return kServiceTypeUnknownDispatch;
  }
  return kServiceTypeCarRide;
}

/// Ownership defaults to `individual` unless `business_managed` already exists.
/// Never promotes a driver to `business_managed`.
String defaultOwnershipModeForProfile(Map<String, dynamic> profile) {
  final existing = normalizeOwnershipMode(
    profile['ownership_mode'] ?? profile['ownershipMode'],
  );
  if (existing == kOwnershipBusinessManaged) {
    return kOwnershipBusinessManaged;
  }
  return kOwnershipIndividual;
}

/// Default dispatch role derived from service type + ownership mode.
String defaultDispatchRoleForProfile(
  String serviceType,
  String ownershipMode,
) {
  final svc = normalizeDriverServiceType(serviceType);
  if (svc == kServiceTypeCarRide) {
    return kDispatchRoleNone;
  }
  if (svc.isEmpty) {
    return kDispatchRoleNone;
  }
  if (normalizeOwnershipMode(ownershipMode) == kOwnershipBusinessManaged) {
    return kDispatchRoleFleetEmployee;
  }
  return kDispatchRoleIndependent;
}

/// Default verification scope derived from the profile + canonical service type.
/// A profile that legacy-supports both ride and dispatch is `multi_service`.
String defaultVerificationScopeForProfile(
  Map<String, dynamic> profile,
  String serviceType,
) {
  final hasRide = _legacyHasRide(profile);
  final hasDispatch = _legacyHasDispatch(profile);
  if (hasRide && hasDispatch) {
    return kVerificationScopeMultiService;
  }
  final svc = normalizeDriverServiceType(serviceType);
  if (svc == kServiceTypeCarRide || svc.isEmpty) {
    return kVerificationScopeRideHailing;
  }
  return kVerificationScopeDispatch;
}

/// Compatibility request service-types for a canonical service type.
/// Preserves the existing matching contract (`ride` / `dispatch_delivery`).
List<String> serviceTypesForDriverServiceType(String serviceType) {
  switch (normalizeDriverServiceType(serviceType)) {
    case kServiceTypeCarRide:
      return const <String>['ride'];
    case kServiceTypeBikeDispatch:
    case kServiceTypeVanDispatch:
    case kServiceTypeUnknownDispatch:
      return const <String>['dispatch_delivery'];
    default:
      return const <String>['ride'];
  }
}

/// Dispatch vehicle type implied by a canonical service type.
/// Returns empty string when the vehicle is not yet known.
String dispatchVehicleTypeForServiceType(String serviceType) {
  switch (normalizeDriverServiceType(serviceType)) {
    case kServiceTypeBikeDispatch:
      return 'bike';
    case kServiceTypeVanDispatch:
      return 'van';
    case kServiceTypeCarRide:
      return 'car';
    default:
      return '';
  }
}

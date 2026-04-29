import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

import 'app_role.dart';
import 'driver_profile_support.dart';
import 'realtime_database_error_support.dart';

const Duration kDriverProfileReadTimeout = Duration(seconds: 10);

class DriverProfileFetchResult {
  const DriverProfileFetchResult({
    required this.path,
    required this.profile,
    required this.snapshotFound,
    required this.createdFallbackProfile,
    required this.uidMatchesRecord,
    required this.rawValueType,
    this.recordId,
    this.parseWarning,
    this.readError,
    this.persistWarning,
  });

  final String path;
  final Map<String, dynamic> profile;
  final bool snapshotFound;
  final bool createdFallbackProfile;
  final bool uidMatchesRecord;
  final String rawValueType;
  final String? recordId;
  final String? parseWarning;
  /// Non-fatal: primary RTDB read failed; profile is in-memory defaults + existing empty.
  final String? readError;
  /// Non-fatal: optional RTDB repair / mirror write failed.
  final String? persistWarning;
}

void _logFirebaseDatabaseError(String label, Object error) {
  if (error is FirebaseException) {
    debugPrint(
      '$label firebase code=${error.code} message=${error.message}',
    );
    return;
  }
  debugPrint('$label error=$error');
}

Future<Map<String, dynamic>> fetchDriverPricingConfig({
  required DatabaseReference rootRef,
  required String source,
}) async {
  const path = 'app_config/pricing';
  debugPrint('[DriverProfile] pricing fetch started source=$source path=$path');
  try {
    final snapshot =
        await rootRef.child(path).get().timeout(kDriverProfileReadTimeout);
    final rawValue = snapshot.value;
    if (rawValue is Map) {
      final pricing = Map<String, dynamic>.from(rawValue);
      debugPrint(
        '[DriverProfile] pricing fetch completed source=$source path=$path found=true keys=${pricing.keys.length}',
      );
      return pricing;
    }
    debugPrint(
      '[DriverProfile] pricing fetch completed source=$source path=$path found=false valueType=${rawValue?.runtimeType ?? 'null'}',
    );
  } catch (error, stackTrace) {
    if (isRealtimeDatabasePermissionDenied(error)) {
      debugPrint(
        '[DriverProfile] pricing config unavailable for source=$source; using embedded defaults.',
      );
      return <String, dynamic>{};
    }
    debugPrint(
      '[DriverProfile] pricing fetch failed source=$source path=$path error=$error',
    );
    debugPrintStack(
      label: '[DriverProfile] pricing fetch stack',
      stackTrace: stackTrace,
    );
  }
  return <String, dynamic>{};
}

Future<void> _persistDriverVerificationShadow({
  required DatabaseReference rootRef,
  required String verificationPath,
  required String source,
  required String uid,
  required Map<String, Object?> verificationPayload,
}) async {
  try {
    await rootRef.child(verificationPath).set(verificationPayload);
    debugPrint(
      '[DriverProfile] verification shadow write ok source=$source uid=$uid path=$verificationPath',
    );
  } catch (error, stackTrace) {
    _logFirebaseDatabaseError(
      '[DriverProfile] verification shadow write FAILED source=$source uid=$uid path=$verificationPath',
      error,
    );
    debugPrintStack(
      label: '[DriverProfile] verification shadow stack',
      stackTrace: stackTrace,
    );
  }
}

Future<DriverProfileFetchResult> fetchDriverProfileRecord({
  required DatabaseReference rootRef,
  required User user,
  required String source,
  required AppRole role,
  bool createIfMissing = true,
}) async {
  final uid = user.uid.trim();
  final path = driverProfilePath(uid);
  if (role != AppRole.driver) {
    throw StateError('Driver app received non-driver role');
  }
  assertRoleScopedPath(role: role, path: path);
  final verificationPath = driverVerificationAdminPath(uid);
  final profileRef = rootRef.child(path);

  print('BOOTSTRAP TYPE: DRIVER');
  debugPrint(
    '[DriverProfile] fetch started role=${role.name} source=$source uid=$uid path=$path mode=get_timeout=${kDriverProfileReadTimeout.inSeconds}s',
  );
  debugPrint(
    '[DRIVER_BACKEND] op=driver_profile_fetch authUid=$uid driverProfilePath=$path source=$source',
  );
  debugPrint(
    '[DRIVER_PROFILE_CHECK] uid=$uid path=$path op=get createIfMissing=$createIfMissing',
  );

  DataSnapshot? snapshot;
  String? readError;
  Object? readException;
  try {
    snapshot = await profileRef.get().timeout(kDriverProfileReadTimeout);
  } on TimeoutException catch (error, stackTrace) {
    readException = error;
    readError = 'read_timeout:$error';
    debugPrint(
      '[DriverProfile] drivers node read TIMEOUT source=$source uid=$uid path=$path',
    );
    debugPrintStack(
      label: '[DriverProfile] read timeout stack',
      stackTrace: stackTrace,
    );
  } catch (error, stackTrace) {
    readException = error;
    readError = error.toString();
    _logFirebaseDatabaseError(
      '[DriverProfile] drivers node read FAILED source=$source uid=$uid path=$path',
      error,
    );
    debugPrintStack(
      label: '[DriverProfile] read stack',
      stackTrace: stackTrace,
    );
  }

  final readSucceeded = snapshot != null;
  final snapshotExists = snapshot?.exists == true;
  final readDeniedByRules = readException != null &&
      isRealtimeDatabasePermissionDenied(readException);
  final rawValue = snapshot?.value;
  final rawValueType = rawValue?.runtimeType.toString() ?? 'null';

  debugPrint(
    '[DriverProfile] raw fetch result source=$source uid=$uid path=$path readOk=$readSucceeded exists=$snapshotExists valueType=$rawValueType readError=${readError ?? 'none'}',
  );

  Map<String, dynamic> existing = <String, dynamic>{};
  String? parseWarning;

  if (rawValue is Map) {
    existing = Map<String, dynamic>.from(rawValue);
  } else if (rawValue != null) {
    parseWarning = 'expected_map_received_$rawValueType';
    debugPrint(
      '[DriverProfile] parsing failure source=$source uid=$uid path=$path reason=$parseWarning',
    );
  }

  final recordId = (existing['id'] ?? existing['uid'])?.toString().trim();
  final uidMatchesRecord =
      recordId == null || recordId.isEmpty || recordId == uid;
  final pricingConfig = await fetchDriverPricingConfig(
    rootRef: rootRef,
    source: source,
  );
  debugPrint(
    '[DriverProfile] uid consistency source=$source uid=$uid path=$path recordId=${recordId?.isNotEmpty == true ? recordId : 'none'} matches=$uidMatchesRecord',
  );

  final profile = buildDriverProfileRecord(
    driverId: uid,
    existing: existing,
    fallbackName: user.displayName ?? user.email?.split('@').first,
    fallbackEmail: user.email,
    fallbackPhone: user.phoneNumber,
    pricingConfig: pricingConfig,
  );

  debugPrint(
    '[DriverProfile] parsing success source=$source uid=$uid path=$path name=${profile['name']} status=${profile['status']} online=${profile['isOnline']} services=${(profile['serviceTypes'] as List<dynamic>).join(',')}',
  );

  var createdFallbackProfile = false;
  String? persistWarning;

  final missingBusinessModel =
      existing['businessModel'] is! Map && existing['business_model'] is! Map;
  final missingVerification = existing['verification'] is! Map;
  final missingServiceTypes = existing['serviceTypes'] is! List;
  final missingWallet = existing['wallet'] is! Map;
  final missingEarnings = existing['earnings'] is! Map;
  final missingSupportCounters = existing['supportCounters'] is! Map &&
      existing['support_counters'] is! Map;
  final missingTrips = !existing.containsKey('trips');
  final missingAvailabilityFlags = !existing.containsKey('isAvailable') ||
      !existing.containsKey('available');
  final missingOnlineAlias =
      !existing.containsKey('isOnline') && existing.containsKey('online');
  final requiresCompatibilityRepair = readSucceeded &&
      snapshotExists &&
      (parseWarning != null ||
          !uidMatchesRecord ||
          existing['id']?.toString().trim() != uid ||
          existing['uid']?.toString().trim() != uid ||
          missingBusinessModel ||
          missingVerification ||
          missingServiceTypes ||
          missingWallet ||
          missingEarnings ||
          missingSupportCounters ||
          missingTrips ||
          missingAvailabilityFlags ||
          missingOnlineAlias);

  if (createIfMissing &&
      !snapshotExists &&
      (readSucceeded || readDeniedByRules)) {
    final verification =
        Map<String, dynamic>.from(profile['verification'] as Map? ?? const {});
    debugPrint(
      '[DriverProfile] fallback profile creation started source=$source uid=$uid path=$path verificationPath=$verificationPath',
    );
    final driverPayload = <String, Object?>{
      ...profile.map((k, v) => MapEntry(k, v as Object?)),
      'id': uid,
      'uid': uid,
      'created_at': ServerValue.timestamp,
      'updated_at': ServerValue.timestamp,
      'last_active': ServerValue.timestamp,
    };
    try {
      await profileRef.update(driverPayload);
      createdFallbackProfile = true;
      debugPrint(
        '[DRIVER_PROFILE_REPAIR] uid=$uid path=$path op=seed_create ok=true readDenied=$readDeniedByRules',
      );
      debugPrint(
        '[DriverProfile] drivers node create/repair write ok source=$source uid=$uid path=$path',
      );
    } catch (error, stackTrace) {
      persistWarning = 'drivers_write_failed:$error';
      _logFirebaseDatabaseError(
        '[DriverProfile] drivers node write FAILED source=$source uid=$uid path=$path',
        error,
      );
      debugPrintStack(
        label: '[DriverProfile] drivers write stack',
        stackTrace: stackTrace,
      );
    }

    final verificationPayload = <String, Object?>{
      ...buildDriverVerificationAdminPayload(
        driverId: uid,
        driverProfile: profile,
        verification: verification,
      ).map((k, v) => MapEntry(k, v as Object?)),
      'createdAt': ServerValue.timestamp,
      'updatedAt': ServerValue.timestamp,
    };
    await _persistDriverVerificationShadow(
      rootRef: rootRef,
      verificationPath: verificationPath,
      source: source,
      uid: uid,
      verificationPayload: verificationPayload,
    );
    debugPrint(
      '[DriverProfile] fallback profile creation flow finished source=$source uid=$uid path=$path createdDriverNode=$createdFallbackProfile',
    );
  } else if (requiresCompatibilityRepair) {
    debugPrint(
      '[DriverProfile] compatibility repair started source=$source uid=$uid path=$path',
    );
    final repairPayload = <String, Object?>{
      ...profile.map((k, v) => MapEntry(k, v as Object?)),
      'id': uid,
      'uid': uid,
      'updated_at': ServerValue.timestamp,
    };
    try {
      await profileRef.update(repairPayload);
      debugPrint(
        '[DriverProfile] compatibility repair completed source=$source uid=$uid path=$path',
      );
    } catch (error, stackTrace) {
      persistWarning = 'repair_failed:$error';
      _logFirebaseDatabaseError(
        '[DriverProfile] compatibility repair FAILED source=$source uid=$uid path=$path',
        error,
      );
      debugPrintStack(
        label: '[DriverProfile] repair stack',
        stackTrace: stackTrace,
      );
    }
  }

  return DriverProfileFetchResult(
    path: path,
    profile: profile,
    snapshotFound: snapshotExists,
    createdFallbackProfile: createdFallbackProfile,
    uidMatchesRecord: uidMatchesRecord,
    rawValueType: rawValueType,
    recordId: recordId,
    parseWarning: parseWarning,
    readError: readError,
    persistWarning: persistWarning,
  );
}

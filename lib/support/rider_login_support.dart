import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart' as rtdb;
import 'package:flutter/foundation.dart';

import '../services/rider_trust_bootstrap_service.dart';
import 'friendly_firebase_errors.dart';
import 'nexride_contact_constants.dart';
import 'startup_rtdb_support.dart';

const Duration kRiderLoginAuthTimeout = Duration(seconds: 15);
const Duration kRiderLoginProfileTimeout = Duration(seconds: 10);

/// Safe user copy + always-logged debug detail for login failures.
class RiderLoginFailure {
  const RiderLoginFailure({
    required this.userMessage,
    required this.debugDetail,
    required this.logTag,
  });

  final String userMessage;
  final String debugDetail;
  final String logTag;
}

class RiderLoginProfileResult {
  const RiderLoginProfileResult({
    required this.userData,
    required this.profileSetupRequired,
    required this.effectiveRole,
  });

  final Map<String, dynamic> userData;
  final bool profileSetupRequired;
  final String effectiveRole;
}

const Set<String> kRiderAppCompatibleRoles = <String>{
  'rider',
  'customer',
  'passenger',
  'user',
};

const Set<String> kRiderAppIncompatibleRoles = <String>{
  'driver',
  'merchant',
  'admin',
  'support',
  'support_agent',
  'support_manager',
};

void logRiderLoginTap() => debugPrint('RIDER_LOGIN_TAP');

void logRiderLoginAuthStart() => debugPrint('RIDER_LOGIN_AUTH_START');

void logRiderLoginAuthSuccess(String uid) =>
    debugPrint('RIDER_LOGIN_AUTH_SUCCESS uid=$uid');

void logRiderLoginProfileStart(String uid) =>
    debugPrint('RIDER_LOGIN_PROFILE_START uid=$uid');

void logRiderLoginProfileSuccess(String uid) =>
    debugPrint('RIDER_LOGIN_PROFILE_SUCCESS uid=$uid');

void logRiderLoginProfileFail(String uid, Object error) {
  debugPrint('RIDER_LOGIN_PROFILE_FAIL uid=$uid error=$error');
  _logPermissionHints(error, path: 'users/$uid');
}

void logRiderLoginTimeout(Object error) =>
    debugPrint('RIDER_LOGIN_TIMEOUT error=$error');

void logRiderLoginNavigateHomeStart() =>
    debugPrint('RIDER_LOGIN_NAVIGATE_HOME_START');

void logRiderLoginNavigateHomeDone() =>
    debugPrint('RIDER_LOGIN_NAVIGATE_HOME_DONE');

void logRiderLoginNavigateHomeSkippedDuplicate() =>
    debugPrint('RIDER_LOGIN_NAVIGATE_HOME_SKIPPED_DUPLICATE');

void logRiderLoginFail(Object error, StackTrace? stackTrace) {
  debugPrint('RIDER_LOGIN_FAIL error=$error');
  if (stackTrace != null) {
    debugPrintStack(label: 'RIDER_LOGIN_FAIL', stackTrace: stackTrace);
  }
}

void logRiderRoleCheckFail(String uid, String role) {
  debugPrint('RIDER_ROLE_CHECK_FAIL uid=$uid role=$role');
}

String resolveRiderRole(Map<String, dynamic> profile) {
  return (profile['role'] ?? profile['user_type'] ?? profile['account_type'] ?? 'rider')
      .toString()
      .trim()
      .toLowerCase();
}

bool isRiderAppCompatibleRole(String role) {
  final normalized = role.trim().toLowerCase();
  if (normalized.isEmpty) {
    return true;
  }
  if (kRiderAppIncompatibleRoles.contains(normalized)) {
    return false;
  }
  if (kRiderAppCompatibleRoles.contains(normalized)) {
    return true;
  }
  debugPrint('RIDER_ROLE_UNKNOWN_ALLOWED role=$normalized');
  return true;
}

String riderRoleRejectionMessage(String role) {
  switch (role) {
    case 'driver':
      return 'This account is registered as a driver. Please use the NexRide Driver app to sign in.';
    case 'merchant':
      return 'This account is registered as a merchant. Please use the NexRide Merchant app.';
    case 'admin':
    case 'support':
    case 'support_agent':
    case 'support_manager':
      return 'This account is for staff access. Use the admin portal instead of the rider app.';
    default:
      return 'This account is not enabled for the rider app. Contact $kNexRideSupportEmail.';
  }
}

RiderLoginFailure classifyLoginFailure(
  Object error, {
  StackTrace? stackTrace,
  String phase = 'login',
}) {
  if (error is TimeoutException) {
    return RiderLoginFailure(
      logTag: 'RIDER_LOGIN_TIMEOUT',
      debugDetail: 'RIDER_LOGIN_TIMEOUT phase=$phase error=$error',
      userMessage:
          'Login is taking too long. Please check your internet and try again.',
    );
  }

  final tag = 'RIDER_LOGIN_FAIL';
  final buffer = StringBuffer('$tag phase=$phase error=$error');
  if (error is FirebaseAuthException) {
    buffer.write(' code=${error.code}');
  }
  if (error is FirebaseException) {
    buffer.write(' firebaseCode=${error.code} plugin=${error.plugin}');
  }
  if (error is StartupRtdbException) {
    buffer.write(' rtdbPath=${error.path} cause=${error.cause}');
  }
  if (stackTrace != null && kDebugMode) {
    buffer.write('\n$stackTrace');
  }

  final debugDetail = buffer.toString();

  if (error is FirebaseAuthException) {
    return RiderLoginFailure(
      logTag: tag,
      debugDetail: debugDetail,
      userMessage: friendlyFirebaseAuthError(error),
    );
  }

  if (error is FirebaseException && error.plugin == 'cloud-firestore') {
    return RiderLoginFailure(
      logTag: 'FIRESTORE_PERMISSION_DENIED',
      debugDetail: debugDetail,
      userMessage:
          'We could not load your account profile. Please try again or contact $kNexRideSupportEmail.',
    );
  }

  if (error is FirebaseException && error.plugin == 'firebase-database') {
    return RiderLoginFailure(
      logTag: 'RTDB_PERMISSION_DENIED',
      debugDetail: debugDetail,
      userMessage:
          'We could not sync your rider profile. Check your connection or contact $kNexRideSupportEmail.',
    );
  }

  if (isPermissionDeniedError(error)) {
    return RiderLoginFailure(
      logTag: 'RTDB_PERMISSION_DENIED',
      debugDetail: debugDetail,
      userMessage:
          'Your account signed in, but profile access was blocked. Contact $kNexRideSupportEmail for help.',
    );
  }

  if (error is StartupRtdbException) {
    return RiderLoginFailure(
      logTag: tag,
      debugDetail: debugDetail,
      userMessage:
          'Signed in, but profile setup did not finish. You can retry or contact $kNexRideSupportEmail.',
    );
  }

  return RiderLoginFailure(
    logTag: tag,
    debugDetail: debugDetail,
    userMessage: friendlyFirebaseError(
      error,
      debugLabel: tag,
      mapPermissionDeniedAsConnectivity: false,
    ),
  );
}

void _logPermissionHints(Object error, {required String path}) {
  final lower = error.toString().toLowerCase();
  if (lower.contains('permission-denied')) {
    if (error is FirebaseException && error.plugin == 'cloud-firestore') {
      debugPrint('FIRESTORE_PERMISSION_DENIED path=$path');
    } else {
      debugPrint('RTDB_PERMISSION_DENIED path=$path');
    }
  }
}

String formatLoginFailureForSnack(RiderLoginFailure failure) {
  debugPrint('${failure.logTag} ${failure.debugDetail}');
  if (kDebugMode) {
    final short = failure.debugDetail.length > 220
        ? '${failure.debugDetail.substring(0, 220)}…'
        : failure.debugDetail;
    return '${failure.userMessage}\n\nDebug: $short';
  }
  return failure.userMessage;
}

Future<Map<String, dynamic>> _fetchProfileWithTimeout({
  required rtdb.DatabaseReference rootRef,
  required String uid,
}) async {
  logRiderLoginProfileStart(uid);
  try {
    final profile = await readUserProfileWithFallback(
      rootRef: rootRef,
      uid: uid,
      source: 'rider_login.user_profile',
    ).timeout(kRiderLoginProfileTimeout);
    logRiderLoginProfileSuccess(uid);
    return profile;
  } on TimeoutException catch (error) {
    logRiderLoginProfileFail(uid, error);
    rethrow;
  } catch (error, stackTrace) {
    logRiderLoginProfileFail(uid, error);
    debugPrintStack(label: 'RIDER_LOGIN_PROFILE_FAIL', stackTrace: stackTrace);
    return <String, dynamic>{};
  }
}

Future<void> _bootstrapProfileWithTimeout({
  required rtdb.DatabaseReference rootRef,
  required String uid,
  required String email,
  required Map<String, dynamic> userData,
  required RiderTrustBootstrapService trustBootstrapService,
}) async {
  final bundle = await trustBootstrapService
      .ensureRiderTrustState(
        riderId: uid,
        existingUser: userData,
        fallbackName: email.split('@').first,
        fallbackEmail: email,
      )
      .timeout(kRiderLoginProfileTimeout);

  final bootstrapReady = await hasRiderBootstrapArtifacts(
    rootRef: rootRef,
    riderId: uid,
    source: 'rider_login.bootstrap_check',
  ).timeout(kRiderLoginProfileTimeout);

  if (!bootstrapReady) {
    try {
      await persistRiderOwnedBootstrap(
        rootRef: rootRef,
        riderId: uid,
        userProfile: <String, dynamic>{
          ...userData,
          ...bundle.userProfile,
          'created_at': userData['created_at'] ?? rtdb.ServerValue.timestamp,
        },
        verification: bundle.verification,
        deviceFingerprints: bundle.deviceFingerprints,
        source: 'rider_login.bootstrap_write',
      ).timeout(kRiderLoginProfileTimeout);
    } on StartupRtdbException {
      await persistMinimalRiderProfileBestEffort(
        rootRef: rootRef,
        riderId: uid,
        email: email,
        displayNameFallback: email.split('@').first,
        source: 'rider_login.minimal_after_bootstrap_failure',
      );
    }
  } else {
    await touchRiderProfileUpdatedAt(rootRef: rootRef, uid: uid);
  }
}

/// Profile fetch + trust bootstrap with overall timeout; never throws except TimeoutException.
Future<RiderLoginProfileResult> restoreOrCreateRiderProfileAfterLogin({
  required rtdb.DatabaseReference rootRef,
  required String uid,
  required String email,
  required RiderTrustBootstrapService trustBootstrapService,
}) async {
  return _restoreOrCreateRiderProfileAfterLoginImpl(
    rootRef: rootRef,
    uid: uid,
    email: email,
    trustBootstrapService: trustBootstrapService,
  ).timeout(kRiderLoginProfileTimeout);
}

Future<RiderLoginProfileResult> _restoreOrCreateRiderProfileAfterLoginImpl({
  required rtdb.DatabaseReference rootRef,
  required String uid,
  required String email,
  required RiderTrustBootstrapService trustBootstrapService,
}) async {
  Map<String, dynamic> existingUser = <String, dynamic>{};
  try {
    existingUser = await _fetchProfileWithTimeout(rootRef: rootRef, uid: uid);
  } on TimeoutException {
    rethrow;
  }

  final userData = <String, dynamic>{
    ...existingUser,
    if (existingUser.isEmpty) ...<String, dynamic>{
      'uid': uid,
      'name': email.split('@').first,
      'email': email,
      'phone': '',
      'role': 'rider',
      'created_at': rtdb.ServerValue.timestamp,
    },
  };

  var profileSetupRequired = existingUser.isEmpty;

  try {
    await _bootstrapProfileWithTimeout(
      rootRef: rootRef,
      uid: uid,
      email: email,
      userData: userData,
      trustBootstrapService: trustBootstrapService,
    );
  } on TimeoutException {
    rethrow;
  } catch (error, stackTrace) {
    debugPrint('RIDER_LOGIN_PROFILE_FAIL uid=$uid bootstrap_error=$error');
    debugPrintStack(label: 'RIDER_LOGIN_PROFILE_BOOTSTRAP', stackTrace: stackTrace);
    profileSetupRequired = true;
    await persistMinimalRiderProfileBestEffort(
      rootRef: rootRef,
      riderId: uid,
      email: email,
      displayNameFallback: email.split('@').first,
      source: 'rider_login.minimal_after_unexpected_failure',
    );
  }

  return RiderLoginProfileResult(
    userData: userData,
    profileSetupRequired: profileSetupRequired,
    effectiveRole: resolveRiderRole(userData),
  );
}

Future<void> touchRiderProfileUpdatedAt({
  required rtdb.DatabaseReference rootRef,
  required String uid,
}) async {
  try {
    await rootRef.child('users/$uid').update(<String, dynamic>{
      'updated_at': rtdb.ServerValue.timestamp,
    }).timeout(const Duration(seconds: 5));
  } catch (error) {
    debugPrint('RIDER_PROFILE_TOUCH_FAIL uid=$uid error=$error');
    _logPermissionHints(error, path: 'users/$uid');
  }
}

import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart'
    show FirebaseAuthException, FirebaseException;
import 'package:flutter/foundation.dart';

import 'production_user_messages.dart';
import 'realtime_database_error_support.dart' show isRealtimeDatabasePermissionDenied;

const String kFriendlyGenericFailureMessage =
    'Something went wrong. Please try again.';

const String kFriendlyNetworkFailureMessage =
    'We could not reach NexRide right now. Check your connection and try again.';

String coerceUserFacingMessage(String? raw) {
  final s = raw?.trim() ?? '';
  if (s.isEmpty) {
    return kFriendlyGenericFailureMessage;
  }
  final lower = s.toLowerCase();
  if (s.length > 180) {
    return kFriendlyGenericFailureMessage;
  }
  if (lower.contains('firebase') ||
      lower.contains('permission-denied') ||
      lower.contains('firebase_functions') ||
      lower.contains('firebaseexception') ||
      lower.startsWith('exception:') ||
      lower.contains('[firebase') ||
      lower.contains('internal assertion') ||
      lower.contains('platform_exception')) {
    return kFriendlyGenericFailureMessage;
  }
  return s;
}

String friendlyCallableReason(
  Map<String, dynamic>? response, {
  String fallback = kFriendlyGenericFailureMessage,
}) {
  final r =
      response?['reason']?.toString().trim().replaceAll(RegExp(r'\s+'), '_').toLowerCase() ??
      '';
  switch (r) {
    case 'unauthorized':
    case 'forbidden':
      return 'You do not have permission to do that.';
    case 'invalid_input':
    case 'disallowed_field':
      return 'Something was wrong with that request. Please try again.';
    case 'ride_missing':
    case 'not_found':
      return 'We could not find that trip.';
    case '':
      return fallback;
    default:
      return fallback;
  }
}

String friendlyFirebaseAuthError(Object error) {
  if (error is! FirebaseAuthException) {
    return kFriendlyGenericFailureMessage;
  }
  debugPrint(
    '[friendlyFirebaseAuthError] code=${error.code} message=${error.message}',
  );
  switch (error.code) {
    case 'user-not-found':
      return 'No account found for that email.';
    case 'wrong-password':
    case 'invalid-credential':
    case 'invalid-login-credentials':
      return 'Incorrect email or password.';
    case 'invalid-email':
      return 'That email address does not look valid.';
    case 'user-disabled':
      return 'This account has been disabled. Contact support.';
    case 'email-already-in-use':
      return 'That email is already registered.';
    case 'weak-password':
      return 'Please choose a stronger password.';
    case 'network-request-failed':
    case 'too-many-requests':
      return kFriendlyNetworkFailureMessage;
    case 'missing-user':
      return kProductionNexRideSupportMessage;
    default:
      final msg = error.message?.trim() ?? '';
      if (msg.isNotEmpty &&
          msg.length < 120 &&
          !msg.toLowerCase().contains('firebase')) {
        return msg;
      }
      return kProductionNexRideSupportMessage;
  }
}

String friendlyFirebaseError(
  Object error, {
  String? debugLabel,
  bool mapPermissionDeniedAsConnectivity = true,
}) {
  final tag = debugLabel ?? 'friendlyFirebaseError';
  debugPrint('[$tag] raw=$error');

  if (error is FirebaseAuthException) {
    return friendlyFirebaseAuthError(error);
  }
  if (error is FirebaseFunctionsException) {
    final code = error.code.trim().toLowerCase();
    debugPrint(
      '[$tag] callable code=$code message=${error.message} details=${error.details}',
    );
    if (code == 'not-found' ||
        code == 'unavailable' ||
        code == 'deadline-exceeded' ||
        code == 'internal') {
      return kFriendlyNetworkFailureMessage;
    }
    return kFriendlyGenericFailureMessage;
  }
  if (error is FirebaseException) {
    final code = error.code.trim().toLowerCase();
    if (code == 'permission-denied' || isRealtimeDatabasePermissionDenied(error)) {
      if (!mapPermissionDeniedAsConnectivity) {
        return kFriendlyGenericFailureMessage;
      }
      return 'Unable to connect to NexRide services right now.';
    }
    return kFriendlyNetworkFailureMessage;
  }
  if (isRealtimeDatabasePermissionDenied(error)) {
    if (!mapPermissionDeniedAsConnectivity) {
      return kFriendlyGenericFailureMessage;
    }
    return 'Unable to connect to NexRide services right now.';
  }
  if (error is TimeoutException) {
    return 'That took too long. Please try again.';
  }
  return coerceUserFacingMessage(
    error
        .toString()
        .replaceFirst('Exception: ', '')
        .replaceFirst('FirebaseException: ', ''),
  );
}

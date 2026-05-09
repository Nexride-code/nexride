import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart'
    show FirebaseAuthException, FirebaseException;
import 'package:flutter/foundation.dart';

import 'nexride_contact_constants.dart';
import 'production_user_messages.dart';
import 'startup_rtdb_support.dart' show isPermissionDeniedError;

/// Safe fallback when an error should never surface technical detail.
const String kFriendlyGenericFailureMessage =
    'Something went wrong. Please try again.';

const String kFriendlyNetworkFailureMessage =
    'We could not reach NexRide right now. Check your connection and try again.';

/// Redacts technical backend / Firebase strings for in-app display.
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

/// Maps Cloud Function JSON [reason] (never raw exception text).
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
    case 'ride_not_completed':
      return 'This trip must be marked complete before uploading a receipt.';
    case 'invalid_payment_method_for_receipt':
      return 'Receipt upload applies to bank-transfer trips only.';
    case 'prepaid_already_used':
    case 'already_used':
      return 'That payment has already been used for a trip.';
    case 'prepaid_intent_abandoned':
    case 'intent_abandoned':
      return 'That payment session was discarded. Start a new trip when ready.';
    case '':
      return fallback;
    default:
      return fallback;
  }
}

/// User-facing authentication errors only.
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
      return 'This account has been disabled. Contact support at $kNexRideSupportEmail.';
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
      return kProductionRiderLoginSupportMessage;
  }
}

/// Primary entry: log raw error, return safe copy for SnackBars / dialogs.
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
    if (code == 'permission-denied' || isPermissionDeniedError(error)) {
      if (!mapPermissionDeniedAsConnectivity) {
        return kFriendlyGenericFailureMessage;
      }
      return 'Unable to connect to NexRide services right now.';
    }
    return kFriendlyNetworkFailureMessage;
  }
  if (isPermissionDeniedError(error)) {
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

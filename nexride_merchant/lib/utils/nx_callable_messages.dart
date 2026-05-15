import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// True when [s] looks like a platform / stack trace string we must not show in production UI.
bool nxLooksLikeTechnicalFailureMessage(String s) {
  final t = s.trim().toLowerCase();
  if (t.isEmpty) return true;
  if (t.contains('firebase_functions')) return true;
  if (t.contains('firebaseexception')) return true;
  if (t.contains('internal error')) return true;
  if (t.contains('assertion failed')) return true;
  if (t.contains('stack trace')) return true;
  if (t.contains('dart:') && t.contains('#0')) return true;
  return false;
}

/// User-facing copy for production. Detailed errors stay in [debugPrint] only.
String nxUserFacingMessage(Object error) {
  if (error is FirebaseFunctionsException) {
    final code = error.code.toLowerCase();
    if (kDebugMode) {
      debugPrint('FirebaseFunctionsException code=$code message=${error.message}');
    }
    switch (code) {
      case 'not-found':
      case 'unavailable':
      case 'deadline-exceeded':
        return 'This action could not be completed. Please try again in a moment.';
      case 'permission-denied':
      case 'unauthenticated':
        return 'You do not have permission to do that. Please sign in again.';
      case 'resource-exhausted':
        return 'The service is busy. Please wait and try again.';
      default:
        return 'Something went wrong. Please try again.';
    }
  }
  if (error is FirebaseAuthException) {
    if (kDebugMode) {
      debugPrint('FirebaseAuthException code=${error.code} message=${error.message}');
    }
    switch (error.code) {
      case 'email-already-in-use':
        return 'That email is already registered. Try signing in instead.';
      case 'weak-password':
        return 'Please choose a stronger password.';
      case 'invalid-email':
        return 'Enter a valid email address.';
      case 'user-not-found':
      case 'wrong-password':
      case 'invalid-credential':
        return 'Incorrect email or password.';
      default:
        return 'Sign-in could not be completed. Please try again.';
    }
  }
  if (kDebugMode) {
    debugPrint('nxUserFacingMessage: $error');
  }
  if (error is StateError) {
    final m = error.message;
    if (m.isNotEmpty && !nxLooksLikeTechnicalFailureMessage(m)) {
      return m;
    }
  }
  return 'Something went wrong. Please try again.';
}

String nxSupportUnavailableMessage() {
  return 'Support is temporarily unavailable. Please try again.';
}

/// Prefer server [user_message] / [message]; never surface raw stack traces or internal SDK strings.
String nxMapFailureMessage(
  Map<String, dynamic> res, [
  String fallback = 'Something went wrong. Please try again.',
]) {
  for (final String key in <String>['user_message', 'message']) {
    final u = res[key]?.toString().trim();
    if (u != null && u.isNotEmpty && !nxLooksLikeTechnicalFailureMessage(u)) {
      return u;
    }
  }
  final reason = res['reason']?.toString().trim().toLowerCase();
  switch (reason) {
    case 'role_forbidden':
      return 'Your staff role cannot do that. Ask the store owner if you need access.';
    case 'owner_only':
      return 'Only the business owner can do that.';
    case 'user_not_found':
      return 'No NexRide user was found for that email.';
    case 'forbidden':
      return 'You do not have access to that action.';
  }
  return fallback;
}

/// Safe text for banners / onboarding when the source string may contain SDK noise.
String nxPublicMessage(String? raw, [String fallback = 'Please try again or contact NexRide support.']) {
  final t = raw?.trim();
  if (t == null || t.isEmpty || nxLooksLikeTechnicalFailureMessage(t)) {
    return fallback;
  }
  return t;
}

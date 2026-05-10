/// Pure logic for the admin/support password-management flows:
///   - password complexity validation
///   - friendly Firebase error mapping
///   - lightweight in-memory rate limit
///
/// No Firebase imports here on purpose — keeps these helpers easy to unit-test
/// and lets the matching screens stay declarative.
library;

import 'package:firebase_auth/firebase_auth.dart';

const int kMinPortalPasswordLength = 12;
const int kPortalChangePwMaxAttempts = 5;
const Duration kPortalChangePwWindow = Duration(minutes: 15);
const int kPortalResetEmailMaxAttempts = 3;
const Duration kPortalResetEmailWindow = Duration(minutes: 30);

/// Validates that [password] is suitable for an operator account.
///
/// Returns `null` when valid, or a user-facing message describing the
/// first failed rule. Rules:
///   - non-empty
///   - at least [kMinPortalPasswordLength] characters
///   - contains a letter
///   - contains a digit
///   - does not contain the email handle (the part before `@`) when
///     it's at least 4 characters long
String? validatePortalPasswordComplexity(
  String password, {
  String? email,
}) {
  if (password.isEmpty) {
    return 'Password is required.';
  }
  if (password.length < kMinPortalPasswordLength) {
    return 'Password must be at least $kMinPortalPasswordLength characters.';
  }
  if (!RegExp(r'[A-Za-z]').hasMatch(password)) {
    return 'Password must include at least one letter.';
  }
  if (!RegExp(r'\d').hasMatch(password)) {
    return 'Password must include at least one digit.';
  }
  if (email != null) {
    final handle = email.toLowerCase().split('@').first;
    if (handle.length >= 4 &&
        password.toLowerCase().contains(handle)) {
      return 'Password must not contain your email handle.';
    }
  }
  return null;
}

/// Map a [FirebaseAuthException] (or arbitrary error) to a non-leaky,
/// user-facing message suitable for both change-password and re-auth flows.
///
/// Specifically does NOT distinguish "no such email" from "wrong password"
/// for the change-password screen — the input always includes the user's
/// own email, so the only useful signal is "current password incorrect".
String friendlyPortalAuthError(Object error) {
  if (error is FirebaseAuthException) {
    switch (error.code) {
      case 'wrong-password':
      case 'invalid-credential':
      case 'invalid-login-credentials':
        return 'Current password is incorrect.';
      case 'too-many-requests':
        return 'Too many attempts. Wait a few minutes and try again.';
      case 'requires-recent-login':
        return 'Please sign in again, then retry the password change.';
      case 'network-request-failed':
        return 'Network error. Check your connection and try again.';
      case 'weak-password':
        return 'Password is too weak. Choose a longer, more unique password.';
      case 'user-disabled':
        return 'This account has been disabled. Contact a NexRide administrator.';
      case 'user-mismatch':
        return 'The signed-in account changed. Sign out and try again.';
    }
    final raw = error.message?.trim() ?? '';
    if (raw.isNotEmpty) return raw;
  }
  return 'Could not change password. Please try again.';
}

/// In-memory rate limiter used by the change-password and password-reset
/// flows. Persists for the lifetime of the running web app — sufficient as
/// a UX guard. The real defense lives in Firebase Auth (per-IP and per-
/// account throttling) and any future Cloudflare / reCAPTCHA layer.
class PortalRateLimiter {
  PortalRateLimiter._();

  static final Map<String, List<int>> _attempts = <String, List<int>>{};

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  static void _prune(String key, Duration window) {
    final list = _attempts[key];
    if (list == null) return;
    final cutoff = _now() - window.inMilliseconds;
    list.removeWhere((int t) => t < cutoff);
    if (list.isEmpty) {
      _attempts.remove(key);
    }
  }

  static bool isAllowed(
    String key, {
    required int maxAttempts,
    required Duration window,
  }) {
    _prune(key, window);
    return (_attempts[key]?.length ?? 0) < maxAttempts;
  }

  static int attemptsLeft(
    String key, {
    required int maxAttempts,
    required Duration window,
  }) {
    _prune(key, window);
    final used = _attempts[key]?.length ?? 0;
    final remaining = maxAttempts - used;
    return remaining < 0 ? 0 : remaining;
  }

  static void recordAttempt(
    String key, {
    required Duration window,
  }) {
    _prune(key, window);
    final list = _attempts.putIfAbsent(key, () => <int>[]);
    list.add(_now());
  }

  static int secondsUntilReset(
    String key, {
    required Duration window,
  }) {
    _prune(key, window);
    final list = _attempts[key];
    if (list == null || list.isEmpty) return 0;
    final oldest = list.first;
    final resetAt = oldest + window.inMilliseconds;
    final delta = resetAt - _now();
    if (delta <= 0) return 0;
    return (delta / 1000).ceil();
  }

  static void clear(String key) {
    _attempts.remove(key);
  }
}

/// Compact human-readable reset countdown — `42s`, `3 min`.
String formatPortalRateResetCompact(int secondsToReset) {
  if (secondsToReset <= 0) return 'now';
  if (secondsToReset < 60) return '${secondsToReset}s';
  final minutes = (secondsToReset / 60).ceil();
  return '$minutes min';
}

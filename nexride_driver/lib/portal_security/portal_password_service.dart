/// Firebase wiring for the admin/support portal password flows.
///
/// One shared service used by both the admin and support portals. Splits
/// the work into small, testable steps so the change-password screen can
/// stay declarative:
///
///   1. [PortalPasswordService.changePassword]  — reauthenticate, update,
///      then call the [rotateAccountAfterPasswordChange] Cloud Function
///      to clear the temporaryPassword claim and revoke other sessions.
///   2. [PortalPasswordService.sendPasswordReset] — invokes
///      [FirebaseAuth.sendPasswordResetEmail] and intentionally swallows
///      "user not found" so callers always show a generic success
///      message (avoids account enumeration).
///   3. [PortalPasswordService.loadAccountSecurity] — bundles the data
///      that the Account Security screen needs into a single round trip.
///
/// All client-side work is rate-limited via [PortalRateLimiter]; the
/// Cloud Function is the authoritative server-side enforcer.
library;

import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

const String _kRotateCallableName = 'rotateAccountAfterPasswordChange';
const String _kAccountSecurityRtdbRoot = 'account_security';
const String _kCallableRegion = 'us-central1';

/// Read-only view of the data shown on the Account Security screen.
class PortalAccountSecurityInfo {
  const PortalAccountSecurityInfo({
    required this.uid,
    required this.email,
    required this.lastSignInTime,
    required this.creationTime,
    required this.passwordChangedAt,
    required this.temporaryPassword,
    required this.mfaEnabled,
    required this.claims,
  });

  final String uid;
  final String email;
  final DateTime? lastSignInTime;
  final DateTime? creationTime;
  final DateTime? passwordChangedAt;
  final bool temporaryPassword;
  final bool mfaEnabled;
  final Map<String, dynamic> claims;
}

/// Outcome of a successful password rotation. Surfaced to the UI so the
/// change-password screen can decide whether to force-sign-out (always,
/// because the rotate callable revokes refresh tokens).
class PortalPasswordChangeResult {
  const PortalPasswordChangeResult({
    required this.success,
    required this.passwordChangedAt,
    required this.refreshTokensRevoked,
    required this.claimCleared,
  });

  final bool success;
  final DateTime passwordChangedAt;
  final bool refreshTokensRevoked;
  final bool claimCleared;
}

class PortalPasswordService {
  PortalPasswordService({
    FirebaseAuth? auth,
    FirebaseDatabase? database,
    FirebaseFunctions? functions,
  })  : _auth = auth,
        _database = database,
        _functions = functions;

  final FirebaseAuth? _auth;
  final FirebaseDatabase? _database;
  final FirebaseFunctions? _functions;

  FirebaseAuth get _resolvedAuth => _auth ?? FirebaseAuth.instance;
  FirebaseDatabase get _resolvedDatabase =>
      _database ?? FirebaseDatabase.instance;
  FirebaseFunctions get _resolvedFunctions =>
      _functions ?? FirebaseFunctions.instanceFor(region: _kCallableRegion);

  User get _requireUser {
    final user = _resolvedAuth.currentUser;
    if (user == null) {
      throw StateError('No signed-in user. Sign in before changing passwords.');
    }
    return user;
  }

  /// Re-authenticate, update the password, then call the rotate Cloud
  /// Function. Throws on any error — the screen layer is responsible for
  /// catching and surfacing a friendly message via
  /// [friendlyPortalAuthError].
  Future<PortalPasswordChangeResult> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final user = _requireUser;
    final email = user.email?.trim();
    if (email == null || email.isEmpty) {
      throw StateError('Account is missing an email; cannot reauthenticate.');
    }

    final credential = EmailAuthProvider.credential(
      email: email,
      password: currentPassword,
    );
    await user.reauthenticateWithCredential(credential);
    await user.updatePassword(newPassword);

    // Server-side: clear temporaryPassword claim, revoke refresh tokens
    // (signs out other sessions), mirror the cleared flag into RTDB,
    // and write an audit log entry.
    final result = await _callRotateCallable();

    final passwordChangedAtMs = result['password_changed_at'];
    final passwordChangedAt = passwordChangedAtMs is int
        ? DateTime.fromMillisecondsSinceEpoch(passwordChangedAtMs)
        : DateTime.now();

    return PortalPasswordChangeResult(
      success: result['success'] == true,
      passwordChangedAt: passwordChangedAt,
      refreshTokensRevoked: result['refresh_tokens_revoked'] == true,
      claimCleared: result['claim_cleared'] == true,
    );
  }

  Future<Map<String, dynamic>> _callRotateCallable() async {
    try {
      final callable = _resolvedFunctions.httpsCallable(
        _kRotateCallableName,
        options: HttpsCallableOptions(
          timeout: const Duration(seconds: 30),
        ),
      );
      final response = await callable.call(<String, dynamic>{});
      final raw = response.data;
      if (raw is Map) {
        return raw.map<String, dynamic>(
          (Object? key, Object? value) =>
              MapEntry(key?.toString() ?? '', value),
        );
      }
      return <String, dynamic>{'success': false, 'reason': 'invalid_response'};
    } on FirebaseFunctionsException catch (error) {
      debugPrint(
        '[PortalPwSvc] rotate callable failed code=${error.code} message=${error.message}',
      );
      rethrow;
    }
  }

  /// Sends a Firebase password-reset email. Always resolves; on common
  /// errors (user-not-found, invalid-email) we swallow the exception so
  /// the caller can show a generic success message.
  Future<void> sendPasswordReset({required String email}) async {
    final normalized = email.trim();
    if (normalized.isEmpty) {
      // Don't even hit the API if there's nothing to send to. Caller shows
      // the same generic success message either way.
      return;
    }
    try {
      await _resolvedAuth.sendPasswordResetEmail(email: normalized);
    } on FirebaseAuthException catch (error) {
      // We deliberately do NOT propagate user-not-found / invalid-email so
      // we don't leak account existence. Other errors are also swallowed
      // for the same reason — the UI just says "if an account exists, ...".
      debugPrint(
        '[PortalPwSvc] sendPasswordReset suppressed code=${error.code} '
        'message=${error.message}',
      );
    } catch (error) {
      debugPrint('[PortalPwSvc] sendPasswordReset unexpected error: $error');
    }
  }

  /// Returns the structured data shown on the Account Security screen.
  /// Combines Firebase Auth metadata, the ID token's filtered custom
  /// claims, and the RTDB `account_security/{uid}` mirror.
  Future<PortalAccountSecurityInfo> loadAccountSecurity() async {
    final user = _requireUser;
    Map<String, dynamic> claims = const <String, dynamic>{};
    bool tempFlagFromClaim = false;
    try {
      final tokenResult = await user.getIdTokenResult();
      final raw = tokenResult.claims;
      if (raw != null) {
        claims = _filterDisplayClaims(raw);
        tempFlagFromClaim = raw['temporaryPassword'] == true;
      }
    } catch (error) {
      debugPrint('[PortalPwSvc] claims read failed: $error');
    }

    DateTime? passwordChangedAt;
    bool tempFlagFromRtdb = false;
    try {
      final snapshot = await _resolvedDatabase
          .ref('$_kAccountSecurityRtdbRoot/${user.uid}')
          .get();
      final value = snapshot.value;
      if (value is Map) {
        final pwAt = value['passwordChangedAt'];
        if (pwAt is int) {
          passwordChangedAt = DateTime.fromMillisecondsSinceEpoch(pwAt);
        }
        if (value['temporaryPassword'] == true) {
          tempFlagFromRtdb = true;
        }
      }
    } catch (error) {
      debugPrint('[PortalPwSvc] account_security read failed: $error');
    }

    bool mfaEnabled = false;
    try {
      final factors = await user.multiFactor.getEnrolledFactors();
      mfaEnabled = factors.isNotEmpty;
    } catch (error) {
      // multiFactor.getEnrolledFactors throws on some web codepaths when MFA
      // isn't enabled at the project level; treat as "not enrolled".
      mfaEnabled = false;
    }

    return PortalAccountSecurityInfo(
      uid: user.uid,
      email: user.email ?? '',
      lastSignInTime: user.metadata.lastSignInTime,
      creationTime: user.metadata.creationTime,
      passwordChangedAt: passwordChangedAt,
      temporaryPassword: tempFlagFromClaim || tempFlagFromRtdb,
      mfaEnabled: mfaEnabled,
      claims: claims,
    );
  }

  /// Lightweight read of just the `mustChangePassword` flag — used by the
  /// gate screens after sign-in. Combines RTDB doc and ID-token claim;
  /// either source flips the flag on. Returns false on any error so we
  /// don't block sign-in due to RTDB/claims hiccups.
  Future<bool> readMustChangePassword({required User user}) async {
    bool fromClaim = false;
    try {
      final tokenResult = await user.getIdTokenResult();
      fromClaim = tokenResult.claims?['temporaryPassword'] == true;
    } catch (_) {
      fromClaim = false;
    }

    bool fromRtdb = false;
    try {
      final snapshot = await _resolvedDatabase
          .ref('$_kAccountSecurityRtdbRoot/${user.uid}')
          .get();
      final value = snapshot.value;
      if (value is Map && value['temporaryPassword'] == true) {
        fromRtdb = true;
      }
    } catch (_) {
      fromRtdb = false;
    }

    return fromClaim || fromRtdb;
  }
}

const Set<String> _kSafeClaimKeys = <String>{
  'admin',
  'super_admin',
  'support',
  'support_staff',
  'isSupport',
  'role',
  'supportRole',
  'temporaryPassword',
};

Map<String, dynamic> _filterDisplayClaims(Map<Object?, Object?> claims) {
  final result = <String, dynamic>{};
  for (final key in _kSafeClaimKeys) {
    if (claims.containsKey(key)) {
      result[key] = claims[key];
    }
  }
  return result;
}

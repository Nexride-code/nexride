import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

import '../models/admin_models.dart';
import '../../portal_security/portal_password_service.dart';
import '../../support/nexride_contact_constants.dart';
import '../admin_rbac.dart';

class _AdminsGate {
  const _AdminsGate({
    required this.portal,
    this.adminRoleHint,
    this.legacyBooleanTrue = false,
  });

  final bool portal;
  final String? adminRoleHint;
  final bool legacyBooleanTrue;
}

class AdminAuthService {
  AdminAuthService({
    FirebaseAuth? auth,
    FirebaseDatabase? database,
  })  : _auth = auth ?? FirebaseAuth.instance,
        _database = database ?? FirebaseDatabase.instance;

  final FirebaseAuth _auth;
  final FirebaseDatabase _database;

  FirebaseAuth get auth => _auth;
  FirebaseDatabase get database => _database;

  bool get hasAuthenticatedUser => auth.currentUser != null;

  String? get authenticatedUid => auth.currentUser?.uid;
  String get authenticatedEmail => auth.currentUser?.email?.trim() ?? '';

  Stream<User?> get authStateChanges => auth.authStateChanges();

  Future<AdminSession?> currentSession() async {
    await _configureWebPersistence();
    final user = await _resolveCurrentUser();
    debugPrint(
      '[AdminAuth] currentSession user=${user?.uid ?? 'none'} email=${user?.email ?? 'none'}',
    );
    if (user == null) {
      return null;
    }
    return _sessionWithRefreshRetry(user, context: 'currentSession');
  }

  Future<AdminSession> signIn({
    required String email,
    required String password,
  }) async {
    final normalizedEmail = email.trim();
    final normalizedPassword = password.trim();
    if (normalizedEmail.isEmpty || normalizedPassword.isEmpty) {
      throw StateError('Enter both your admin email and password.');
    }

    await _configureWebPersistence();

    try {
      final credential = await auth.signInWithEmailAndPassword(
        email: normalizedEmail,
        password: normalizedPassword,
      );
      final user = credential.user;
      if (user == null) {
        throw StateError('Signed in but no Firebase user was returned.');
      }
      // Force fresh claims immediately after login.
      await user.getIdToken(true);

      final session = await _sessionWithRefreshRetry(user, context: 'signIn');
      if (session == null) {
        debugPrint(
          '[AdminAuth] signIn denied uid=${user.uid} email=${user.email ?? 'none'}',
        );
        // Don't sign out here: [AdminLoginScreen] and protected-route gate
        // decide when to clear the Firebase session after surfacing the error.
        throw StateError(
          'Your account is signed in but does not have access. '
          'Contact the NexRide system administrator ($kNexRideAdminEmail).',
        );
      }
      debugPrint(
        '[AdminAuth] signIn granted uid=${session.uid} mode=${session.accessMode}',
      );
      return session;
    } on FirebaseAuthException catch (error) {
      throw StateError(_friendlyAuthMessage(error));
    }
  }

  /// Mirror of the support service's retry helper: evaluate access with
  /// the cached ID token; if denied, force a token refresh once and try
  /// again before giving up. Closes the "claims just got granted but the
  /// browser still has a stale token" race.
  Future<AdminSession?> _sessionWithRefreshRetry(
    User user, {
    required String context,
  }) async {
    final firstPass = await _sessionForUser(user, attempt: 'cached');
    if (firstPass != null) {
      return firstPass;
    }
    debugPrint(
      'ADMIN_AUTH_DEBUG context=$context attempt=cached uid=${user.uid} '
      'allow=false reasons=DENY:no_matched_path -> forcing token refresh',
    );
    try {
      await user
          .getIdToken(true)
          .timeout(const Duration(seconds: 8));
    } catch (error) {
      debugPrint('[AdminAuth] forced token refresh failed: $error');
      return null;
    }
    return _sessionForUser(user, attempt: 'forced-refresh');
  }

  Future<void> signOut() => auth.signOut();

  Future<void> forceTokenRefresh() async {
    final user = auth.currentUser;
    if (user == null) {
      return;
    }
    await user.getIdToken(true);
  }

  Future<AdminSession?> _sessionForUser(
    User user, {
    String attempt = 'cached',
  }) async {
    final email = user.email?.trim().toLowerCase() ?? '';
    final displayName = (user.displayName?.trim().isNotEmpty ?? false)
        ? user.displayName!.trim()
        : (email.isNotEmpty ? email.split('@').first : 'Admin');

    // Parallelize: worst-case wall time is max(claims, RTDB), not sum — keeps
    // AdminGate under its outer timeout in normal network conditions.
    final results = await Future.wait<Object>(<Future<Object>>[
      _readClaims(user),
      _readAdminsGate(user.uid),
    ]);
    final claims = results[0] as Map<String, dynamic>;
    final adminsGate = results[1] as _AdminsGate;

    final claimAdmin = claims['admin'] == true;
    final claimRoleAdmin = claims['role'] == 'admin';
    final rtdbPortal = adminsGate.portal;
    final finalAllowed = claimAdmin || claimRoleAdmin || rtdbPortal;

    final reasons = <String>[];
    if (claimAdmin) reasons.add('claim:admin=true');
    if (claimRoleAdmin) reasons.add('claim:role=admin');
    if (rtdbPortal) reasons.add('rtdb:admins_gate');
    if (!finalAllowed) reasons.add('DENY:no_matched_path[attempt=$attempt]');

    debugPrint(
      'ADMIN_AUTH_DEBUG attempt=$attempt uid=${user.uid} email=$email '
      'allow=$finalAllowed reasons=${reasons.join('|')} '
      'claims=$claims rtdbAdmin=$rtdbPortal',
    );
    if (!finalAllowed) {
      return null;
    }

    final accessMode =
        claimAdmin || claimRoleAdmin ? 'custom_claim_admin' : 'admins_node';

    String roleFromClaims =
        '${claims['admin_role'] ?? ''}'.trim().toLowerCase();
    if (!kNexrideAdminRoles.contains(roleFromClaims)) {
      roleFromClaims = '';
    }
    String roleFromRtdb = adminsGate.adminRoleHint ?? '';
    if (!kNexrideAdminRoles.contains(roleFromRtdb)) {
      roleFromRtdb = '';
    }
    String resolvedRole = roleFromClaims.isNotEmpty
        ? roleFromClaims
        : (roleFromRtdb.isNotEmpty
            ? roleFromRtdb
            : ((claimAdmin || claimRoleAdmin || adminsGate.legacyBooleanTrue)
                ? 'super_admin'
                : 'ops_admin'));

    if (!kNexrideAdminRoles.contains(resolvedRole)) {
      resolvedRole = 'ops_admin';
    }

    final Set<String> perms = permissionsForAdminRole(resolvedRole);
    debugPrint('[AdminAuth] admin access granted via $accessMode');

    // Probe whether the operator is on a temporary password — drives the
    // forced-redirect flow in AdminGateScreen.
    bool mustChangePassword = false;
    try {
      final svc = PortalPasswordService(auth: auth, database: database);
      mustChangePassword = await svc.readMustChangePassword(user: user);
    } catch (error) {
      debugPrint('[AdminAuth] mustChangePassword probe failed: $error');
    }

    return AdminSession(
      uid: user.uid,
      email: email,
      displayName: displayName,
      accessMode: accessMode,
      mustChangePassword: mustChangePassword,
      adminRole: resolvedRole,
      permissions: perms,
    );
  }

  Future<Map<String, dynamic>> _readClaims(User user) async {
    try {
      final idToken = await user
          .getIdTokenResult()
          .timeout(const Duration(seconds: 5));
      final claims = idToken.claims;
      if (claims == null) {
        return const <String, dynamic>{};
      }
      return claims.map<String, dynamic>(
        (String key, dynamic value) => MapEntry(key, value),
      );
    } catch (error) {
      debugPrint('[AdminAuth] custom claim lookup failed uid=${user.uid} error=$error');
      return const <String, dynamic>{};
    }
  }

  Future<User?> _resolveCurrentUser() async {
    final existingUser = auth.currentUser;
    if (existingUser != null) {
      return existingUser;
    }
    try {
      return await auth
          .authStateChanges()
          .first
          .timeout(const Duration(seconds: 3));
    } on TimeoutException {
      return auth.currentUser;
    }
  }

  Future<void> _configureWebPersistence() async {
    if (!kIsWeb) {
      return;
    }
    try {
      await auth
          .setPersistence(Persistence.LOCAL)
          .timeout(const Duration(seconds: 5));
    } on TimeoutException {
      debugPrint('[AdminAuth] setPersistence timed out — continuing');
    } catch (error) {
      debugPrint('[AdminAuth] unable to set web auth persistence: $error');
    }
  }

  Future<_AdminsGate> _readAdminsGate(String uid) async {
    try {
      final snapshot = await database
          .ref('admins/$uid')
          .get()
          .timeout(const Duration(seconds: 5));
      final Object? v = snapshot.value;
      if (v == true) {
        return const _AdminsGate(portal: true, legacyBooleanTrue: true);
      }
      if (v is Map) {
        final Map<Object?, Object?> m = v;
        final bool disabled =
            m['disabled'] == true || m['enabled'] == false;
        if (disabled) {
          return const _AdminsGate(portal: false);
        }
        final String ar =
            '${m['admin_role'] ?? m['role'] ?? ''}'.trim().toLowerCase();
        if (kNexrideAdminRoles.contains(ar)) {
          return _AdminsGate(portal: true, adminRoleHint: ar);
        }
        if (m['admin'] == true || m['enabled'] == true) {
          return const _AdminsGate(portal: true);
        }
        return const _AdminsGate(portal: false);
      }
      return const _AdminsGate(portal: false);
    } on TimeoutException {
      debugPrint(
        '[AdminAuth] admins lookup timed out uid=$uid — treating as no RTDB admin flag',
      );
      return const _AdminsGate(portal: false);
    } catch (error, stackTrace) {
      debugPrint('[AdminAuth] admins lookup failed uid=$uid error=$error');
      debugPrintStack(
        label: '[AdminAuth] admins lookup stack',
        stackTrace: stackTrace,
      );
      return const _AdminsGate(portal: false);
    }
  }

  String _friendlyAuthMessage(FirebaseAuthException error) {
    switch (error.code) {
      case 'invalid-email':
        return 'Enter a valid email address.';
      case 'invalid-credential':
      case 'user-not-found':
      case 'wrong-password':
        return 'Incorrect email or password.';
      case 'user-disabled':
        return 'This Firebase account has been disabled.';
      case 'operation-not-allowed':
        return 'Email/password sign-in is not enabled for this Firebase project.';
      case 'network-request-failed':
        return 'Network error. Check your connection and try again.';
      case 'too-many-requests':
        return 'Too many sign-in attempts. Wait a moment and try again.';
      default:
        return error.message?.trim().isNotEmpty == true
            ? error.message!.trim()
            : 'Unable to sign in right now.';
    }
  }
}

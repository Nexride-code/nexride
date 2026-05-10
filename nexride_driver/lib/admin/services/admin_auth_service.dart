import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

import '../models/admin_models.dart';
import '../../portal_security/portal_password_service.dart';
import '../../support/nexride_contact_constants.dart';

class AdminAuthService {
  AdminAuthService({
    FirebaseAuth? auth,
    FirebaseDatabase? database,
  })  : _auth = auth,
        _database = database;

  final FirebaseAuth? _auth;
  final FirebaseDatabase? _database;

  FirebaseAuth get auth => _auth ?? FirebaseAuth.instance;
  FirebaseDatabase get database => _database ?? FirebaseDatabase.instance;
  bool get hasAuthenticatedUser => auth.currentUser != null;
  String get authenticatedUid => auth.currentUser?.uid ?? '';
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
        // Important: don't sign out here. The gate's
        // `_scheduleUnauthorizedReset` is the one place that signs the
        // unauthorized user out — keeping that single chokepoint makes
        // the deny logs reproducible.
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
      await user.getIdToken(true);
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

    final claims = await _readClaims(user);
    final claimAdmin = claims['admin'] == true;
    final claimRoleAdmin = claims['role'] == 'admin';
    final hasDatabaseAccess = await _hasDatabaseAdminAccess(user.uid);
    final finalAllowed = claimAdmin || claimRoleAdmin || hasDatabaseAccess;

    final reasons = <String>[];
    if (claimAdmin) reasons.add('claim:admin=true');
    if (claimRoleAdmin) reasons.add('claim:role=admin');
    if (hasDatabaseAccess) reasons.add('rtdb:/admins/{uid}=true');
    if (!finalAllowed) reasons.add('DENY:no_matched_path[attempt=$attempt]');

    debugPrint(
      'ADMIN_AUTH_DEBUG attempt=$attempt uid=${user.uid} email=$email '
      'allow=$finalAllowed reasons=${reasons.join('|')} '
      'claims=$claims rtdbAdmin=$hasDatabaseAccess',
    );
    if (!finalAllowed) {
      return null;
    }

    final accessMode =
        claimAdmin || claimRoleAdmin ? 'custom_claim_admin' : 'admins_node';
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
    );
  }

  Future<Map<String, dynamic>> _readClaims(User user) async {
    try {
      final idToken = await user.getIdTokenResult();
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
      await auth.setPersistence(Persistence.LOCAL);
    } catch (error) {
      debugPrint('[AdminAuth] unable to set web auth persistence: $error');
    }
  }

  Future<bool> _hasDatabaseAdminAccess(String uid) async {
    try {
      final snapshot = await database.ref('admins/$uid').get();
      return snapshot.value == true;
    } catch (error, stackTrace) {
      debugPrint('[AdminAuth] admins lookup failed uid=$uid error=$error');
      debugPrintStack(
        label: '[AdminAuth] admins lookup stack',
        stackTrace: stackTrace,
      );
      if (_isPermissionDenied(error)) {
        return false;
      }
      rethrow;
    }
  }

  bool _isPermissionDenied(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('permission-denied') ||
        message.contains('permission denied');
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

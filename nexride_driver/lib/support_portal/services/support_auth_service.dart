import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

import '../models/support_models.dart';

class SupportAuthService {
  SupportAuthService({
    FirebaseAuth? auth,
    FirebaseDatabase? database,
  })  : _auth = auth,
        _database = database;

  final FirebaseAuth? _auth;
  final FirebaseDatabase? _database;

  FirebaseAuth get auth => _auth ?? FirebaseAuth.instance;
  FirebaseDatabase get database => _database ?? FirebaseDatabase.instance;
  DatabaseReference get _rootRef => database.ref();
  bool get hasAuthenticatedUser => auth.currentUser != null;
  String get authenticatedUid => auth.currentUser?.uid ?? '';
  String get authenticatedEmail => auth.currentUser?.email?.trim() ?? '';

  Stream<User?> get authStateChanges => auth.authStateChanges();

  Future<SupportSession?> currentSession() async {
    await _configureWebPersistence();
    final user = await _resolveCurrentUser();
    debugPrint(
      '[SupportAuth] currentSession user=${user?.uid ?? 'none'} email=${user?.email ?? 'none'}',
    );
    if (user == null) {
      return null;
    }
    return _sessionForUser(user);
  }

  Future<SupportSession> signIn({
    required String email,
    required String password,
  }) async {
    final normalizedEmail = email.trim();
    final normalizedPassword = password.trim();
    if (normalizedEmail.isEmpty || normalizedPassword.isEmpty) {
      throw StateError('Enter both your support email and password.');
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

      final session = await _sessionForUser(user);
      if (session == null) {
        await auth.signOut();
        throw StateError(
          'Your account is signed in but does not have access. '
          'Contact the NexRide system administrator.',
        );
      }
      debugPrint(
        '[SupportAuth] signIn granted uid=${session.uid} role=${session.role} access=${session.accessMode}',
      );
      return session;
    } on FirebaseAuthException catch (error) {
      throw StateError(_friendlyAuthMessage(error));
    }
  }

  Future<void> signOut() => auth.signOut();

  Future<void> forceTokenRefresh() async {
    final user = auth.currentUser;
    if (user == null) {
      return;
    }
    await user.getIdToken(true);
  }

  Future<SupportSession?> _sessionForUser(User user) async {
    final email = user.email?.trim().toLowerCase() ?? '';
    final defaultDisplayName = (user.displayName?.trim().isNotEmpty ?? false)
        ? user.displayName!.trim()
        : (email.isNotEmpty ? email.split('@').first : 'Support');

    final supportRecord = await _loadSupportStaffRecord(user.uid);
    final supportRole = _roleFromSupportRecord(supportRecord);

    final claims = await _readClaims(user);
    final claimRole = normalizeSupportRole(
      _firstText(<dynamic>[claims['role']]),
    );
    final claimSupport = claims['support'] == true;
    final claimSupportStaff = claims['support_staff'] == true;
    final claimAdmin = claims['admin'] == true;
    final claimRoleAllowed =
        claimRole == 'support_agent' || claimRole == 'support_manager';
    final claimAllowed = claimSupport || claimSupportStaff || claimRoleAllowed;
    final rtdbAdmin = await _loadAdminRoleFromDatabase(user.uid);
    final hasAdminOverride = claimAdmin || rtdbAdmin.isNotEmpty;
    final hasRtdbSupport = supportRole.isNotEmpty;
    final finalAllowed = hasAdminOverride || claimAllowed || hasRtdbSupport;
    debugPrint(
      'SUPPORT_AUTH_DEBUG uid=${user.uid} email=$email '
      'claims=$claims supportRecord=$supportRecord '
      'rtdbAdmin=${rtdbAdmin.isNotEmpty} finalAllowed=$finalAllowed',
    );

    if (hasAdminOverride) {
      return SupportSession.adminOverride(
        uid: user.uid,
        email: email,
        displayName: defaultDisplayName,
        role: 'admin',
        accessMode: claimAdmin ? 'custom_claim_admin' : 'admins_node',
      );
    }
    if (claimAllowed) {
      final resolvedRole = claimRoleAllowed ? claimRole : 'support_agent';
      return SupportSession(
        uid: user.uid,
        email: email,
        displayName: defaultDisplayName,
        role: resolvedRole,
        accessMode: 'custom_claim_support',
        permissions: SupportPermissions.forRole(resolvedRole),
      );
    }

    if (supportRole.isNotEmpty) {
      return SupportSession(
        uid: user.uid,
        email: email,
        displayName: _recordDisplayName(
          supportRecord,
          fallback: defaultDisplayName,
        ),
        role: supportRole,
        accessMode: 'support_staff_role',
        permissions: SupportPermissions.forRole(supportRole),
      );
    }

    debugPrint(
      '[SupportAuth] no support access for uid=${user.uid} email=$email',
    );
    return null;
  }

  Future<Map<String, dynamic>> _readClaims(User user) async {
    try {
      final token = await user.getIdTokenResult();
      final claims = token.claims;
      if (claims == null) {
        return const <String, dynamic>{};
      }
      return claims.map<String, dynamic>(
        (String key, dynamic value) => MapEntry(key, value),
      );
    } catch (error) {
      debugPrint('[SupportAuth] claim lookup failed uid=${user.uid} error=$error');
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
      debugPrint('[SupportAuth] unable to set web auth persistence: $error');
    }
  }

  Future<Map<String, dynamic>> _loadSupportStaffRecord(String uid) async {
    try {
      final snapshot = await _rootRef.child('support_staff/$uid').get();
      return _map(snapshot.value);
    } catch (error) {
      debugPrint(
        '[SupportAuth] support_staff lookup failed uid=$uid error=$error',
      );
      if (_isPermissionDenied(error)) {
        return const <String, dynamic>{};
      }
      rethrow;
    }
  }

  Future<String> _loadAdminRoleFromDatabase(String uid) async {
    try {
      final snapshot = await _rootRef.child('admins/$uid').get();
      if (snapshot.value == true) {
        return 'admin';
      }
      return '';
    } catch (error) {
      debugPrint('[SupportAuth] admins lookup failed uid=$uid error=$error');
      if (_isPermissionDenied(error)) {
        return '';
      }
      rethrow;
    }
  }

  String _roleFromSupportRecord(Map<String, dynamic> record) {
    if (record.isEmpty ||
        record['enabled'] == false ||
        record['disabled'] == true) {
      return '';
    }
    final role = normalizeSupportRole(
      _firstText(<dynamic>[record['role'], record['supportRole']]),
    );
    if (role == 'support_manager' || role == 'support_agent') {
      return role;
    }
    return '';
  }

  String _recordDisplayName(
    Map<String, dynamic> record, {
    required String fallback,
  }) {
    return _firstText(
      <dynamic>[record['displayName'], record['name'], record['email']],
      fallback: fallback,
    );
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

  Map<String, dynamic> _map(dynamic value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return value.map<String, dynamic>(
        (dynamic key, dynamic entry) => MapEntry(key.toString(), entry),
      );
    }
    return <String, dynamic>{};
  }

  String _firstText(Iterable<dynamic> values, {String fallback = ''}) {
    for (final value in values) {
      final text = value?.toString().trim() ?? '';
      if (text.isNotEmpty) {
        return text;
      }
    }
    return fallback;
  }
}

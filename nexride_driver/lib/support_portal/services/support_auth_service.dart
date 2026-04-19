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

      final session = await _sessionForUser(user);
      if (session == null) {
        await auth.signOut();
        throw StateError(
          'This account signed in to Firebase, but it does not have NexRide Support access yet. '
          'Grant a `support_agent` or `support_manager` role in `/support_staff/${user.uid}`, '
          'or add `/admins/${user.uid}` = true for admin access.',
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

  Future<SupportSession?> _sessionForUser(User user) async {
    final email = user.email?.trim().toLowerCase() ?? '';
    final defaultDisplayName = (user.displayName?.trim().isNotEmpty ?? false)
        ? user.displayName!.trim()
        : (email.isNotEmpty ? email.split('@').first : 'Support');

    final supportRecord = await _loadSupportStaffRecord(user.uid);
    final supportRole = _roleFromSupportRecord(supportRecord);
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

    final adminRole = await _loadAdminRoleFromDatabase(user.uid);
    if (adminRole.isNotEmpty) {
      return SupportSession.adminOverride(
        uid: user.uid,
        email: email,
        displayName: defaultDisplayName,
        role: adminRole,
        accessMode: 'admins_node',
      );
    }

    debugPrint(
      '[SupportAuth] no support access for uid=${user.uid} email=$email',
    );
    return null;
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

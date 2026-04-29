import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

import '../models/admin_models.dart';

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
    return _sessionForUser(user);
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

      final session = await _sessionForUser(user);
      if (session == null) {
        debugPrint(
          '[AdminAuth] signIn denied uid=${user.uid} email=${user.email ?? 'none'}',
        );
        await auth.signOut();
        throw StateError(
          'This account signed in to Firebase, but it does not have NexRide admin access yet. '
          'Add `/admins/${user.uid}` = true in Realtime Database.',
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

  Future<void> signOut() => auth.signOut();

  Future<AdminSession?> _sessionForUser(User user) async {
    final email = user.email?.trim().toLowerCase() ?? '';
    final displayName = (user.displayName?.trim().isNotEmpty ?? false)
        ? user.displayName!.trim()
        : (email.isNotEmpty ? email.split('@').first : 'Admin');

    final hasDatabaseAccess = await _hasDatabaseAdminAccess(user.uid);
    if (!hasDatabaseAccess) {
      debugPrint(
        '[AdminAuth] no admin access path matched for uid=${user.uid} email=$email',
      );
      return null;
    }

    const accessMode = 'admins_node';
    debugPrint('[AdminAuth] admin access granted via $accessMode');
    return AdminSession(
      uid: user.uid,
      email: email,
      displayName: displayName,
      accessMode: accessMode,
    );
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

import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

import '../../portal_security/portal_password_service.dart';
import '../models/support_models.dart';

/// Resolved authorization decision for a signed-in support user.
///
/// `allow` is true when at least one of the accepted access paths matched
/// (custom claim, RTDB `/admins`, RTDB `/support_staff`). The reason
/// strings are emitted by the auth-debug log and are also useful for
/// post-mortem from the browser console.
@visibleForTesting
class SupportAuthDecision {
  const SupportAuthDecision({
    required this.allow,
    required this.session,
    required this.reasons,
    required this.claims,
    required this.supportRecord,
    required this.rtdbAdmin,
  });

  final bool allow;
  final SupportSession? session;
  final List<String> reasons;
  final Map<String, dynamic> claims;
  final Map<String, dynamic> supportRecord;
  final bool rtdbAdmin;
}

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
    return _resolveSessionWithRefreshRetry(user, context: 'currentSession');
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
      // Force fresh claims immediately after login so newly granted
      // support claims are picked up without an extra page reload.
      await user.getIdToken(true);

      final session = await _resolveSessionWithRefreshRetry(
        user,
        context: 'signIn',
      );
      if (session == null) {
        // Important: do NOT call signOut here. The gate screen's
        // `_scheduleUnauthorizedReset` is the single place that signs the
        // unauthorized user out so the failure log line is emitted before
        // the auth state flips, making the deny reason debuggable.
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

  /// First evaluates the user's session against the cached ID token. If
  /// the cached token denies access (e.g. claims haven't propagated yet
  /// after provisioning), force-refreshes the token once and re-evaluates
  /// before giving up. This is the surgical fix for the "signed in but no
  /// access" race that bit support@ on first login.
  Future<SupportSession?> _resolveSessionWithRefreshRetry(
    User user, {
    required String context,
  }) async {
    final firstPass = await _evaluateAccess(user, attempt: 'cached');
    _logDecision(user, context: context, attempt: 'cached', decision: firstPass);
    if (firstPass.allow) {
      return _withMustChangePassword(firstPass.session!, user);
    }

    // Retry once with a forced token refresh. Cheap (one network round
    // trip) and only happens on the unhappy path.
    try {
      await user
          .getIdToken(true)
          .timeout(const Duration(seconds: 15));
    } catch (error) {
      debugPrint('[SupportAuth] forced token refresh failed: $error');
      return null;
    }
    final secondPass = await _evaluateAccess(user, attempt: 'forced-refresh');
    _logDecision(
      user,
      context: context,
      attempt: 'forced-refresh',
      decision: secondPass,
    );
    if (secondPass.allow) {
      return _withMustChangePassword(secondPass.session!, user);
    }
    return null;
  }

  Future<SupportSession> _withMustChangePassword(
    SupportSession session,
    User user,
  ) async {
    bool mustChangePassword = false;
    try {
      final svc = PortalPasswordService(auth: auth, database: database);
      mustChangePassword = await svc.readMustChangePassword(user: user);
    } catch (error) {
      debugPrint('[SupportAuth] mustChangePassword probe failed: $error');
    }
    return session.copyWith(mustChangePassword: mustChangePassword);
  }

  /// Pure decision function. Reads claims + RTDB `/support_staff` +
  /// RTDB `/admins`, then returns a structured allow/deny outcome. Does
  /// NOT mutate any state and does NOT change the auth session.
  ///
  /// `attempt` is purely for log differentiation between the cached-token
  /// pass and the forced-refresh retry.
  Future<SupportAuthDecision> _evaluateAccess(
    User user, {
    required String attempt,
  }) async {
    final email = user.email?.trim().toLowerCase() ?? '';
    final defaultDisplayName = (user.displayName?.trim().isNotEmpty ?? false)
        ? user.displayName!.trim()
        : (email.isNotEmpty ? email.split('@').first : 'Support');

    final claims = await _readClaims(user);
    final supportRecord = await _loadSupportStaffRecord(user.uid);
    final rtdbAdmin = await _loadAdminFlag(user.uid);
    final supportRole = _roleFromSupportRecord(supportRecord);

    final claimRole = normalizeSupportRole(
      _firstText(<dynamic>[claims['role']]),
    );
    final claimSupport = claims['support'] == true;
    final claimSupportStaff = claims['support_staff'] == true;
    final claimAdmin = claims['admin'] == true;
    final claimRoleAllowed =
        claimRole == 'support_agent' || claimRole == 'support_manager';
    final claimAllowed = claimSupport || claimSupportStaff || claimRoleAllowed;
    final hasAdminOverride = claimAdmin || rtdbAdmin;
    final hasRtdbSupport = supportRole.isNotEmpty;

    final reasons = <String>[];
    if (claimAdmin) reasons.add('claim:admin=true');
    if (rtdbAdmin) reasons.add('rtdb:/admins/{uid}=true');
    if (claimSupport) reasons.add('claim:support=true');
    if (claimSupportStaff) reasons.add('claim:support_staff=true');
    if (claimRoleAllowed) reasons.add('claim:role=$claimRole');
    if (hasRtdbSupport) reasons.add('rtdb:/support_staff/{uid}.role=$supportRole');

    SupportSession? session;
    if (hasAdminOverride) {
      session = SupportSession.adminOverride(
        uid: user.uid,
        email: email,
        displayName: defaultDisplayName,
        role: 'admin',
        accessMode: claimAdmin ? 'custom_claim_admin' : 'admins_node',
      );
    } else if (claimAllowed) {
      final resolvedRole = claimRoleAllowed ? claimRole : 'support_agent';
      session = SupportSession(
        uid: user.uid,
        email: email,
        displayName: defaultDisplayName,
        role: resolvedRole,
        accessMode: 'custom_claim_support',
        permissions: SupportPermissions.forRole(resolvedRole),
      );
    } else if (hasRtdbSupport) {
      session = SupportSession(
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

    final allow = session != null;
    if (!allow) {
      reasons.add('DENY:no_matched_path[attempt=$attempt]');
    }
    return SupportAuthDecision(
      allow: allow,
      session: session,
      reasons: reasons,
      claims: claims,
      supportRecord: supportRecord,
      rtdbAdmin: rtdbAdmin,
    );
  }

  void _logDecision(
    User user, {
    required String context,
    required String attempt,
    required SupportAuthDecision decision,
  }) {
    debugPrint(
      'SUPPORT_AUTH_DEBUG context=$context attempt=$attempt '
      'uid=${user.uid} email=${user.email ?? 'none'} '
      'allow=${decision.allow} '
      'reasons=${decision.reasons.join('|')} '
      'claims=${decision.claims} '
      'rtdbAdmin=${decision.rtdbAdmin} '
      'supportRecordKeys=${decision.supportRecord.keys.toList()}',
    );
  }

  Future<Map<String, dynamic>> _readClaims(User user) async {
    try {
      final token = await user
          .getIdTokenResult()
          .timeout(const Duration(seconds: 8));
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
      await auth
          .setPersistence(Persistence.LOCAL)
          .timeout(const Duration(seconds: 5));
    } on TimeoutException {
      debugPrint('[SupportAuth] setPersistence timed out — continuing');
    } catch (error) {
      debugPrint('[SupportAuth] unable to set web auth persistence: $error');
    }
  }

  Future<Map<String, dynamic>> _loadSupportStaffRecord(String uid) async {
    try {
      final snapshot = await _rootRef
          .child('support_staff/$uid')
          .get()
          .timeout(const Duration(seconds: 10));
      return _map(snapshot.value);
    } on TimeoutException {
      debugPrint(
        '[SupportAuth] support_staff lookup timed out uid=$uid — treating as empty',
      );
      return const <String, dynamic>{};
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

  Future<bool> _loadAdminFlag(String uid) async {
    try {
      final snapshot = await _rootRef
          .child('admins/$uid')
          .get()
          .timeout(const Duration(seconds: 10));
      return snapshot.value == true;
    } on TimeoutException {
      debugPrint(
        '[SupportAuth] admins lookup timed out uid=$uid — treating as no admin flag',
      );
      return false;
    } catch (error) {
      debugPrint('[SupportAuth] admins lookup failed uid=$uid error=$error');
      if (_isPermissionDenied(error)) {
        return false;
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

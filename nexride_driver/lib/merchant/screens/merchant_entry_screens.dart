import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../admin/admin_config.dart';
import '../merchant_portal_functions.dart';
import '../merchant_portal_routes.dart';
import '../merchant_portal_utils.dart';
import 'merchant_dashboard_screen.dart';
import 'merchant_no_application_screen.dart';

/// `/merchant` landing — never auto-opens application or merchant session.
class MerchantLandingScreen extends StatefulWidget {
  const MerchantLandingScreen({super.key});

  @override
  State<MerchantLandingScreen> createState() => _MerchantLandingScreenState();
}

class _MerchantLandingScreenState extends State<MerchantLandingScreen> {
  bool? _adminLike;

  @override
  void initState() {
    super.initState();
    _refreshAdminHint();
  }

  Future<void> _refreshAdminHint() async {
    final u = FirebaseAuth.instance.currentUser;
    if (u == null) {
      if (mounted) setState(() => _adminLike = false);
      return;
    }
    final email = u.email?.toLowerCase().trim() ?? '';
    if (email == 'admin@nexride.africa') {
      if (mounted) setState(() => _adminLike = true);
      return;
    }
    try {
      final r = await u.getIdTokenResult(true);
      final admin = r.claims?['admin'] == true;
      if (mounted) setState(() => _adminLike = admin);
    } catch (_) {
      if (mounted) setState(() => _adminLike = false);
    }
  }

  void _openSessionGate() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const MerchantSessionGateScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            backgroundColor: AdminThemeTokens.canvas,
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final user = snap.data;
        if (user == null) {
          return _SignedOutLanding(
            onLogin: () {
              Navigator.of(context).pushNamed(MerchantPortalRoutes.login);
            },
            onSignup: () {
              Navigator.of(context).pushNamed(MerchantPortalRoutes.signup);
            },
          );
        }

        final email = user.email ?? user.uid;
        final adminLike = _adminLike;

        if (adminLike == null) {
          return const Scaffold(
            backgroundColor: AdminThemeTokens.canvas,
            body: Center(child: CircularProgressIndicator()),
          );
        }

        if (adminLike) {
          return _AdminChoiceLanding(
            email: email,
            onContinueMerchant: _openSessionGate,
            onLogout: () => FirebaseAuth.instance.signOut(),
            onSignupAnother: () async {
              await FirebaseAuth.instance.signOut();
              if (context.mounted) {
                Navigator.of(context).pushNamed(MerchantPortalRoutes.signup);
              }
            },
          );
        }

        return _SignedInMerchantLanding(
          email: email,
          onContinue: _openSessionGate,
          onLogout: () => FirebaseAuth.instance.signOut(),
          onSignupAnother: () async {
            await FirebaseAuth.instance.signOut();
            if (context.mounted) {
              Navigator.of(context).pushNamed(MerchantPortalRoutes.signup);
            }
          },
        );
      },
    );
  }
}

class _SignedOutLanding extends StatelessWidget {
  const _SignedOutLanding({
    required this.onLogin,
    required this.onSignup,
  });

  final VoidCallback onLogin;
  final VoidCallback onSignup;

  static const String _footer = 'Merchant portal v2';

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      backgroundColor: AdminThemeTokens.canvas,
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 440),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: AdminThemeTokens.surface,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: AdminThemeTokens.border),
                        boxShadow: <BoxShadow>[
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.06),
                            blurRadius: 24,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(28, 32, 28, 28),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            Text(
                              'NexRide Merchant',
                              textAlign: TextAlign.center,
                              style: t.textTheme.headlineSmall?.copyWith(
                                    fontWeight: FontWeight.w800,
                                    color: AdminThemeTokens.ink,
                                  ),
                            ),
                            const SizedBox(height: 14),
                            Text(
                              'Sell food, groceries, pharmacy items, and essentials '
                              'to nearby NexRide customers.',
                              textAlign: TextAlign.center,
                              style: t.textTheme.bodyLarge?.copyWith(
                                    color: const Color(0xFF3D3A35),
                                    height: 1.45,
                                  ),
                            ),
                            const SizedBox(height: 28),
                            FilledButton(
                              onPressed: onLogin,
                              child: const Text('Log in'),
                            ),
                            const SizedBox(height: 12),
                            OutlinedButton(
                              onPressed: onSignup,
                              child: const Text('Create merchant account'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 10, top: 4),
              child: Text(
                _footer,
                textAlign: TextAlign.center,
                style: t.textTheme.labelSmall?.copyWith(
                      color: AdminThemeTokens.slate.withValues(alpha: 0.45),
                      fontSize: 10,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SignedInMerchantLanding extends StatelessWidget {
  const _SignedInMerchantLanding({
    required this.email,
    required this.onContinue,
    required this.onLogout,
    required this.onSignupAnother,
  });

  final String email;
  final VoidCallback onContinue;
  final VoidCallback onLogout;
  final Future<void> Function() onSignupAnother;

  static const String _footer = 'Merchant portal v2';

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      backgroundColor: AdminThemeTokens.canvas,
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 440),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: AdminThemeTokens.surface,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: AdminThemeTokens.border),
                        boxShadow: <BoxShadow>[
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.06),
                            blurRadius: 24,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(28, 32, 28, 28),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            Text(
                              'NexRide Merchant',
                              textAlign: TextAlign.center,
                              style: t.textTheme.headlineSmall?.copyWith(
                                    fontWeight: FontWeight.w800,
                                    color: AdminThemeTokens.ink,
                                  ),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'You are signed in',
                              textAlign: TextAlign.center,
                              style: t.textTheme.titleMedium?.copyWith(
                                    color: const Color(0xFF3D3A35),
                                  ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              email,
                              textAlign: TextAlign.center,
                              style: t.textTheme.bodyLarge?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    color: AdminThemeTokens.ink,
                                  ),
                            ),
                            const SizedBox(height: 28),
                            FilledButton(
                              onPressed: onContinue,
                              child: Text('Continue as $email'),
                            ),
                            const SizedBox(height: 12),
                            OutlinedButton(
                              onPressed: onLogout,
                              child: const Text('Log out'),
                            ),
                            const SizedBox(height: 12),
                            TextButton(
                              onPressed: () => onSignupAnother(),
                              child: const Text('Create another merchant account'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 10, top: 4),
              child: Text(
                _footer,
                textAlign: TextAlign.center,
                style: t.textTheme.labelSmall?.copyWith(
                      color: AdminThemeTokens.slate.withValues(alpha: 0.45),
                      fontSize: 10,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AdminChoiceLanding extends StatelessWidget {
  const _AdminChoiceLanding({
    required this.email,
    required this.onContinueMerchant,
    required this.onLogout,
    required this.onSignupAnother,
  });

  final String email;
  final VoidCallback onContinueMerchant;
  final VoidCallback onLogout;
  final Future<void> Function() onSignupAnother;

  static const String _footer = 'Merchant portal v2';

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      backgroundColor: AdminThemeTokens.canvas,
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: AdminThemeTokens.surface,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: AdminThemeTokens.border),
                        boxShadow: <BoxShadow>[
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.06),
                            blurRadius: 24,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(28, 32, 28, 28),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            Icon(
                              Icons.admin_panel_settings_outlined,
                              size: 44,
                              color: AdminThemeTokens.gold,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'NexRide Merchant',
                              textAlign: TextAlign.center,
                              style: t.textTheme.headlineSmall?.copyWith(
                                    fontWeight: FontWeight.w800,
                                    color: AdminThemeTokens.ink,
                                  ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'Admin account detected',
                              textAlign: TextAlign.center,
                              style: t.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w800,
                                    color: AdminThemeTokens.ink,
                                  ),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              'You are signed in as $email. This looks like a NexRide '
                              'administrator account. Choose how to continue.',
                              textAlign: TextAlign.center,
                              style: t.textTheme.bodyMedium?.copyWith(
                                    color: const Color(0xFF3D3A35),
                                    height: 1.45,
                                  ),
                            ),
                            const SizedBox(height: 24),
                            FilledButton(
                              onPressed: onContinueMerchant,
                              child: const Text('Continue to merchant portal'),
                            ),
                            const SizedBox(height: 12),
                            OutlinedButton(
                              onPressed: onLogout,
                              child: const Text('Log out'),
                            ),
                            const SizedBox(height: 12),
                            TextButton(
                              onPressed: () => onSignupAnother(),
                              child: const Text('Create another merchant account'),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'For day-to-day admin work, use the admin portal at /admin.',
                              textAlign: TextAlign.center,
                              style: t.textTheme.bodySmall?.copyWith(
                                    color: AdminThemeTokens.slate.withValues(alpha: 0.75),
                                  ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 10, top: 4),
              child: Text(
                _footer,
                textAlign: TextAlign.center,
                style: t.textTheme.labelSmall?.copyWith(
                      color: AdminThemeTokens.slate.withValues(alpha: 0.45),
                      fontSize: 10,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// After login or "Continue" — loads merchant profile.
class MerchantSessionGateScreen extends StatefulWidget {
  const MerchantSessionGateScreen({super.key});

  @override
  State<MerchantSessionGateScreen> createState() =>
      _MerchantSessionGateScreenState();
}

class _MerchantSessionGateScreenState extends State<MerchantSessionGateScreen> {
  late Future<Map<String, dynamic>> _load;

  @override
  void initState() {
    super.initState();
    _load = _fetchMerchantProfile();
  }

  Future<Map<String, dynamic>> _fetchMerchantProfile() async {
    return MerchantPortalFunctions().merchantGetMyMerchant();
  }

  void _retry() {
    setState(() {
      _load = _fetchMerchantProfile();
    });
  }

  String _callableErrorMessage(Object error) {
    if (error is FirebaseFunctionsException) {
      final details = error.details;
      final extra = details == null ? '' : '\n$details';
      return '${error.code}: ${error.message ?? 'request_failed'}$extra';
    }
    return error.toString();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>>(
      future: _load,
      builder: (context, snap) {
        if (snap.hasError) {
          return Scaffold(
            appBar: AppBar(
              title: const Text('Merchant portal'),
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Text(
                        'Could not load your merchant profile.\n\n'
                        '${_callableErrorMessage(snap.error!)}',
                      ),
                      if (kDebugMode) ...<Widget>[
                        const SizedBox(height: 12),
                        Text(
                          'uid: ${FirebaseAuth.instance.currentUser?.uid ?? 'none'}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: _retry,
                        child: const Text('Retry'),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton(
                        onPressed: () => FirebaseAuth.instance.signOut(),
                        child: const Text('Log out'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }
        if (!snap.hasData) {
          return Scaffold(
            appBar: AppBar(
              title: const Text('Merchant portal'),
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            body: const Center(child: CircularProgressIndicator()),
          );
        }
        final data = snap.data!;
        if (data.isEmpty) {
          return Scaffold(
            appBar: AppBar(
              title: const Text('Merchant portal'),
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    const Text('Empty response from server.'),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _retry,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        if (mpSuccess(data['success'])) {
          final merchant = mpMerchant(data['merchant']);
          if (merchant == null) {
            return Scaffold(
              appBar: AppBar(
                title: const Text('Merchant portal'),
                leading: IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      const Text(
                        'Server returned success but no merchant payload. '
                        'Try again or contact support.',
                      ),
                      if (kDebugMode) ...<Widget>[
                        const SizedBox(height: 12),
                        Text(
                          'keys: ${data.keys.join(', ')}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: _retry,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }
          return MerchantDashboardScreen(initialMerchant: merchant);
        }

        final reason = data['reason']?.toString() ?? '';
        if (reason == 'not_found') {
          return const MerchantNoApplicationScreen();
        }

        String message;
        switch (reason) {
          case 'unauthorized':
            message =
                'You are not signed in correctly. Try logging out and back in.';
            break;
          case 'ambiguous_multiple_merchants':
            message =
                'Multiple merchant records match this account. Please contact NexRide support.';
            break;
          default:
            message =
                'Could not load merchant profile${reason.isEmpty ? '' : ' ($reason)'}';
        }

        return Scaffold(
          appBar: AppBar(
            title: const Text('Merchant portal'),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Text(message, textAlign: TextAlign.center),
                    if (kDebugMode) ...<Widget>[
                      const SizedBox(height: 12),
                      Text(
                        'reason=$reason uid=${FirebaseAuth.instance.currentUser?.uid ?? 'none'}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: _retry,
                      child: const Text('Retry'),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: () => FirebaseAuth.instance.signOut(),
                      child: const Text('Log out'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

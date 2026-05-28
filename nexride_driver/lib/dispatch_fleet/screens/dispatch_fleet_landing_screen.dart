import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../admin/admin_config.dart';
import '../dispatch_fleet_routes.dart';

/// `/fleet` landing — sign up, log in, or support (no commerce).
class DispatchFleetLandingScreen extends StatelessWidget {
  const DispatchFleetLandingScreen({super.key});

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
        if (user != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!context.mounted) {
              return;
            }
            Navigator.of(context).pushReplacementNamed(
              DispatchFleetRoutes.session,
            );
          });
          return const Scaffold(
            backgroundColor: AdminThemeTokens.canvas,
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return _SignedOutLanding(
          onSignup: () {
            Navigator.of(context).pushNamed(DispatchFleetRoutes.signup);
          },
          onLogin: () {
            Navigator.of(context).pushNamed(DispatchFleetRoutes.login);
          },
          onSupport: () {
            Navigator.of(context).pushNamed(DispatchFleetRoutes.support);
          },
        );
      },
    );
  }
}

class _SignedOutLanding extends StatelessWidget {
  const _SignedOutLanding({
    required this.onSignup,
    required this.onLogin,
    required this.onSupport,
  });

  final VoidCallback onSignup;
  final VoidCallback onLogin;
  final VoidCallback onSupport;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      backgroundColor: AdminThemeTokens.canvas,
      body: SafeArea(
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
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(28, 32, 28, 28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Text(
                        'NexRide Dispatch Fleet',
                        textAlign: TextAlign.center,
                        style: t.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                              color: AdminThemeTokens.ink,
                            ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        'Fleet Business portal for managing dispatch bikers. '
                        'Not for restaurant, pharmacy, or grocery commerce.',
                        textAlign: TextAlign.center,
                        style: t.textTheme.bodyLarge?.copyWith(
                              color: const Color(0xFF3D3A35),
                              height: 1.45,
                            ),
                      ),
                      const SizedBox(height: 28),
                      FilledButton(
                        onPressed: onSignup,
                        child: const Text('Sign up'),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton(
                        onPressed: onLogin,
                        child: const Text('Log in'),
                      ),
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: onSupport,
                        child: const Text('Contact NexRide Support'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

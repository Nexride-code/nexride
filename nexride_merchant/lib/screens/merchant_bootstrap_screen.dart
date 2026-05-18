import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/merchant_app_state.dart';
import '../support/app_crash_guard.dart';
import '../utils/nx_callable_messages.dart';
import 'login_screen.dart';
import 'merchant_complete_application_screen.dart';
import 'merchant_shell_screen.dart';
import 'pending_merchant_approval_screen.dart';
import 'onboarding_status_screen.dart';

class MerchantBootstrapScreen extends StatefulWidget {
  const MerchantBootstrapScreen({super.key});

  @override
  State<MerchantBootstrapScreen> createState() => _MerchantBootstrapScreenState();
}

class _MerchantBootstrapScreenState extends State<MerchantBootstrapScreen> {
  StreamSubscription<User?>? _sub;

  @override
  void initState() {
    super.initState();
    startupStep('merchant_bootstrap_init');
    _sub = FirebaseAuth.instance.authStateChanges().listen(
      _onAuthUserChanged,
      onError: (Object error, StackTrace stackTrace) {
        startupError('auth_state_stream', error);
        debugPrintStack(
          label: 'STARTUP_ERROR auth_state_stream',
          stackTrace: stackTrace,
        );
      },
    );
  }

  void _onAuthUserChanged(User? user) {
    if (!mounted) return;
    if (user != null) {
      startupStep('auth_restored', fields: {'uid': user.uid});
    }
    final state = context.read<MerchantAppState>();
    state.attachAuth(user);
    if (user != null) {
      unawaited(_refreshMerchantAfterAuth(state));
    }
  }

  Future<void> _refreshMerchantAfterAuth(MerchantAppState state) async {
    try {
      startupStep('merchant_profile_load_start');
      await state.refreshMerchant();
      if (!mounted) return;
      startupStep('merchant_profile_load_done');
    } catch (error, stackTrace) {
      startupError('merchant_profile_load', error);
      debugPrintStack(
        label: 'STARTUP_ERROR merchant_profile_load',
        stackTrace: stackTrace,
      );
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final user = snap.data;
        if (user == null) {
          return const LoginScreen();
        }
        return Consumer<MerchantAppState>(
          builder: (context, state, _) {
            if (state.loadingMerchant && state.merchant == null) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }
            if (state.merchant == null) {
              if (state.merchantLoadFailureReason == 'not_found') {
                return OnboardingStatusScreen(
                  mode: OnboardingMode.noApplication,
                  onCompleteApplication: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const MerchantCompleteApplicationScreen(),
                      ),
                    );
                    if (context.mounted) {
                      await context.read<MerchantAppState>().refreshMerchant();
                    }
                  },
                );
              }
              return OnboardingStatusScreen(
                mode: OnboardingMode.error,
                message: nxPublicMessage(
                  state.merchantLoadError,
                  'Unable to load your merchant profile. Please try again.',
                ),
              );
            }
            if (state.shouldShowPendingApprovalGate) {
              final m = state.merchant!;
              return PendingMerchantApprovalScreen(
                merchant: m,
                onContinueToPortal: () => context.read<MerchantAppState>().acknowledgePendingPortal(),
              );
            }
            return const MerchantShellScreen();
          },
        );
      },
    );
  }
}

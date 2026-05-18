import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'map_screen.dart';
import 'nex_ride_app.dart' show rootScaffoldMessengerKey;
import 'support/rider_root_navigation.dart';
import 'ride_type_screen.dart';
import 'rider_signup.dart';
import 'services/rider_trip_deep_link_service.dart';
import 'services/rider_trust_bootstrap_service.dart';
import 'support/rider_login_support.dart';
import 'support/startup_rtdb_support.dart';

class RiderLogin extends StatefulWidget {
  const RiderLogin({super.key});

  @override
  State<RiderLogin> createState() => _RiderLoginState();
}

class _RiderLoginState extends State<RiderLogin> {
  final emailController = TextEditingController();
  final passwordController = TextEditingController();

  final FirebaseAuth auth = FirebaseAuth.instance;
  final DatabaseReference dbRef = FirebaseDatabase.instance.ref();
  final RiderTrustBootstrapService _trustBootstrapService =
      const RiderTrustBootstrapService();

  bool isLoading = false;
  bool _didNavigateAfterLogin = false;

  Future<void> loginUser() async {
    final email = emailController.text.trim();
    final password = passwordController.text.trim();

    if (email.isEmpty || password.isEmpty) {
      showMessage('Email and password required');
      return;
    }

    logRiderLoginTap();

    Widget? homeDestination;
    var navigateHome = false;

    try {
      if (mounted) {
        setState(() => isLoading = true);
      }

      logRiderLoginAuthStart();

      final UserCredential userCredential = await auth
          .signInWithEmailAndPassword(
            email: email,
            password: password,
          )
          .timeout(kRiderLoginAuthTimeout);

      final uid = (userCredential.user?.uid ?? '').trim();
      if (uid.isEmpty) {
        showLoginFailure(
          const RiderLoginFailure(
            logTag: 'RIDER_LOGIN_FAIL',
            userMessage:
                'Sign-in did not return a valid account. Please try again.',
            debugDetail: 'RIDER_LOGIN_FAIL reason=null_user_after_sign_in',
          ),
        );
        return;
      }

      logRiderLoginAuthSuccess(uid);

      RiderLoginProfileResult profileResult;
      try {
        profileResult = await restoreOrCreateRiderProfileAfterLogin(
          rootRef: dbRef,
          uid: uid,
          email: email,
          trustBootstrapService: _trustBootstrapService,
        );
      } on TimeoutException catch (error) {
        logRiderLoginTimeout(error);
        logRiderLoginProfileFail(uid, error);
        await persistMinimalRiderProfileBestEffort(
          rootRef: dbRef,
          riderId: uid,
          email: email,
          displayNameFallback: email.split('@').first,
          source: 'rider_login.timeout_minimal_profile',
        );
        profileResult = RiderLoginProfileResult(
          userData: <String, dynamic>{
            'uid': uid,
            'name': email.split('@').first,
            'email': email,
            'role': 'rider',
          },
          profileSetupRequired: true,
          effectiveRole: 'rider',
        );
        if (mounted) {
          showMessage(
            'Signed in. Profile sync timed out — continuing with a minimal profile.',
          );
        }
      }

      if (!isRiderAppCompatibleRole(profileResult.effectiveRole)) {
        logRiderRoleCheckFail(uid, profileResult.effectiveRole);
        await auth.signOut();
        if (mounted) {
          showMessage(riderRoleRejectionMessage(profileResult.effectiveRole));
        }
        return;
      }

      String? pendingTripRideId;
      try {
        pendingTripRideId = await RiderTripDeepLinkService.instance
            .consumePendingAfterAuth()
            .timeout(const Duration(seconds: 5));
      } catch (error, stackTrace) {
        debugPrint('RIDER_TRIP_LINK_AFTER_LOGIN_FAIL uid=$uid error=$error');
        debugPrintStack(
          label: 'RIDER_TRIP_LINK_AFTER_LOGIN',
          stackTrace: stackTrace,
        );
      }

      if (!mounted) {
        return;
      }

      homeDestination =
          pendingTripRideId != null && pendingTripRideId.isNotEmpty
              ? MapScreen(initialOpenRideId: pendingTripRideId)
              : const RideTypeScreen();
      navigateHome = true;
    } on TimeoutException catch (error, stackTrace) {
      logRiderLoginTimeout(error);
      logRiderLoginFail(error, stackTrace);
      showLoginFailure(classifyLoginFailure(error, stackTrace: stackTrace));
    } on FirebaseAuthException catch (error, stackTrace) {
      logRiderLoginFail(error, stackTrace);
      showLoginFailure(classifyLoginFailure(error, stackTrace: stackTrace));
    } catch (error, stackTrace) {
      logRiderLoginFail(error, stackTrace);
      showLoginFailure(
        classifyLoginFailure(error, stackTrace: stackTrace, phase: 'post_auth'),
      );
    } finally {
      if (mounted) {
        setState(() => isLoading = false);
      }
    }

    if (navigateHome && homeDestination != null) {
      await _navigateToHomeAfterLogin(homeDestination);
    }
  }

  Future<void> _navigateToHomeAfterLogin(Widget destination) async {
    if (_didNavigateAfterLogin) {
      logRiderLoginNavigateHomeSkippedDuplicate();
      return;
    }

    _didNavigateAfterLogin = true;
    logRiderLoginNavigateHomeStart();

    try {
      await riderRootReplaceAll(
        destination,
        logTag: 'RIDER_LOGIN_NAVIGATE_HOME',
      );
      logRiderLoginNavigateHomeDone();
    } catch (error, stackTrace) {
      _didNavigateAfterLogin = false;
      debugPrint('RIDER_LOGIN_NAVIGATE_HOME_FAIL error=$error');
      debugPrintStack(stackTrace: stackTrace);
      showMessage('Unable to open home screen. Please try again.');
    }
  }

  Future<void> _openSignUp() async {
    if (isLoading) {
      return;
    }
    debugPrint('RIDER_SIGNUP_OPEN');
    try {
      await riderRootPush(
        const RiderSignup(),
        logTag: 'RIDER_SIGNUP_OPEN',
      );
    } catch (error, stackTrace) {
      debugPrint('RIDER_SIGNUP_OPEN_FAIL error=$error');
      debugPrintStack(stackTrace: stackTrace);
      showMessage('Unable to open sign up. Please try again.');
    }
  }

  void showLoginFailure(RiderLoginFailure failure) {
    showMessage(formatLoginFailureForSnack(failure));
  }

  void showMessage(String message) {
    rootScaffoldMessengerKey.currentState?.showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const Color gold = Color(0xFFB57A2A);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 30),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              'NexRide Rider',
              style: TextStyle(
                color: gold,
                fontSize: 32,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'Login to continue',
              style: TextStyle(color: Colors.grey, fontSize: 16),
            ),
            const SizedBox(height: 40),
            TextField(
              controller: emailController,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                hintText: 'Email',
                hintStyle: TextStyle(color: Colors.grey),
              ),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: passwordController,
              obscureText: true,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                hintText: 'Password',
                hintStyle: TextStyle(color: Colors.grey),
              ),
            ),
            const SizedBox(height: 40),
            SizedBox(
              width: double.infinity,
              height: 55,
              child: ElevatedButton(
                onPressed: isLoading ? null : loginUser,
                style: ElevatedButton.styleFrom(
                  backgroundColor: gold,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(30),
                  ),
                ),
                child: isLoading
                    ? const CircularProgressIndicator(color: Colors.white)
                    : const Text('Login', style: TextStyle(fontSize: 18)),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text(
                  "Don't have an account?",
                  style: TextStyle(color: Colors.grey),
                ),
                TextButton(
                  onPressed: isLoading ? null : () => unawaited(_openSignUp()),
                  child: const Text(
                    'Sign Up',
                    style: TextStyle(color: gold, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

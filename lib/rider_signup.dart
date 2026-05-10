import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:geolocator/geolocator.dart';

import 'onboarding/rider_selfie_verification_screen.dart';
import 'services/rider_compliance_service.dart'
    show RiderComplianceService, RiderPolicyDocumentKind;
import 'services/rider_trust_bootstrap_service.dart';
import 'support/firebase_rtdb_guard.dart';
import 'support/friendly_firebase_errors.dart';
import 'support/startup_rtdb_support.dart';
import 'widgets/rider_policy_bottom_sheet.dart';

class RiderSignup extends StatefulWidget {
  const RiderSignup({super.key});

  @override
  State<RiderSignup> createState() => _RiderSignupState();
}

class _RiderSignupState extends State<RiderSignup> {
  final nameController = TextEditingController();
  final emailController = TextEditingController();
  final phoneController = TextEditingController();
  final passwordController = TextEditingController();

  final FirebaseAuth auth = FirebaseAuth.instance;
  final DatabaseReference dbRef = FirebaseDatabase.instance.ref();
  final RiderTrustBootstrapService _trustBootstrapService =
      const RiderTrustBootstrapService();

  bool isLoading = false;
  bool _agreedPolicies = false;
  bool _confirmedAge18 = false;

  Future<void> registerUser() async {
    if (emailController.text.trim().isEmpty ||
        passwordController.text.trim().isEmpty ||
        nameController.text.trim().isEmpty) {
      showMessage("All fields required");
      return;
    }
    if (!_agreedPolicies || !_confirmedAge18) {
      showMessage("Please accept the terms and confirm your age to continue.");
      return;
    }

    setState(() => isLoading = true);

    try {
      // 🔐 CREATE AUTH ACCOUNT
      await FirebaseAuth.instance.createUserWithEmailAndPassword(
            email: emailController.text.trim(),
            password: passwordController.text.trim(),
          );

      final authUser = await waitForAuthenticatedUser();
      String uid = authUser.uid;

      try {
        await RiderComplianceService.instance.saveSignupConsent(uid: uid);
      } catch (e, st) {
        debugPrint('[RIDER_SIGNUP] consent save failed: $e $st');
        try {
          await FirebaseAuth.instance.currentUser?.delete();
        } catch (_) {}
        if (mounted) {
          showMessage(
            'Could not save your legal consent. Check your connection and try again.',
          );
        }
        return;
      }

      double? locLat;
      double? locLng;
      try {
        final svc = await Geolocator.isLocationServiceEnabled();
        if (svc) {
          var permission = await Geolocator.checkPermission();
          if (permission == LocationPermission.denied) {
            permission = await Geolocator.requestPermission();
          }
          if (permission != LocationPermission.denied &&
              permission != LocationPermission.deniedForever) {
            final pos = await Geolocator.getCurrentPosition(
              timeLimit: const Duration(seconds: 12),
            );
            locLat = pos.latitude;
            locLng = pos.longitude;
          }
        }
      } catch (e, st) {
        debugPrint('[RIDER_SIGNUP_GPS] skipped error=$e $st');
      }

      final baseUser = <String, dynamic>{
        "uid": uid,
        "name": nameController.text.trim(),
        "email": emailController.text.trim(),
        "phone": phoneController.text.trim(),
        "role": "rider",
        "created_at": ServerValue.timestamp,
        if (locLat != null && locLng != null) "signup_lat": locLat,
        if (locLat != null && locLng != null) "signup_lng": locLng,
        if (locLat != null && locLng != null)
          "signup_location_at": ServerValue.timestamp,
      };
      final bundle = await _trustBootstrapService.ensureRiderTrustState(
        riderId: uid,
        existingUser: baseUser,
        fallbackName: nameController.text.trim(),
        fallbackEmail: emailController.text.trim(),
        fallbackPhone: phoneController.text.trim(),
      );

      await runWithDatabaseRetry<void>(
        label: 'rider_signup.bootstrap_write',
        action: () => persistRiderOwnedBootstrap(
          rootRef: dbRef,
          riderId: uid,
          userProfile: <String, dynamic>{
            ...baseUser,
            ...bundle.userProfile,
            "created_at": ServerValue.timestamp,
          },
          verification: bundle.verification,
          deviceFingerprints: bundle.deviceFingerprints,
          source: 'rider_signup.bootstrap_write',
        ),
      );

      if (!mounted) {
        return;
      }
      showMessage("Account created ✅");

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => const RiderSelfieVerificationScreen(),
        ),
      );
    } on FirebaseAuthException catch (e) {
      if (e.code == 'email-already-in-use') {
        showMessage("Email already in use ❌");
      } else {
        showMessage(friendlyFirebaseAuthError(e));
      }
    } catch (e) {
      debugPrint('$e');
      if (e is StartupRtdbException) {
        showMessage(
          startupDebugMessage(
            "We could not finish setting up your rider account ❌",
            path: e.path,
            error: e.cause,
          ),
        );
      } else {
        showMessage(friendlyFirebaseError(e, debugLabel: 'riderSignup'));
      }
    }

    if (mounted) {
      setState(() => isLoading = false);
    }
  }

  void showMessage(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  InputDecoration inputStyle(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Colors.grey),
      filled: true,
      fillColor: Colors.grey[900],
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
    );
  }

  @override
  void dispose() {
    nameController.dispose();
    emailController.dispose();
    phoneController.dispose();
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

        child: ListView(
          children: [
            const SizedBox(height: 100),

            const Center(
              child: Text(
                "NexRide",
                style: TextStyle(
                  color: gold,
                  fontSize: 34,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),

            const SizedBox(height: 10),

            const Center(
              child: Text(
                "Create Rider Account",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),

            const SizedBox(height: 40),

            TextField(
              controller: nameController,
              style: const TextStyle(color: Colors.white),
              decoration: inputStyle("Full Name"),
            ),

            const SizedBox(height: 20),

            TextField(
              controller: emailController,
              style: const TextStyle(color: Colors.white),
              decoration: inputStyle("Email"),
            ),

            const SizedBox(height: 20),

            TextField(
              controller: phoneController,
              style: const TextStyle(color: Colors.white),
              decoration: inputStyle("Phone Number"),
            ),

            const SizedBox(height: 20),

            TextField(
              controller: passwordController,
              obscureText: true,
              style: const TextStyle(color: Colors.white),
              decoration: inputStyle("Password"),
            ),

            const SizedBox(height: 22),

            CheckboxListTile(
              value: _agreedPolicies,
              onChanged: isLoading
                  ? null
                  : (v) => setState(() => _agreedPolicies = v ?? false),
              activeColor: gold,
              checkColor: Colors.black,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text(
                'I have read and agree to the Terms of Service, '
                'Privacy Policy, and Community Guidelines.',
                style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.35),
              ),
            ),
            Wrap(
              spacing: 6,
              runSpacing: 0,
              children: [
                TextButton(
                  onPressed: isLoading
                      ? null
                      : () => showRiderPolicyBottomSheet(
                            context,
                            RiderPolicyDocumentKind.terms,
                          ),
                  child: const Text(
                    'Terms of Service',
                    style: TextStyle(
                      color: gold,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: isLoading
                      ? null
                      : () => showRiderPolicyBottomSheet(
                            context,
                            RiderPolicyDocumentKind.privacy,
                          ),
                  child: const Text(
                    'Privacy Policy',
                    style: TextStyle(
                      color: gold,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: isLoading
                      ? null
                      : () => showRiderPolicyBottomSheet(
                            context,
                            RiderPolicyDocumentKind.community,
                          ),
                  child: const Text(
                    'Community Guidelines',
                    style: TextStyle(
                      color: gold,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            CheckboxListTile(
              value: _confirmedAge18,
              onChanged: isLoading
                  ? null
                  : (v) => setState(() => _confirmedAge18 = v ?? false),
              activeColor: gold,
              checkColor: Colors.black,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text(
                'I confirm I am 18 years or older.',
                style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.35),
              ),
            ),

            const SizedBox(height: 28),

            SizedBox(
              width: double.infinity,
              height: 55,

              child: ElevatedButton(
                onPressed: (isLoading || !_agreedPolicies || !_confirmedAge18)
                    ? null
                    : registerUser,
                style: ElevatedButton.styleFrom(
                  backgroundColor: gold,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(30),
                  ),
                ),
                child: isLoading
                    ? const CircularProgressIndicator(color: Colors.white)
                    : const Text(
                        "Create Account",
                        style: TextStyle(fontSize: 18),
                      ),
              ),
            ),

            const SizedBox(height: 20),

            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text(
                  "Already have an account?",
                  style: TextStyle(color: Colors.grey),
                ),

                TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                  },
                  child: const Text(
                    "Login",
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

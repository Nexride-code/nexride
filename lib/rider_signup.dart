import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'ride_type_screen.dart';
import 'services/rider_trust_bootstrap_service.dart';
import 'support/firebase_rtdb_guard.dart';
import 'support/startup_rtdb_support.dart';

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

  Future<void> registerUser() async {
    if (emailController.text.trim().isEmpty ||
        passwordController.text.trim().isEmpty ||
        nameController.text.trim().isEmpty) {
      showMessage("All fields required");
      return;
    }

    setState(() => isLoading = true);

    try {
      // 🔐 CREATE AUTH ACCOUNT
      UserCredential userCredential = await FirebaseAuth.instance
          .createUserWithEmailAndPassword(
            email: emailController.text.trim(),
            password: passwordController.text.trim(),
          );

      final authUser = await waitForAuthenticatedUser();
      String uid = authUser.uid;

      final baseUser = <String, dynamic>{
        "uid": uid,
        "name": nameController.text.trim(),
        "email": emailController.text.trim(),
        "phone": phoneController.text.trim(),
        "role": "rider",
        "created_at": ServerValue.timestamp,
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
        MaterialPageRoute(builder: (context) => const RideTypeScreen()),
      );
    } on FirebaseAuthException catch (e) {
      if (e.code == 'email-already-in-use') {
        showMessage("Email already in use ❌");
      } else {
        showMessage(e.message ?? "Signup failed");
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
        showMessage("Error occurred ❌");
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

            const SizedBox(height: 40),

            SizedBox(
              width: double.infinity,
              height: 55,

              child: ElevatedButton(
                onPressed: isLoading ? null : registerUser,
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

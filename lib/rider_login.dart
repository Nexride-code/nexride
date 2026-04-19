import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'ride_type_screen.dart';
import 'rider_signup.dart';
import 'services/rider_trust_bootstrap_service.dart';
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

  Future<void> loginUser() async {
    if (emailController.text.trim().isEmpty ||
        passwordController.text.trim().isEmpty) {
      showMessage("Email and password required");
      return;
    }

    setState(() => isLoading = true);

    try {
      // 🔐 LOGIN
      UserCredential userCredential = await auth.signInWithEmailAndPassword(
        email: emailController.text.trim(),
        password: passwordController.text.trim(),
      );

      String uid = userCredential.user!.uid;

      DatabaseReference userRef = FirebaseDatabase.instance.ref("users/$uid");

      final snapshot = await runOptionalStartupRead<DataSnapshot>(
        source: 'rider_login.user_profile',
        path: 'users/$uid',
        action: () => userRef.get(),
      );

      final existingUser = snapshot?.value is Map
          ? Map<String, dynamic>.from(snapshot!.value as Map)
          : <String, dynamic>{};
      final userData = <String, dynamic>{
        ...existingUser,
        if (snapshot == null || !snapshot.exists) ...<String, dynamic>{
          "uid": uid,
          "name": emailController.text.split("@")[0],
          "email": emailController.text.trim(),
          "phone": "",
          "role": "rider",
          "created_at": ServerValue.timestamp,
        },
      };

      final bundle = await _trustBootstrapService.ensureRiderTrustState(
        riderId: uid,
        existingUser: userData,
        fallbackName: emailController.text.split("@")[0],
        fallbackEmail: emailController.text.trim(),
      );

      await persistRiderOwnedBootstrap(
        rootRef: dbRef,
        riderId: uid,
        userProfile: <String, dynamic>{
          ...userData,
          ...bundle.userProfile,
          "created_at": userData["created_at"] ?? ServerValue.timestamp,
        },
        verification: bundle.verification,
        deviceFingerprints: bundle.deviceFingerprints,
        source: 'rider_login.bootstrap_write',
      );

      debugPrint(
        snapshot?.exists == true
            ? "✅ Rider profile found"
            : "✅ Rider profile created",
      );

      // ✅ ROLE CHECK
      if (userData["role"] != "rider") {
        await auth.signOut();
        if (!mounted) {
          return;
        }
        showMessage("Access denied ❌");
        setState(() => isLoading = false);
        return;
      }

      if (!mounted) {
        return;
      }
      showMessage("Login successful ✅");

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const RideTypeScreen()),
      );
    } on FirebaseAuthException catch (e) {
      debugPrint("AUTH ERROR: ${e.code}");

      if (e.code == 'user-not-found') {
        showMessage("No user found ❌");
      } else if (e.code == 'wrong-password') {
        showMessage("Wrong password ❌");
      } else {
        showMessage(e.message ?? "Login failed");
      }
    } catch (e) {
      debugPrint("GENERAL ERROR: $e");
      if (e is StartupRtdbException) {
        showMessage(
          startupDebugMessage(
            "We could not finish loading your rider account right now ❌",
            path: e.path,
            error: e.cause,
          ),
        );
      } else {
        showMessage("Something went wrong ❌");
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
              "NexRide Rider",
              style: TextStyle(
                color: gold,
                fontSize: 32,
                fontWeight: FontWeight.bold,
              ),
            ),

            const SizedBox(height: 10),

            const Text(
              "Login to continue",
              style: TextStyle(color: Colors.grey, fontSize: 16),
            ),

            const SizedBox(height: 40),

            TextField(
              controller: emailController,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                hintText: "Email",
                hintStyle: TextStyle(color: Colors.grey),
              ),
            ),

            const SizedBox(height: 20),

            TextField(
              controller: passwordController,
              obscureText: true,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                hintText: "Password",
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
                    : const Text("Login", style: TextStyle(fontSize: 18)),
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
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const RiderSignup(),
                      ),
                    );
                  },
                  child: const Text(
                    "Sign Up",
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

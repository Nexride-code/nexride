import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'driver_home_screen.dart';
import 'driver_signup.dart';
import 'package:lottie/lottie.dart';

import '../support/realtime_database_error_support.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final emailController = TextEditingController();
  final passwordController = TextEditingController();

  final dbRef = FirebaseDatabase.instance.ref();

  bool isLoading = false;

  void loginDriver() async {
    if (emailController.text.isEmpty || passwordController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Please fill all fields")));
      return;
    }

    setState(() {
      isLoading = true;
    });

    try {
      /// 🔥 STEP 1: Login with Firebase Auth
      UserCredential userCredential =
          await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: emailController.text.trim(),
        password: passwordController.text.trim(),
      );

      String uid = userCredential.user!.uid;
      final profilePath = 'drivers/$uid';
      debugPrint('[DriverLoginLegacy] profile read started path=$profilePath');

      /// 🔥 STEP 2: Check driver in Realtime DB
      DatabaseEvent? event =
          await runOptionalRealtimeDatabaseRead<DatabaseEvent>(
        source: 'driver_login_legacy.profile_lookup',
        path: profilePath,
        action: () => dbRef.child("drivers").child(uid).once(),
      );

      if (event == null) {
        await FirebaseAuth.instance.signOut();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              realtimeDatabaseDebugMessage(
                "We couldn't load your driver profile right now. Please try again.",
                path: profilePath,
                error: 'profile_lookup_unavailable',
              ),
            ),
          ),
        );
      } else if (event.snapshot.value != null) {
        /// ✅ Driver exists → go to home
        if (!mounted) return;
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => const DriverHomeScreen(),
          ),
        );
      } else {
        /// ❌ Driver not found
        await FirebaseAuth.instance.signOut();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Driver profile not found")),
        );
      }
    } on FirebaseAuthException catch (e) {
      String message = "Login failed";

      if (e.code == 'user-not-found') {
        message = "No account found";
      } else if (e.code == 'wrong-password') {
        message = "Wrong password";
      } else if (e.code == 'invalid-email') {
        message = "Invalid email";
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          realtimeDatabaseDebugMessage(
            "We could not finish driver startup. Please try again.",
            path: FirebaseAuth.instance.currentUser == null
                ? 'auth'
                : 'drivers/${FirebaseAuth.instance.currentUser!.uid}',
            error: e,
          ),
        ),
      ));
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          /// ANIMATION
          Positioned.fill(
            child: Lottie.asset(
              "assets/animations/taxi_animation.json",
              fit: BoxFit.cover,
              repeat: true,
            ),
          ),

          /// DARK OVERLAY
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.65),
                    Colors.black.withValues(alpha: 0.75),
                    Colors.black.withValues(alpha: 0.90),
                  ],
                ),
              ),
            ),
          ),

          /// CONTENT
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 25),
                child: Column(
                  children: [
                    /// LOGO
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.amber,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Icon(
                        Icons.local_taxi,
                        size: 45,
                        color: Colors.black,
                      ),
                    ),

                    const SizedBox(height: 25),

                    const Text(
                      "NexRide",
                      style: TextStyle(
                        fontSize: 38,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),

                    const Text(
                      "Driver Login",
                      style: TextStyle(
                        color: Colors.white70,
                      ),
                    ),

                    const SizedBox(height: 40),

                    /// EMAIL FIELD
                    TextField(
                      controller: emailController,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: Colors.white10,
                        hintText: "Email",
                        hintStyle: const TextStyle(color: Colors.white54),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(15),
                        ),
                      ),
                    ),

                    const SizedBox(height: 15),

                    /// PASSWORD FIELD
                    TextField(
                      controller: passwordController,
                      obscureText: true,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: Colors.white10,
                        hintText: "Password",
                        hintStyle: const TextStyle(color: Colors.white54),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(15),
                        ),
                      ),
                    ),

                    const SizedBox(height: 25),

                    /// LOGIN BUTTON
                    isLoading
                        ? const CircularProgressIndicator()
                        : ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.amber,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 80,
                                vertical: 18,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(35),
                              ),
                            ),
                            onPressed: loginDriver,
                            child: const Text(
                              "LOGIN",
                              style: TextStyle(
                                color: Colors.black,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),

                    const SizedBox(height: 15),

                    /// SIGNUP LINK
                    TextButton(
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => const DriverSignup(),
                          ),
                        );
                      },
                      child: const Text(
                        "Don't have an account? Sign Up",
                        style: TextStyle(color: Colors.white70),
                      ),
                    )
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../services/auth_service.dart';
import '../services/firebase_rtdb_guard.dart';

class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});

  @override
  _SignupScreenState createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {

  final emailController = TextEditingController();
  final passwordController = TextEditingController();

  final AuthService authService = AuthService();

  final DatabaseReference dbRef = FirebaseDatabase.instance.ref();

  bool isLoading = false;

  void signUp() async {

    if(emailController.text.isEmpty || passwordController.text.isEmpty){
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please fill all fields"))
      );
      return;
    }

    setState(() {
      isLoading = true;
    });

    try {

      // 🔥 STEP 1: Create user
      UserCredential? userCredential = await FirebaseAuth.instance
          .createUserWithEmailAndPassword(
        email: emailController.text.trim(),
        password: passwordController.text.trim(),
      );

      final authUser = await waitForAuthenticatedUser();
      String uid = authUser.uid;

      // 🔥 STEP 2: Save to Realtime Database
      await runWithDatabaseRetry<void>(
        label: 'driver_signup.bootstrap',
        action: () async {
          final updates = <String, Object?>{
            "drivers/$uid/uid": uid,
            "drivers/$uid/email": emailController.text.trim(),
            "drivers/$uid/role": "driver",
            "drivers/$uid/status": "offline",
            "drivers/$uid/isOnline": false,
            "drivers/$uid/isAvailable": false,
            "drivers/$uid/updated_at": ServerValue.timestamp,
            "drivers/$uid/created_at": ServerValue.timestamp,
            "users/$uid/uid": uid,
            "users/$uid/email": emailController.text.trim(),
            "users/$uid/role": "driver",
            "users/$uid/updated_at": ServerValue.timestamp,
            "users/$uid/created_at": ServerValue.timestamp,
            "online_drivers/$uid": {
              "uid": uid,
              "online": false,
              "updated_at": ServerValue.timestamp,
            },
            "active_driver_locations/$uid": {
              "uid": uid,
              "lat": 0,
              "lng": 0,
              "heading": 0,
              "updated_at": ServerValue.timestamp,
            },
            "driver_active_rides/$uid": {
              "uid": uid,
              "ride_id": null,
              "updated_at": ServerValue.timestamp,
            },
          };
          await dbRef.update(updates);
        },
      );

      // ✅ SUCCESS
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Account Created Successfully ✅"))
      );

      Navigator.pop(context);

    } on FirebaseAuthException catch (e) {

      String message = "Something went wrong";

      if(e.code == 'email-already-in-use'){
        message = "Email already in use";
      } else if(e.code == 'weak-password'){
        message = "Password too weak";
      } else if(e.code == 'invalid-email'){
        message = "Invalid email";
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message))
      );

    } catch (e) {

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error: ${e.toString()}"))
      );

    } finally {
      setState(() {
        isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {

    return Scaffold(
      appBar: AppBar(
        title: const Text("NexRide Sign Up"),
      ),

      body: Padding(
        padding: const EdgeInsets.all(20),

        child: Column(
          children: [

            TextField(
              controller: emailController,
              decoration: const InputDecoration(
                labelText: "Email",
              ),
            ),

            TextField(
              controller: passwordController,
              decoration: const InputDecoration(
                labelText: "Password",
              ),
              obscureText: true,
            ),

            const SizedBox(height:20),

            isLoading
                ? const CircularProgressIndicator()
                : ElevatedButton(
                    onPressed: signUp,
                    child: const Text("Create Account"),
                  )

          ],
        ),
      ),
    );
  }
}
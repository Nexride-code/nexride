import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../services/auth_service.dart';

class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
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
        SnackBar(content: Text("Please fill all fields"))
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

      String uid = userCredential.user!.uid;

      // 🔥 STEP 2: Save to Realtime Database
      await dbRef.child("drivers").child(uid).set({
        "uid": uid,
        "email": emailController.text.trim(),
        "status": "active",
        "created_at": DateTime.now().toIso8601String(),
      });

      // ✅ SUCCESS
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Account Created Successfully ✅"))
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
        title: Text("NexRide Sign Up"),
      ),

      body: Padding(
        padding: EdgeInsets.all(20),

        child: Column(
          children: [

            TextField(
              controller: emailController,
              decoration: InputDecoration(
                labelText: "Email",
              ),
            ),

            TextField(
              controller: passwordController,
              decoration: InputDecoration(
                labelText: "Password",
              ),
              obscureText: true,
            ),

            SizedBox(height:20),

            isLoading
                ? CircularProgressIndicator()
                : ElevatedButton(
                    onPressed: signUp,
                    child: Text("Create Account"),
                  )

          ],
        ),
      ),
    );
  }
}
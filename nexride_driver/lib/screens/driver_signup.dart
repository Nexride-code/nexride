import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

import '../config/driver_app_config.dart';
import '../support/driver_profile_bootstrap_support.dart';
import '../support/driver_profile_support.dart';
import '../support/friendly_firebase_errors.dart';

class DriverSignup extends StatefulWidget {
  const DriverSignup({super.key});

  @override
  State<DriverSignup> createState() => _DriverSignupState();
}

class _DriverSignupState extends State<DriverSignup> {
  final nameController = TextEditingController();
  final emailController = TextEditingController();
  final phoneController = TextEditingController();
  final passwordController = TextEditingController();

  final FirebaseAuth auth = FirebaseAuth.instance;
  final DatabaseReference dbRef = FirebaseDatabase.instance.ref();

  bool isLoading = false;
  final Set<String> _selectedDriverServiceTypes = <String>{'car_driver'};

  static const Map<String, String> _driverServiceToRequestServiceType =
      <String, String>{
    'car_driver': 'ride',
    'dispatch_driver': 'dispatch_delivery',
  };

  InputDecoration _inputDecoration({
    required String label,
    required String hint,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      labelStyle: TextStyle(color: Colors.black.withValues(alpha: 0.65)),
      hintStyle: TextStyle(color: Colors.black.withValues(alpha: 0.42)),
      filled: true,
      fillColor: kDriverCream,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide(color: Colors.black.withValues(alpha: 0.08)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: const BorderSide(color: kDriverGold, width: 1.4),
      ),
    );
  }

  Future<void> registerDriver() async {
    FocusScope.of(context).unfocus();

    if (nameController.text.trim().isEmpty ||
        emailController.text.trim().isEmpty ||
        phoneController.text.trim().isEmpty ||
        passwordController.text.trim().isEmpty) {
      showMessage("All fields are required");
      return;
    }

    if (passwordController.text.trim().length < 6) {
      showMessage("Password must be at least 6 characters");
      return;
    }
    if (_selectedDriverServiceTypes.isEmpty) {
      showMessage("Select at least one driver service type");
      return;
    }

    setState(() => isLoading = true);

    try {
      debugPrint(
        '[DriverSignup] creating account email=${emailController.text.trim()}',
      );

      UserCredential userCredential = await auth.createUserWithEmailAndPassword(
        email: emailController.text.trim(),
        password: passwordController.text.trim(),
      );

      String uid = userCredential.user!.uid;

      final profilePath = driverProfilePath(uid);
      final verificationPath = driverVerificationAdminPath(uid);
      final pricingConfig = await fetchDriverPricingConfig(
        rootRef: dbRef,
        source: 'signup',
      );
      final profileRecord = buildDriverProfileRecord(
        driverId: uid,
        existing: <String, dynamic>{},
        fallbackName: nameController.text.trim(),
        fallbackEmail: emailController.text.trim(),
        fallbackPhone: phoneController.text.trim(),
        pricingConfig: pricingConfig,
      );
      final selectedDriverServiceTypes = _selectedDriverServiceTypes.toList(
        growable: false,
      )..sort();
      final requestServiceTypes = selectedDriverServiceTypes
          .map((String type) => _driverServiceToRequestServiceType[type] ?? '')
          .where((String type) => type.isNotEmpty)
          .toSet()
          .toList(growable: false)
        ..sort();
      debugPrint(
        '[DriverSignup] profile write started uid=$uid path=$profilePath verificationPath=$verificationPath',
      );

      await dbRef.update({
        profilePath: {
          ...profileRecord,
          "driver_service_types": selectedDriverServiceTypes,
          "serviceTypes": requestServiceTypes,
          "created_at": ServerValue.timestamp,
          "updated_at": ServerValue.timestamp,
        },
        verificationPath: {
          ...buildDriverVerificationAdminPayload(
            driverId: uid,
            driverProfile: profileRecord,
            verification: profileRecord["verification"] as Map<String, dynamic>,
          ),
          "createdAt": ServerValue.timestamp,
          "updatedAt": ServerValue.timestamp,
        },
      });

      debugPrint('[DriverSignup] account created uid=$uid path=$profilePath');
      showMessage("Driver account created successfully ✅");

      if (!mounted) {
        return;
      }

      Navigator.pop(context);
    } on FirebaseAuthException catch (e) {
      if (e.code == 'email-already-in-use') {
        showMessage("Email already in use ❌");
      } else if (e.code == 'invalid-email') {
        showMessage("Invalid email format ❌");
      } else {
        showMessage(friendlyFirebaseAuthError(e));
      }
    } catch (e) {
      showMessage(friendlyFirebaseError(e, debugLabel: 'driverSignup'));
    }

    if (mounted) {
      setState(() => isLoading = false);
    }
  }

  void showMessage(String message) {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
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
    return Scaffold(
      backgroundColor: kDriverCream,
      appBar: AppBar(
        title: const Text("Driver Sign Up"),
        backgroundColor: kDriverGold,
        foregroundColor: Colors.black,
        centerTitle: true,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: <Widget>[
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: kDriverDark,
                borderRadius: BorderRadius.circular(30),
                boxShadow: const <BoxShadow>[
                  BoxShadow(
                    color: Color(0x22000000),
                    blurRadius: 18,
                    offset: Offset(0, 12),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: kDriverGold.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: const Icon(
                      Icons.badge_outlined,
                      color: kDriverGold,
                    ),
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'Create your driver profile',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Set up your account first, then choose your business model and submit verification documents from the Driver Hub.',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.76),
                      height: 1.55,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(30),
                boxShadow: const <BoxShadow>[
                  BoxShadow(
                    color: Color(0x16000000),
                    blurRadius: 16,
                    offset: Offset(0, 10),
                  ),
                ],
              ),
              child: Column(
                children: <Widget>[
                  TextField(
                    controller: nameController,
                    enabled: !isLoading,
                    style: const TextStyle(color: Colors.black87),
                    textCapitalization: TextCapitalization.words,
                    decoration: _inputDecoration(
                      label: "Full Name",
                      hint: "Enter your full legal name",
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: emailController,
                    enabled: !isLoading,
                    style: const TextStyle(color: Colors.black87),
                    keyboardType: TextInputType.emailAddress,
                    decoration: _inputDecoration(
                      label: "Email",
                      hint: "Enter your email address",
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: phoneController,
                    enabled: !isLoading,
                    style: const TextStyle(color: Colors.black87),
                    keyboardType: TextInputType.phone,
                    decoration: _inputDecoration(
                      label: "Phone",
                      hint: "Enter your phone number",
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: passwordController,
                    enabled: !isLoading,
                    obscureText: true,
                    style: const TextStyle(color: Colors.black87),
                    decoration: _inputDecoration(
                      label: "Password",
                      hint: "Minimum 6 characters",
                    ),
                  ),
                  const SizedBox(height: 16),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Driver service type',
                      style: TextStyle(
                        color: Colors.black.withValues(alpha: 0.78),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    value: _selectedDriverServiceTypes.contains('car_driver'),
                    onChanged: isLoading
                        ? null
                        : (bool? value) {
                            setState(() {
                              if (value == true) {
                                _selectedDriverServiceTypes.add('car_driver');
                              } else {
                                _selectedDriverServiceTypes
                                    .remove('car_driver');
                              }
                            });
                          },
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text('Car driver'),
                  ),
                  CheckboxListTile(
                    value:
                        _selectedDriverServiceTypes.contains('dispatch_driver'),
                    onChanged: isLoading
                        ? null
                        : (bool? value) {
                            setState(() {
                              if (value == true) {
                                _selectedDriverServiceTypes.add(
                                  'dispatch_driver',
                                );
                              } else {
                                _selectedDriverServiceTypes.remove(
                                  'dispatch_driver',
                                );
                              }
                            });
                          },
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text('Dispatch driver'),
                  ),
                  const SizedBox(height: 22),
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton(
                      onPressed: isLoading ? null : registerDriver,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: kDriverGold,
                        foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                      child: isLoading
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                color: Colors.black,
                                strokeWidth: 2.4,
                              ),
                            )
                          : const Text(
                              "Create Driver Account",
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Icon(
                    Icons.verified_user_outlined,
                    color: kDriverGold,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      DriverFeatureFlags.driverVerificationRequired
                          ? 'After signup, your account stays offline until you choose an operating model and complete verification review steps as needed.'
                          : 'After signup, choose an operating model and complete verification review steps as needed. Driver verification stays active in the background, but it does not block going online while this flag is off.',
                      style: TextStyle(
                        color: Colors.black.withValues(alpha: 0.68),
                        height: 1.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

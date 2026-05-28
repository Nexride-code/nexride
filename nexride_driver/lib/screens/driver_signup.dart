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
  String _selectedServiceType = kServiceTypeCarRide;

  static const List<_ServiceTypeOption> _serviceTypeOptions =
      <_ServiceTypeOption>[
    _ServiceTypeOption(
      value: kServiceTypeCarRide,
      title: 'Car ride',
      subtitle: 'Pick up and drop off riders (ride-hailing).',
      icon: Icons.directions_car_filled_outlined,
    ),
    _ServiceTypeOption(
      value: kServiceTypeBikeDispatch,
      title: 'Bike dispatch',
      subtitle: 'Deliver packages and orders on a bike.',
      icon: Icons.pedal_bike_outlined,
    ),
    _ServiceTypeOption(
      value: kServiceTypeVanDispatch,
      title: 'Van dispatch',
      subtitle: 'Move larger deliveries with a van.',
      icon: Icons.airport_shuttle_outlined,
    ),
  ];

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
      final serviceType = _selectedServiceType;
      final profileRecord = buildDriverProfileRecord(
        driverId: uid,
        existing: <String, dynamic>{'service_type': serviceType},
        fallbackName: nameController.text.trim(),
        fallbackEmail: emailController.text.trim(),
        fallbackPhone: phoneController.text.trim(),
        pricingConfig: pricingConfig,
      );
      final requestServiceTypes =
          serviceTypesForDriverServiceType(serviceType);
      final legacyDriverServiceTypes =
          legacyDriverServiceTypesForServiceType(serviceType);
      final dispatchVehicleType =
          dispatchVehicleTypeForServiceType(serviceType);
      debugPrint(
        '[DriverSignup] profile write started uid=$uid path=$profilePath verificationPath=$verificationPath serviceType=$serviceType',
      );

      await dbRef.update({
        profilePath: {
          ...profileRecord,
          "driver_service_types": legacyDriverServiceTypes,
          "serviceTypes": requestServiceTypes,
          "dispatch_vehicle_type": dispatchVehicleType,
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
                      'What do you want to do?',
                      style: TextStyle(
                        color: Colors.black.withValues(alpha: 0.78),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Choose your main service. You can request to add more later.',
                      style: TextStyle(
                        color: Colors.black.withValues(alpha: 0.55),
                        fontSize: 12.5,
                        height: 1.4,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  for (final _ServiceTypeOption option in _serviceTypeOptions)
                    _ServiceTypeCard(
                      option: option,
                      selected: _selectedServiceType == option.value,
                      enabled: !isLoading,
                      onTap: () {
                        setState(() => _selectedServiceType = option.value);
                      },
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

class _ServiceTypeOption {
  const _ServiceTypeOption({
    required this.value,
    required this.title,
    required this.subtitle,
    required this.icon,
  });

  final String value;
  final String title;
  final String subtitle;
  final IconData icon;
}

class _ServiceTypeCard extends StatelessWidget {
  const _ServiceTypeCard({
    required this.option,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final _ServiceTypeOption option;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color borderColor =
        selected ? kDriverGold : Colors.black.withValues(alpha: 0.1);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: selected
            ? kDriverGold.withValues(alpha: 0.12)
            : kDriverCream,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: enabled ? onTap : null,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: borderColor,
                width: selected ? 1.6 : 1,
              ),
            ),
            child: Row(
              children: <Widget>[
                Icon(
                  option.icon,
                  color: selected
                      ? kDriverDark
                      : Colors.black.withValues(alpha: 0.6),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        option.title,
                        style: const TextStyle(
                          color: Colors.black87,
                          fontWeight: FontWeight.w700,
                          fontSize: 15.5,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        option.subtitle,
                        style: TextStyle(
                          color: Colors.black.withValues(alpha: 0.6),
                          fontSize: 12.5,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: selected
                      ? kDriverGold
                      : Colors.black.withValues(alpha: 0.35),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

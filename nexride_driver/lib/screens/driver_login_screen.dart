import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../support/driver_profile_bootstrap_support.dart';
import '../support/driver_profile_support.dart';
import '../support/production_user_messages.dart';
import '../support/realtime_database_error_support.dart';
import '../trip_sync/trip_state_machine.dart';
import 'driver_signup.dart';

class DriverLoginScreen extends StatefulWidget {
  const DriverLoginScreen({super.key});

  @override
  State<DriverLoginScreen> createState() => _DriverLoginScreenState();
}

class _DriverLoginScreenState extends State<DriverLoginScreen>
    with SingleTickerProviderStateMixin {
  final TextEditingController emailController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();

  bool isLoading = false;

  late final AnimationController _controller;
  late final Animation<Color?> _color1;
  late final Animation<Color?> _color2;

  @override
  void initState() {
    super.initState();

    _controller =
        AnimationController(vsync: this, duration: const Duration(seconds: 6))
          ..repeat(reverse: true);

    _color1 = ColorTween(
      begin: kDriverDark,
      end: const Color(0xFF2E2210),
    ).animate(_controller);

    _color2 = ColorTween(
      begin: const Color(0xFF171717),
      end: const Color(0xFF5A4114),
    ).animate(_controller);
  }

  Future<void> loginDriver() async {
    final email = emailController.text.trim();
    final password = passwordController.text.trim();

    if (email.isEmpty || password.isEmpty) {
      showMessage('Please enter email and password');
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() => isLoading = true);

    try {
      debugPrint('[DriverLogin] attempting login email=$email');

      final userCredential =
          await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email,
        password: password,
      );

      final user = userCredential.user;
      if (user == null) {
        throw FirebaseAuthException(
          code: 'missing-user',
          message: 'Signed in but no Firebase user was returned.',
        );
      }

      final rootRef = FirebaseDatabase.instance.ref();
      final profilePath = driverProfilePath(user.uid);
      final verificationPath = driverVerificationAdminPath(user.uid);
      final driverRef = rootRef.child(profilePath);
      debugPrint(
        '[DriverLogin] driver profile read started uid=${user.uid} path=$profilePath timeout=${kDriverProfileReadTimeout.inSeconds}s',
      );
      await driverRef.keepSynced(true);
      final snapshot = (await driverRef.once(DatabaseEventType.value).timeout(
                kDriverProfileReadTimeout,
              ))
          .snapshot;
      debugPrint(
        '[DriverLogin] driver profile read completed uid=${user.uid} path=$profilePath found=${snapshot.exists} valueType=${snapshot.value?.runtimeType ?? 'null'}',
      );
      final existing = snapshot.value is Map
          ? Map<String, dynamic>.from(snapshot.value as Map)
          : <String, dynamic>{};
      final pricingConfig = await fetchDriverPricingConfig(
        rootRef: rootRef,
        source: 'login',
      );

      final profileRecord = buildDriverProfileRecord(
        driverId: user.uid,
        existing: existing,
        fallbackName: email.split('@').first,
        fallbackEmail: email,
        pricingConfig: pricingConfig,
      );
      final existingActiveRideId =
          (existing['activeRideId']?.toString().trim().isNotEmpty ?? false)
              ? existing['activeRideId'].toString().trim()
              : existing['currentRideId']?.toString().trim() ?? '';
      final existingTripStatus = TripStateMachine.legacyStatusForCanonical(
        TripStateMachine.canonicalStateFromValues(
          tripState: existing['trip_state'],
          status: existing['status'],
        ),
      );
      final hasActiveTrip = existingActiveRideId.isNotEmpty &&
          <String>{
            'accepted',
            'arriving',
            'arrived',
            'on_trip',
          }.contains(
            existingTripStatus,
          );

      final profileUpdate = <String, Object?>{
        ...profileRecord,
        'last_availability_intent': existing['last_availability_intent'] ??
            (hasActiveTrip ? 'online' : 'offline'),
        'isOnline': false,
        'isAvailable': false,
        'available': false,
        'status': hasActiveTrip ? existingTripStatus : 'offline',
        'activeRideId': hasActiveTrip ? existingActiveRideId : null,
        'currentRideId': hasActiveTrip ? existingActiveRideId : null,
        'online_session_started_at':
            hasActiveTrip ? existing['online_session_started_at'] : null,
        'last_active': ServerValue.timestamp,
        'updated_at': ServerValue.timestamp,
      };

      if (!snapshot.exists) {
        profileUpdate['created_at'] = ServerValue.timestamp;
        profileUpdate['role'] = 'driver';
        profileUpdate['services'] = <String>['ride'];
        profileUpdate['market'] = 'lagos';
        profileUpdate['market_pool'] = 'lagos';
        profileUpdate['online'] = false;
        profileUpdate['status'] = 'active';
        profileUpdate['serviceTypes'] = <String>['ride'];
      }

      final rootUpdates = <String, Object?>{
        profilePath: profileUpdate,
        verificationPath: <String, Object?>{
          ...buildDriverVerificationAdminPayload(
            driverId: user.uid,
            driverProfile: profileRecord,
            verification: profileRecord['verification'] as Map<String, dynamic>,
          ),
          'createdAt': existing['created_at'] ?? ServerValue.timestamp,
          'updatedAt': ServerValue.timestamp,
        },
      };
      try {
        await rootRef.update(rootUpdates);
      } catch (error) {
        if (!isRealtimeDatabasePermissionDenied(error)) {
          rethrow;
        }

        debugPrint(
          '[DriverLogin] optional bootstrap write denied uid=${user.uid} verificationPath=$verificationPath error=$error',
        );
        await driverRef.update(profileUpdate);
      }

      debugPrint(
        '[DriverLogin] login success uid=${user.uid} profilePath=$profilePath verificationPath=$verificationPath',
      );

      if (!mounted) {
        return;
      }

      showMessage('Login successful');
    } on FirebaseAuthException catch (error) {
      debugPrint(
          '[DriverLogin] auth error code=${error.code} message=${error.message}');

      switch (error.code) {
        case 'user-not-found':
          showMessage('No account found');
          break;
        case 'wrong-password':
        case 'invalid-credential':
          showMessage('Wrong email or password');
          break;
        case 'invalid-email':
          showMessage('Invalid email');
          break;
        default:
          showMessage(error.message ?? 'Login error');
      }
    } catch (error, stackTrace) {
      debugPrint('[DriverLogin] unexpected error $error');
      debugPrintStack(label: '[DriverLogin]', stackTrace: stackTrace);
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        try {
          final rootRef = FirebaseDatabase.instance.ref();
          await rootRef.child(driverProfilePath(user.uid)).update(<String, Object?>{
            'uid': user.uid,
            'id': user.uid,
            'email': emailController.text.trim(),
            'role': 'driver',
            'online': false,
            'status': 'active',
            'services': <String>['ride'],
            'serviceTypes': <String>['ride'],
            'market': 'lagos',
            'market_pool': 'lagos',
            'created_at': ServerValue.timestamp,
            'updated_at': ServerValue.timestamp,
          });
          debugPrint('[DriverLogin] minimal driver seed attempted uid=${user.uid}');
        } catch (minimalError, minimalStack) {
          debugPrint('[DriverLogin] minimal driver seed failed: $minimalError');
          debugPrintStack(
            label: '[DriverLogin] minimal seed',
            stackTrace: minimalStack,
          );
        }
      }
      showMessage(kNexRideFriendlyFailureMessage);
    } finally {
      if (mounted) {
        setState(() => isLoading = false);
      }
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

  InputDecoration inputDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: Colors.black.withValues(alpha: 0.48)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide(color: Colors.black.withValues(alpha: 0.08)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: const BorderSide(color: kDriverGold, width: 1.4),
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide(color: Colors.black.withValues(alpha: 0.08)),
      ),
      filled: true,
      fillColor: kDriverCream,
    );
  }

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Scaffold(
          body: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [_color1.value!, _color2.value!],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: SafeArea(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(22, 18, 22, 28),
                children: <Widget>[
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(30),
                      color: Colors.white.withValues(alpha: 0.08),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.12),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            color: kDriverGold.withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: const Icon(
                            Icons.directions_car_filled_rounded,
                            color: kDriverGold,
                            size: 28,
                          ),
                        ),
                        const SizedBox(height: 20),
                        const Text(
                          'NexRide Driver',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 30,
                            fontWeight: FontWeight.w800,
                            height: 1.05,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Sign in to manage rides, dispatch jobs, verification, and your driver business settings.',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.78),
                            fontSize: 14,
                            height: 1.55,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 22),
                  Container(
                    padding: const EdgeInsets.all(22),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(30),
                      boxShadow: const <BoxShadow>[
                        BoxShadow(
                          color: Color(0x24000000),
                          blurRadius: 24,
                          offset: Offset(0, 16),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const Text(
                          'Welcome back',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w800,
                            color: Colors.black87,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Use the email and password linked to your driver account.',
                          style: TextStyle(
                            color: Colors.black.withValues(alpha: 0.62),
                            height: 1.45,
                          ),
                        ),
                        const SizedBox(height: 20),
                        TextField(
                          controller: emailController,
                          enabled: !isLoading,
                          style: const TextStyle(color: Colors.black87),
                          keyboardType: TextInputType.emailAddress,
                          decoration: inputDecoration('Email address'),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: passwordController,
                          enabled: !isLoading,
                          obscureText: true,
                          style: const TextStyle(color: Colors.black87),
                          decoration: inputDecoration('Password'),
                        ),
                        const SizedBox(height: 22),
                        SizedBox(
                          width: double.infinity,
                          height: 56,
                          child: ElevatedButton(
                            onPressed: isLoading ? null : loginDriver,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: kDriverGold,
                              foregroundColor: Colors.black,
                              elevation: 0,
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
                                    'Log In',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                          ),
                        ),
                        const SizedBox(height: 18),
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: kDriverCream,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            children: <Widget>[
                              const Icon(
                                Icons.workspace_premium_outlined,
                                color: kDriverGold,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  'Business model selection and verification status stay linked to your account after login.',
                                  style: TextStyle(
                                    color: Colors.black.withValues(alpha: 0.68),
                                    height: 1.45,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Text(
                        "Don't have a driver account?",
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.82),
                        ),
                      ),
                      TextButton(
                        onPressed: isLoading
                            ? null
                            : () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) => const DriverSignup(),
                                  ),
                                );
                              },
                        child: const Text(
                          'Sign Up',
                          style: TextStyle(
                            color: kDriverGold,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

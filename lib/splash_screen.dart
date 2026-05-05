import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

import 'ride_type_screen.dart';
import 'rider_login.dart';
import 'support/production_user_messages.dart';
import 'services/rider_trust_bootstrap_service.dart';
import 'services/rider_trust_rules_service.dart';
import 'support/startup_rtdb_support.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _StartupStepResult<T> {
  const _StartupStepResult.success(this.value)
    : succeeded = true,
      timedOut = false,
      error = null;

  const _StartupStepResult.fallback(
    this.value, {
    required this.error,
    required this.timedOut,
  }) : succeeded = false;

  final T value;
  final bool succeeded;
  final bool timedOut;
  final Object? error;
}

class _SplashScreenState extends State<SplashScreen> {
  static const Duration _kStartupStepTimeout = Duration(seconds: 6);
  static const Duration _kStartupFailSafeTimeout = Duration(seconds: 8);

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final DatabaseReference _rootRef = FirebaseDatabase.instance.ref();
  final RiderTrustBootstrapService _bootstrapService =
      const RiderTrustBootstrapService();
  final RiderTrustRulesService _trustRulesService =
      const RiderTrustRulesService();

  bool _bootstrapping = true;
  String? _startupMessage;
  bool _hasNavigated = false;
  bool _startupInProgress = false;
  bool _backgroundBootstrapQueued = false;
  int _startupRunId = 0;
  Timer? _startupFailSafeTimer;

  @override
  void initState() {
    super.initState();
    _scheduleStartupFailSafe();
    unawaited(_bootstrapStartupRoute());
  }

  @override
  void dispose() {
    _startupFailSafeTimer?.cancel();
    super.dispose();
  }

  Future<void> _bootstrapStartupRoute() async {
    if (_startupInProgress || _hasNavigated) {
      _logStartup('startup already running, ignoring duplicate call');
      return;
    }

    _startupInProgress = true;
    final runId = ++_startupRunId;
    _scheduleStartupFailSafe();
    _setStartupState(message: 'Getting things ready…');

    User? authenticatedUser;
    var nextScreen = _fallbackScreenFor(_auth.currentUser);
    var shouldStartBackgroundBootstrap = false;
    var existingUser = <String, dynamic>{};
    var startupRules = RiderTrustBootstrapService.defaultRules;

    try {
      final authResult = await _runStartupStep<User?>(
        label: 'auth check',
        fallbackValue: _auth.currentUser,
        action: () async {
          final currentUser = _auth.currentUser;
          if (currentUser != null) {
            return currentUser;
          }
          return _auth.authStateChanges().first.timeout(
            _kStartupStepTimeout,
            onTimeout: () => null,
          );
        },
      );

      authenticatedUser = authResult.value;
      nextScreen = _fallbackScreenFor(authenticatedUser);

      if (authenticatedUser == null) {
        _logStartup('bootstrap complete authenticated=false');
        return;
      }

      final signedInUser = authenticatedUser;

      _setStartupState(message: 'Preparing your NexRide rider account…');

      final profileResult = await _runStartupStep<Map<String, dynamic>>(
        label: 'profile fetch',
        fallbackValue: <String, dynamic>{},
        action: () => _fetchExistingUserProfile(signedInUser),
      );
      existingUser = profileResult.value;

      if (!profileResult.succeeded) {
        shouldStartBackgroundBootstrap = true;
        _logStartup(
          'profile fetch fallback enabled riderId=${signedInUser.uid}',
        );
        _logStartup('bootstrap complete authenticated=true background=true');
        return;
      }

      final configResult = await _runStartupStep<Map<String, dynamic>>(
        label: 'config load',
        fallbackValue: RiderTrustBootstrapService.defaultRules,
        action: _loadStartupConfig,
      );
      startupRules = configResult.value;

      final bootstrapResult = await _runStartupStep<bool>(
        label: 'session bootstrap',
        fallbackValue: false,
        action: () async {
          await _bootstrapSignedInRider(
            signedInUser,
            existingUser: existingUser,
            preloadedRules: startupRules,
          );
          return true;
        },
      );
      shouldStartBackgroundBootstrap = !bootstrapResult.succeeded;
      _logStartup(
        'bootstrap complete authenticated=true success=${bootstrapResult.succeeded}',
      );
    } catch (error) {
      _logStartup('startup route failed error=$error');
      shouldStartBackgroundBootstrap = authenticatedUser != null;
    } finally {
      _startupInProgress = false;

      if (shouldStartBackgroundBootstrap && authenticatedUser != null) {
        _startBackgroundBootstrap(
          user: authenticatedUser,
          existingUser: existingUser,
          preloadedRules: startupRules,
          refreshProfile: existingUser.isEmpty,
        );
      }

      if (mounted && !_hasNavigated && runId == _startupRunId) {
        _navigateTo(nextScreen);
      }
    }
  }

  Future<void> _bootstrapSignedInRider(
    User user, {
    required Map<String, dynamic> existingUser,
    required Map<String, dynamic> preloadedRules,
  }) async {
    final bundle = await _bootstrapService
        .ensureRiderTrustState(
          riderId: user.uid,
          existingUser: existingUser,
          fallbackName:
              existingUser['name']?.toString().trim().isNotEmpty == true
              ? existingUser['name']?.toString().trim()
              : user.email?.split('@').first,
          fallbackEmail: user.email,
          fallbackPhone: existingUser['phone']?.toString(),
          preloadedRules: preloadedRules,
        )
        .timeout(_kStartupStepTimeout);

    final bootstrapReady = await hasRiderBootstrapArtifacts(
      rootRef: _rootRef,
      riderId: user.uid,
      source: 'splash_screen.bootstrap_check',
    );
    if (!bootstrapReady) {
      await persistRiderOwnedBootstrap(
        rootRef: _rootRef,
        riderId: user.uid,
        userProfile: <String, dynamic>{
          ...existingUser,
          ...bundle.userProfile,
          'created_at': existingUser['created_at'] ?? ServerValue.timestamp,
        },
        verification: bundle.verification,
        deviceFingerprints: bundle.deviceFingerprints,
        source: 'splash_screen.bootstrap_write',
      ).timeout(_kStartupStepTimeout);
    }
  }

  Future<Map<String, dynamic>> _fetchExistingUserProfile(User user) async {
    return readUserProfileWithFallback(
      rootRef: _rootRef,
      uid: user.uid,
      source: 'splash_screen.user_profile',
    ).timeout(_kStartupStepTimeout, onTimeout: () => <String, dynamic>{});
  }

  Future<Map<String, dynamic>> _loadStartupConfig() {
    return _trustRulesService.fetchRules().timeout(
      _kStartupStepTimeout,
      onTimeout: () => RiderTrustBootstrapService.defaultRules,
    );
  }

  Future<_StartupStepResult<T>> _runStartupStep<T>({
    required String label,
    required T fallbackValue,
    required Future<T> Function() action,
  }) async {
    _logStartup('$label start');
    try {
      final value = await action().timeout(_kStartupStepTimeout);
      _logStartup('$label done');
      return _StartupStepResult<T>.success(value);
    } on TimeoutException catch (error, stackTrace) {
      _logStartup('$label done timeout=true');
      debugPrintStack(
        label: '[Splash] $label timeout',
        stackTrace: stackTrace,
      );
      return _StartupStepResult<T>.fallback(
        fallbackValue,
        error: error,
        timedOut: true,
      );
    } catch (error, stackTrace) {
      _logStartup('$label done fallback=true error=$error');
      debugPrintStack(
        label: '[Splash] $label failure',
        stackTrace: stackTrace,
      );
      return _StartupStepResult<T>.fallback(
        fallbackValue,
        error: error,
        timedOut: false,
      );
    }
  }

  void _startBackgroundBootstrap({
    required User user,
    required Map<String, dynamic> existingUser,
    required Map<String, dynamic> preloadedRules,
    required bool refreshProfile,
  }) {
    if (_backgroundBootstrapQueued) {
      return;
    }

    _backgroundBootstrapQueued = true;
    unawaited(
      Future<void>(() async {
        _logStartup('background bootstrap start riderId=${user.uid}');

        try {
          Map<String, dynamic> resolvedUser = existingUser;
          if (refreshProfile) {
            final profileResult = await _runStartupStep<Map<String, dynamic>>(
              label: 'background profile fetch',
              fallbackValue: existingUser,
              action: () => _fetchExistingUserProfile(user),
            );
            resolvedUser = profileResult.value;
          }

          final configResult = await _runStartupStep<Map<String, dynamic>>(
            label: 'background config load',
            fallbackValue: preloadedRules,
            action: _loadStartupConfig,
          );

          final bootstrapResult = await _runStartupStep<bool>(
            label: 'background session bootstrap',
            fallbackValue: false,
            action: () async {
              await _bootstrapSignedInRider(
                user,
                existingUser: resolvedUser,
                preloadedRules: configResult.value,
              );
              return true;
            },
          );
          _logStartup(
            'background bootstrap done success=${bootstrapResult.succeeded}',
          );
        } catch (error, stackTrace) {
          _logStartup('background bootstrap failed error=$error');
          debugPrintStack(
            label: '[Splash] background bootstrap failure',
            stackTrace: stackTrace,
          );
        } finally {
          _backgroundBootstrapQueued = false;
        }
      }),
    );
  }

  Widget _fallbackScreenFor(User? user) {
    return user == null ? const RiderLogin() : const RideTypeScreen();
  }

  void _scheduleStartupFailSafe() {
    _startupFailSafeTimer?.cancel();
    _startupFailSafeTimer = Timer(_kStartupFailSafeTimeout, () {
      if (_hasNavigated) {
        return;
      }

      _logStartup('failsafe timeout fired');
      _navigateTo(_fallbackScreenFor(_auth.currentUser));
    });
  }

  void _setStartupState({required String message}) {
    if (!mounted || _hasNavigated) {
      return;
    }

    setState(() {
      _bootstrapping = true;
      _startupMessage = message;
    });
  }

  void _logStartup(String message) {
    debugPrint('[Splash] $message');
  }

  void _navigateTo(Widget screen) {
    if (!mounted || _hasNavigated) {
      return;
    }
    _hasNavigated = true;
    _startupFailSafeTimer?.cancel();
    Navigator.of(
      context,
    ).pushReplacement(MaterialPageRoute<void>(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: Lottie.asset(
              'assets/animations/nexride_taxi_drive.json',
              fit: BoxFit.cover,
              repeat: true,
            ),
          ),
          Positioned.fill(
            child: Container(color: Colors.black.withValues(alpha: 0.35)),
          ),
          SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    const Text(
                      'Move with NexRide',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFFD4AF37),
                        height: 1.15,
                        letterSpacing: 0.8,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Ride. Deliver. Earn.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 16,
                        color: Colors.white70,
                        letterSpacing: 1.6,
                      ),
                    ),
                    const SizedBox(height: 28),
                    if (_bootstrapping) ...<Widget>[
                      const SizedBox(
                        width: 26,
                        height: 26,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: Color(0xFFB7792B),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _startupMessage ?? 'Preparing your NexRide rider account…',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white70,
                          height: 1.45,
                        ),
                      ),
                    ] else ...<Widget>[
                      Container(
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: Column(
                          children: <Widget>[
                            const Icon(
                              Icons.error_outline_rounded,
                              color: Color(0xFFB7792B),
                              size: 34,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              kNexRideFriendlyFailureMessage,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.black87,
                                height: 1.45,
                              ),
                            ),
                            const SizedBox(height: 14),
                            FilledButton(
                              onPressed: _bootstrapStartupRoute,
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xFFB7792B),
                                foregroundColor: Colors.black,
                              ),
                              child: const Text('Retry startup'),
                            ),
                          ],
                        ),
                      ),
                    ],
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

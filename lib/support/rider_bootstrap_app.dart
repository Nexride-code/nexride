import 'dart:async';

import 'package:flutter/material.dart';

import '../nex_ride_app.dart';
import '../services/rider_android_notification_permission.dart';
import '../services/rider_push_notification_service.dart';
import '../widgets/rider_startup_error_screen.dart';
import '../widgets/rider_startup_loading_screen.dart';
import 'app_crash_guard.dart';
import 'app_startup_state.dart';
import 'rider_firebase_init.dart';

/// Boots Firebase after the first frame, then hands off to [NexRideApp].
class RiderBootstrapApp extends StatefulWidget {
  const RiderBootstrapApp({super.key});

  @override
  State<RiderBootstrapApp> createState() => _RiderBootstrapAppState();
}

class _RiderBootstrapAppState extends State<RiderBootstrapApp> {
  AppStartupState? _startupState;
  Object? _fatalError;
  StackTrace? _fatalStack;
  bool _renderLogged = false;
  int _attempt = 0;
  bool _firebaseInitStarted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_renderLogged) return;
      _renderLogged = true;
      markRiderAppRendered();
      debugPrint('APP_RENDER_BEGIN');
    });
    _startFirebaseInit();
  }

  void _startFirebaseInit() {
    if (_firebaseInitStarted) {
      return;
    }
    _firebaseInitStarted = true;
    unawaited(_initializeFirebase());
  }

  Future<void> _initializeFirebase() async {
    _attempt += 1;
    debugPrint('FIREBASE_INIT_START attempt=$_attempt');
    try {
      await RiderFirebaseInit.ensure();

      debugPrint('FIREBASE_INIT_OK');
      startupStep('firebase_init_ok');
      if (!mounted) return;
      setState(() {
        _startupState = const AppStartupState(firebaseReady: true);
        _fatalError = null;
        _fatalStack = null;
      });
      _scheduleDeferredServices();
    } catch (error, stackTrace) {
      debugPrint('FIREBASE_INIT_FAIL error=$error');
      startupError('firebase_init', error, stackTrace: stackTrace);
      if (!mounted) return;
      setState(() {
        _startupState = const AppStartupState(
          firebaseReady: false,
          safeErrorMessage:
              'Unable to connect to NexRide services right now. Please sign in again.',
        );
      });
    }
  }

  void _scheduleDeferredServices() {
    unawaited(
      RiderAndroidNotificationPermission.instance
          .ensureForFirstAppOpen()
          .catchError((Object e) {
        debugPrint('RIDER_NOTIF_PERM first_open error=$e');
        return false;
      }),
    );
    unawaited(
      RiderPushNotificationService.instance.initialize().catchError((Object e) {
        debugPrint('PUSH_INIT_FAIL error=$e');
      }),
    );
  }

  void _retryBootstrap() {
    RiderFirebaseInit.resetForRetry();
    setState(() {
      _fatalError = null;
      _fatalStack = null;
      _startupState = null;
      _firebaseInitStarted = false;
    });
    _startFirebaseInit();
  }

  @override
  Widget build(BuildContext context) {
    if (_fatalError != null) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        home: RiderStartupErrorScreen(
          error: _fatalError!,
          stackTrace: _fatalStack,
          onRetry: _retryBootstrap,
        ),
      );
    }

    final state = _startupState;
    if (state == null) {
      return const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: RiderStartupLoadingScreen(),
      );
    }

    return NexRideApp(startupState: state);
  }
}

/// Runs the bootstrap shell; use from guarded main only.
Future<void> runRiderBootstrapApp() async {
  debugPrint('RIDER_STARTUP_BEGIN');
  WidgetsFlutterBinding.ensureInitialized();
  configureRiderCrashGuard();
  startupStep('main_bindings_ready');

  runApp(const RiderBootstrapApp());
}

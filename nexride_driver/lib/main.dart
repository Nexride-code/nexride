import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'admin/admin_config.dart';
import 'admin/screens/admin_gate_screen.dart';
import 'admin/screens/admin_login_screen.dart';
import 'admin/widgets/admin_components.dart';
import 'firebase_options.dart';
import 'screens/driver_login_screen.dart';
import 'screens/driver_map_screen.dart';
import 'support/app_role.dart';
import 'support/driver_profile_bootstrap_support.dart';
import 'support/driver_profile_support.dart';
import 'support/driver_crash_guard.dart';
import 'support/driver_root_navigator.dart';
import 'support/driver_startup_coordinator.dart';
import 'support/driver_startup_logs.dart';
import 'support/driver_startup_platform.dart';
import 'services/driver_push_notification_service.dart';
import 'support/production_user_messages.dart';

Future<void> main() async {
  runDriverAppGuarded(_runDriverApp);
}

Future<void> _runDriverApp() async {
  print('APP_START');
  assert(() {
    print('APP MODE: DRIVER ONLY');
    return true;
  }());

  WidgetsFlutterBinding.ensureInitialized();
  configureDriverCrashGuard();
  driverStartupStep('main_bindings_ready');

  final startupRoute =
      WidgetsBinding.instance.platformDispatcher.defaultRouteName;
  final startupUri = Uri.base;

  _configureGlobalErrorHandling(
    startupRoute: startupRoute,
    startupUri: startupUri,
  );
  _logStartup(
    'main() starting route=$startupRoute uri=$startupUri mode=${kDebugMode ? 'debug' : 'release'}',
  );

  if (kIsWeb) {
    _logStartup(
      'Using Uri.base route resolution for web startup; skipping explicit URL strategy setup.',
    );
  }

  runApp(
    NexRideDriver(
      startupRoute: startupRoute,
      startupUri: startupUri,
      initializationFactory: () =>
          _initializeFirebase(startupRoute: startupRoute),
    ),
  );
}

Future<void> _initializeFirebase({
  required String startupRoute,
}) async {
  driverStartupLog('firebase_init_start');
  if (kIsWeb && DefaultFirebaseOptions.webAppIdLooksLikeMobileConfig) {
    _logStartup(
      'Web Firebase appId looks like a mobile config: ${DefaultFirebaseOptions.webAppId}',
    );
  }
  _logStartup(
    'Initializing Firebase for route=$startupRoute authDomain=${DefaultFirebaseOptions.webAuthDomain} databaseUrl=${DefaultFirebaseOptions.webDatabaseUrl}',
  );

  if (driverStartupIsIosSimulator) {
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(
          options: DefaultFirebaseOptions.currentPlatform,
        ).timeout(const Duration(seconds: 8));
      }
      print('FIREBASE_INIT_DONE');
      print("RUNTIME_PROJECT_ID: ${Firebase.app().options.projectId}");
      print("RUNTIME_DB_URL: ${FirebaseDatabase.instance.databaseURL}");
      print("RUNTIME_UID: ${FirebaseAuth.instance.currentUser?.uid}");
      _logStartup('Firebase initializeApp succeeded (ios simulator fast path).');
      driverStartupLog('firebase_init_done');

      if (!kIsWeb) {
        driverStartupLog('rtdb_session_start');
        try {
          FirebaseDatabase.instance.setPersistenceEnabled(true);
          FirebaseDatabase.instance.setPersistenceCacheSizeBytes(10000000);
          _logStartup('Realtime Database persistence enabled.');
        } catch (e, st) {
          debugPrint('[Startup] RTDB persistence non-fatal: $e\n$st');
        }
        driverStartupLog('rtdb_session_done');
      } else {
        driverStartupLog('rtdb_session_start');
        _logStartup('Web detected, skipping RTDB persistence setup.');
        driverStartupLog('rtdb_session_done');
      }

      driverStartupLog('fcm_token_skipped_ios_simulator');
      return;
    } catch (error, stackTrace) {
      driverStartupLog('firebase_init_fail');
      _logStartup('Firebase init failed (ios simulator fast path): $error');
      debugPrintStack(
        label: '[Startup] Firebase init stack',
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Object? lastError;
  StackTrace? lastStack;
  const attempts = 5;
  final timeoutPerAttempt =
      kIsWeb ? const Duration(seconds: 25) : const Duration(seconds: 40);

  for (var attempt = 1; attempt <= attempts; attempt++) {
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(
          options: DefaultFirebaseOptions.currentPlatform,
        ).timeout(timeoutPerAttempt);
      }
      print('FIREBASE_INIT_DONE');
      print("RUNTIME_PROJECT_ID: ${Firebase.app().options.projectId}");
      print("RUNTIME_DB_URL: ${FirebaseDatabase.instance.databaseURL}");
      print("RUNTIME_UID: ${FirebaseAuth.instance.currentUser?.uid}");
      _logStartup(
        'Firebase initializeApp succeeded (attempt=$attempt/$attempts).',
      );
      driverStartupLog('firebase_init_done');

      if (!kIsWeb) {
        driverStartupLog('rtdb_session_start');
        try {
          FirebaseDatabase.instance.setPersistenceEnabled(true);
          FirebaseDatabase.instance.setPersistenceCacheSizeBytes(10000000);
          _logStartup('Realtime Database persistence enabled.');
        } catch (e, st) {
          debugPrint('[Startup] RTDB persistence non-fatal: $e\n$st');
        }
        driverStartupLog('rtdb_session_done');
      } else {
        driverStartupLog('rtdb_session_start');
        _logStartup('Web detected, skipping RTDB persistence setup.');
        driverStartupLog('rtdb_session_done');
      }
      return;
    } catch (error, stackTrace) {
      lastError = error;
      lastStack = stackTrace;
      driverStartupLog('firebase_init_fail');
      _logStartup(
        'Firebase init attempt $attempt/$attempts failed: $error',
      );
      debugPrintStack(
        label: '[Startup] Firebase init stack',
        stackTrace: stackTrace,
      );
      if (attempt < attempts) {
        await Future<void>.delayed(Duration(seconds: attempt * 2));
      }
    }
  }

  final err = lastError ?? StateError('Firebase init exhausted retries');
  if (lastStack != null) {
    Error.throwWithStackTrace(err, lastStack);
  }
  throw err;
}

void _configureGlobalErrorHandling({
  required String startupRoute,
  required Uri startupUri,
}) {
  ErrorWidget.builder = (FlutterErrorDetails details) {
    final adminRoute = _isAdminRoute(startupUri.path) ||
        _isAdminRoute(startupRoute) ||
        _isAdminRoute(
            WidgetsBinding.instance.platformDispatcher.defaultRouteName);
    return _FatalErrorView(
      title: adminRoute
          ? 'Admin screen failed to load'
          : 'NexRide',
      message: adminRoute
          ? 'A widget error interrupted the admin interface before it could finish rendering.'
          : 'Something went wrong while building this screen. Go back if you can, or restart the app.',
      error: details.exception,
      stackTrace: details.stack,
      admin: adminRoute,
    );
  };
}

void _logStartup(String message) {
  debugPrint('[Startup] $message');
}

bool _isAdminRoute(String route) {
  final normalized = route.trim();
  if (normalized == AdminPortalRoutePaths.adminPrefix ||
      normalized.startsWith('${AdminPortalRoutePaths.adminPrefix}/')) {
    return true;
  }
  return normalized == AdminRoutePaths.admin ||
      normalized == AdminRoutePaths.adminLogin;
}

String _resolveRouteName(String? requestedRoute) {
  final routeFromPath = Uri.base.path.trim();
  final routeFromQuery = Uri.base.queryParameters['route'];
  final routeFromHash =
      Uri.base.fragment.startsWith('/') ? Uri.base.fragment : '';

  var candidate = requestedRoute ?? AdminRoutePaths.driverHome;
  if ((candidate.isEmpty || candidate == Navigator.defaultRouteName) &&
      routeFromPath.isNotEmpty &&
      routeFromPath != Navigator.defaultRouteName) {
    candidate = routeFromPath;
  }
  if ((candidate.isEmpty || candidate == Navigator.defaultRouteName) &&
      routeFromQuery != null &&
      routeFromQuery.trim().isNotEmpty) {
    candidate = routeFromQuery.trim();
  }
  if ((candidate.isEmpty || candidate == Navigator.defaultRouteName) &&
      routeFromHash.isNotEmpty) {
    candidate = routeFromHash;
  }
  if (candidate.length > 1 && candidate.endsWith('/')) {
    candidate = candidate.substring(0, candidate.length - 1);
  }
  return candidate;
}

class NexRideDriver extends StatefulWidget {
  const NexRideDriver({
    required this.startupRoute,
    required this.startupUri,
    required this.initializationFactory,
    super.key,
  });

  final String startupRoute;
  final Uri startupUri;
  final Future<void> Function() initializationFactory;

  @override
  State<NexRideDriver> createState() => _NexRideDriverState();
}

class _NexRideDriverState extends State<NexRideDriver> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      print('FIRST_FRAME_RENDERED');
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: driverRootNavigatorKey,
      debugShowCheckedModeBanner: false,
      title: 'NexRide Driver',
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: kDriverCream,
        colorScheme: ColorScheme.fromSeed(
          seedColor: kDriverGold,
          primary: kDriverGold,
          brightness: Brightness.light,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: kDriverGold,
          foregroundColor: Colors.black,
          centerTitle: true,
          elevation: 0,
          titleTextStyle: TextStyle(
            color: Colors.black,
            fontSize: 20,
            fontWeight: FontWeight.w800,
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ButtonStyle(
            backgroundColor: WidgetStateProperty.resolveWith<Color>(
              (states) => states.contains(WidgetState.disabled)
                  ? kDriverGold.withValues(alpha: 0.42)
                  : kDriverGold,
            ),
            foregroundColor: const WidgetStatePropertyAll<Color>(Colors.black),
            elevation: WidgetStateProperty.resolveWith<double>(
              (states) => states.contains(WidgetState.disabled) ? 0 : 4,
            ),
            shadowColor: WidgetStateProperty.resolveWith<Color>(
              (states) => kDriverGold.withValues(
                alpha: states.contains(WidgetState.disabled) ? 0.0 : 0.32,
              ),
            ),
            padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
              EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            ),
            shape: WidgetStatePropertyAll<RoundedRectangleBorder>(
              RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
                side: BorderSide(
                  color: const Color(0xFF8F671C).withValues(alpha: 0.9),
                ),
              ),
            ),
            textStyle: const WidgetStatePropertyAll<TextStyle>(
              TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: ButtonStyle(
            backgroundColor: WidgetStateProperty.resolveWith<Color>(
              (states) => states.contains(WidgetState.disabled)
                  ? kDriverGold.withValues(alpha: 0.42)
                  : kDriverGold,
            ),
            foregroundColor: const WidgetStatePropertyAll<Color>(Colors.black),
            padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
              EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            ),
            shape: WidgetStatePropertyAll<RoundedRectangleBorder>(
              RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
                side: BorderSide(
                  color: const Color(0xFF8F671C).withValues(alpha: 0.9),
                ),
              ),
            ),
            textStyle: const WidgetStatePropertyAll<TextStyle>(
              TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ),
      ),
      onGenerateRoute: (RouteSettings settings) {
        final requestedRoute = settings.name;
        final resolvedRoute = _resolveRouteName(requestedRoute);
        _logStartup(
          'onGenerateRoute requested=${requestedRoute ?? '(null)'} resolved=$resolvedRoute uri=${widget.startupUri}',
        );

        switch (resolvedRoute) {
          case AdminRoutePaths.admin:
            return MaterialPageRoute<void>(
              builder: (_) => _AppBootstrapRoute(
                initializationFactory: widget.initializationFactory,
                routeName: resolvedRoute,
                adminRoute: true,
                child: const AdminGateScreen(),
              ),
              settings: settings,
            );
          case AdminRoutePaths.adminLogin:
            return MaterialPageRoute<void>(
              builder: (_) => _AppBootstrapRoute(
                initializationFactory: widget.initializationFactory,
                routeName: resolvedRoute,
                adminRoute: true,
                child: AdminLoginScreen(
                  key: ValueKey<String?>(
                    adminLoginBannerFromArguments(settings.arguments),
                  ),
                  inlineMessage:
                      adminLoginBannerFromArguments(settings.arguments),
                ),
              ),
              settings: settings,
            );
          case AdminRoutePaths.driverHome:
            return MaterialPageRoute<void>(
              builder: (_) => _AppBootstrapRoute(
                initializationFactory: widget.initializationFactory,
                routeName: resolvedRoute,
                child: const AuthGate(),
              ),
              settings: settings,
            );
          default:
            return MaterialPageRoute<void>(
              builder: (_) => _UnknownRouteScreen(
                requestedRoute: resolvedRoute,
              ),
              settings: settings,
            );
        }
      },
    );
  }
}

class _AppBootstrapRoute extends StatefulWidget {
  const _AppBootstrapRoute({
    required this.initializationFactory,
    required this.routeName,
    required this.child,
    this.adminRoute = false,
  });

  final Future<void> Function() initializationFactory;
  final String routeName;
  final Widget child;
  final bool adminRoute;

  @override
  State<_AppBootstrapRoute> createState() => _AppBootstrapRouteState();
}

class _AppBootstrapRouteState extends State<_AppBootstrapRoute> {
  late Future<void> _bootstrapFuture;

  @override
  void initState() {
    super.initState();
    _bootstrapFuture = _runBootstrapShell();
  }

  Future<void> _runBootstrapShell() async {
    final Future<void> init = widget.initializationFactory();
    if (!driverStartupIsIosSimulator) {
      await init;
      return;
    }
    await init.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        driverStartupLog('bootstrap_shell_timeout');
        if (Firebase.apps.isEmpty) {
          throw TimeoutException('firebase_init_not_complete_sim_bootstrap');
        }
        DriverStartupCoordinator.instance.markDegradedSessionData(
          reason: 'bootstrap_shell_timeout',
        );
      },
    );
  }

  void _retryBootstrap() {
    setState(() {
      _bootstrapFuture = _runBootstrapShell();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _bootstrapFuture,
      builder: (
        BuildContext context,
        AsyncSnapshot<void> snapshot,
      ) {
        if (snapshot.connectionState != ConnectionState.done) {
          _logStartup('Bootstrap waiting route=${widget.routeName}');
          return widget.adminRoute
              ? const AdminFullscreenState(
                  title: 'Loading NexRide admin',
                  message:
                      'Starting Firebase, restoring auth state, and preparing the admin control center.',
                  icon: Icons.admin_panel_settings_outlined,
                  isLoading: true,
                )
              : const _BootstrapStatusScreen(
                  title: 'NexRide Driver',
                  message: 'Connecting… This can take longer on a weak signal.',
                  loading: true,
                );
        }

        if (snapshot.hasError) {
          _logStartup(
            'Bootstrap error on route=${widget.routeName} error=${snapshot.error}',
          );
          debugPrint(
            '[Startup] Firebase bootstrap error route=${widget.routeName} err=${snapshot.error}',
          );
          if (snapshot.stackTrace != null) {
            debugPrintStack(
              label: '[Startup] Firebase bootstrap stack',
              stackTrace: snapshot.stackTrace,
            );
          }
          return _FatalErrorView(
            title: widget.adminRoute
                ? 'Admin screen failed to load'
                : 'NexRide',
            message: widget.adminRoute
                ? 'Firebase startup failed before the admin route could render.'
                : kDriverBootstrapAfterRetriesMessage,
            error: snapshot.error ??
                StateError('Unknown bootstrap error on ${widget.routeName}'),
            stackTrace: snapshot.stackTrace,
            admin: widget.adminRoute,
            onRetry: widget.adminRoute ? null : _retryBootstrap,
          );
        }

        _logStartup('Bootstrap ready route=${widget.routeName}');
        return widget.child;
      },
    );
  }
}

class _FatalErrorView extends StatelessWidget {
  const _FatalErrorView({
    required this.title,
    required this.message,
    required this.error,
    this.stackTrace,
    this.admin = false,
    this.onRetry,
  });

  final String title;
  final String message;
  final Object error;
  final StackTrace? stackTrace;
  final bool admin;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    if (admin) {
      return AdminFullscreenState(
        title: title,
        message: message,
        error: error,
        stackTrace: stackTrace,
        icon: Icons.error_outline_rounded,
      );
    }
    return _BootstrapStatusScreen(
      title: title,
      message: message,
      error: error,
      stackTrace: stackTrace,
      onRetry: onRetry,
    );
  }
}

class _BootstrapStatusScreen extends StatelessWidget {
  const _BootstrapStatusScreen({
    required this.title,
    required this.message,
    this.error,
    this.stackTrace,
    this.loading = false,
    this.onRetry,
  });

  final String title;
  final String message;
  final Object? error;
  final StackTrace? stackTrace;
  final bool loading;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kDriverCream,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    if (loading)
                      const CircularProgressIndicator(color: kDriverGold)
                    else
                      const Icon(
                        Icons.warning_amber_rounded,
                        color: kDriverGold,
                        size: 36,
                      ),
                    const SizedBox(height: 18),
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.black,
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      message,
                      style: const TextStyle(
                        color: Colors.black87,
                        height: 1.5,
                      ),
                    ),
                    if (!loading && onRetry != null) ...<Widget>[
                      const SizedBox(height: 22),
                      FilledButton(
                        onPressed: onRetry,
                        child: const Text('Try again'),
                      ),
                    ],
                    if (error != null && kDebugMode) ...<Widget>[
                      const SizedBox(height: 16),
                      SelectableText(
                        error.toString(),
                        style: const TextStyle(
                          color: Colors.black,
                          fontSize: 13,
                          height: 1.5,
                        ),
                      ),
                    ],
                    if (kDebugMode &&
                        stackTrace != null &&
                        stackTrace.toString().trim().isNotEmpty) ...<Widget>[
                      const SizedBox(height: 16),
                      SelectableText(
                        stackTrace.toString(),
                        style: const TextStyle(
                          color: Colors.black87,
                          fontSize: 12,
                          height: 1.45,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _UnknownRouteScreen extends StatelessWidget {
  const _UnknownRouteScreen({
    required this.requestedRoute,
  });

  final String requestedRoute;

  @override
  Widget build(BuildContext context) {
    final adminRoute = _isAdminRoute(requestedRoute);
    if (adminRoute) {
      return AdminFullscreenState(
        title: 'Admin screen failed to load',
        message:
            'The requested admin route "$requestedRoute" is not registered in the app router.',
        error: StateError('Unknown admin route: $requestedRoute'),
        icon: Icons.route_outlined,
      );
    }
    return _BootstrapStatusScreen(
      title: 'Unknown route',
      message: 'The requested route "$requestedRoute" is not registered.',
      error: StateError('Unknown route: $requestedRoute'),
    );
  }
}

class DriverProfileData {
  const DriverProfileData({
    required this.driverId,
    required this.driverName,
    required this.car,
    required this.plate,
  });

  final String driverId;
  final String driverName;
  final String car;
  final String plate;

  factory DriverProfileData.fromMap(
      String driverId, Map<String, dynamic> data) {
    return DriverProfileData(
      driverId: driverId,
      driverName: (data['name']?.toString().trim().isNotEmpty ?? false)
          ? data['name'].toString().trim()
          : 'Driver',
      car: data['car']?.toString().trim() ?? '',
      plate: data['plate']?.toString().trim() ?? '',
    );
  }
}

class _DriverProfileSyncFailure implements Exception {
  const _DriverProfileSyncFailure({
    required this.debugReason,
    required this.userMessage,
  });

  final String debugReason;
  final String userMessage;

  @override
  String toString() => debugReason;
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

enum _AuthGateStage {
  checkingSession,
  signInRequired,
  bootstrapping,
  ready,
  failed,
}

class _AuthGateState extends State<AuthGate> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final DatabaseReference _rootRef = FirebaseDatabase.instance.ref();

  StreamSubscription<User?>? _authSubscription;
  Timer? _authStuckGuardTimer;
  bool _authStateDoneLogged = false;
  DriverProfileData? _profile;
  _AuthGateStage _stage = _AuthGateStage.checkingSession;
  String? _statusMessage;
  String? _profileSyncIssueMessage;
  User? _currentUser;
  int _bootstrapAttempt = 0;
  /// Bumps on every auth event so overlapping async work can bail safely.
  int _authGateGeneration = 0;
  String _debugStep = 'waiting for auth state';

  void _setDebugStep(String step) {
    if (_debugStep == step) {
      return;
    }
    if (mounted) {
      setState(() {
        _debugStep = step;
      });
      return;
    }
    _debugStep = step;
  }

  void _logAuthStateDoneOnce(String via) {
    if (_authStateDoneLogged) {
      return;
    }
    _authStateDoneLogged = true;
    driverStartupLog('auth_state_done via=$via');
    driverStartupStep('auth_restored', fields: {'via': via});
  }

  @override
  void initState() {
    super.initState();
    driverStartupLog('auth_state_start');
    if (driverStartupIsIosSimulator) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        final User? user = FirebaseAuth.instance.currentUser;
        driverStartupLog('auth_state_fast_path uid=${user?.uid ?? 'none'}');
        unawaited(_handleAuthStateChanged(user));
      });
      _authStuckGuardTimer = Timer(const Duration(seconds: 8), () {
        if (!mounted) {
          return;
        }
        if (_stage != _AuthGateStage.checkingSession) {
          return;
        }
        final User? user = FirebaseAuth.instance.currentUser;
        driverStartupLog('auth_state_stuck_guard uid=${user?.uid ?? 'none'}');
        if (user == null) {
          setState(() {
            _stage = _AuthGateStage.signInRequired;
            _statusMessage = null;
            _profileSyncIssueMessage = null;
            _profile = null;
          });
          _setDebugStep('sign in required (stuck guard)');
          _logAuthStateDoneOnce('stuck_guard_signed_out');
          return;
        }
        unawaited(_handleAuthStateChanged(user));
        _logAuthStateDoneOnce('stuck_guard_signed_in');
      });
    }
    _authSubscription = _auth.authStateChanges().listen(
      (User? user) {
        unawaited(_handleAuthStateChanged(user));
      },
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('[AuthGate] auth stream error=$error');
        debugPrintStack(
          label: '[AuthGate] auth stream stack',
          stackTrace: stackTrace,
        );
        _setDebugStep('auth state error');
        if (!mounted) {
          return;
        }
        setState(() {
          _stage = _AuthGateStage.failed;
          _statusMessage =
              'We could not restore your driver session. Please try again.';
          _profileSyncIssueMessage = null;
          _profile = null;
        });
      },
    );
  }

  Future<void> _handleAuthStateChanged(User? user) async {
    debugPrint(
      '[AuthGate] auth state restored user=${user?.uid ?? 'none'}',
    );
    _currentUser = user;
    final int gate = ++_authGateGeneration;

    if (user == null) {
      if (!mounted) {
        return;
      }
      setState(() {
        _stage = _AuthGateStage.signInRequired;
        _statusMessage = null;
        _profileSyncIssueMessage = null;
        _profile = null;
      });
      _setDebugStep('sign in required');
      _logAuthStateDoneOnce('signed_out');
      return;
    }

    // Duplicate auth emissions (same uid) while already on the map: refresh
    // push token only — do not re-run bootstrap or remount the map.
    if (_stage == _AuthGateStage.ready &&
        _profile?.driverId == user.uid &&
        _auth.currentUser?.uid == user.uid) {
      _setDebugStep('auth refresh (map already ready)');
      unawaited(DriverPushNotificationService.instance.registerCurrentUserToken());
      return;
    }

    if (!mounted || gate != _authGateGeneration) {
      return;
    }
    _logAuthStateDoneOnce('session_resolved');
    setState(() {
      _stage = _AuthGateStage.bootstrapping;
      _statusMessage =
          'Loading your profile and preparing the driver map. This is slower on first login.';
      _profileSyncIssueMessage = null;
    });
    _setDebugStep('driver bootstrap queued');

    try {
      await _bootstrapDriverSession(user, gate: gate);
    } catch (error, stackTrace) {
      debugPrint('[AuthGate] unexpected bootstrap failure error=$error');
      debugPrintStack(
        label: '[AuthGate] unexpected bootstrap stack',
        stackTrace: stackTrace,
      );
      if (!mounted || gate != _authGateGeneration) {
        return;
      }
      setState(() {
        _stage = _AuthGateStage.failed;
        _statusMessage =
            'We could not finish loading your driver workspace. Check your connection and tap Retry.';
        _profileSyncIssueMessage = null;
        _profile = _profile ?? _buildFallbackProfile(user);
      });
      _setDebugStep('bootstrap unexpected failure');
    }
  }

  Future<void> _bootstrapDriverSession(User user, {required int gate}) async {
    driverStartupLog('driver_profile_start');
    driverStartupLog('rtdb_session_start');
    final attempt = ++_bootstrapAttempt;
    debugPrint(
        '[AuthGate] driver bootstrap start uid=${user.uid} attempt=$attempt gate=$gate');
    _setDebugStep('loading driver profile');

    try {
      final profile = await _loadDriverProfile(user);

      if (!mounted ||
          attempt != _bootstrapAttempt ||
          gate != _authGateGeneration ||
          _auth.currentUser?.uid != user.uid) {
        return;
      }

      debugPrint(
        '[AuthGate] driver bootstrap loaded uid=${profile.driverId} name=${profile.driverName} car=${profile.car} plate=${profile.plate}',
      );
      _setDebugStep('driver profile ready');

      setState(() {
        _profile = profile;
        _stage = _AuthGateStage.ready;
        _statusMessage = null;
        _profileSyncIssueMessage = null;
      });
      driverStartupStep('startup_ready', fields: {'uid': profile.driverId});
    } on _DriverProfileSyncFailure catch (error) {
      driverStartupLog('driver_profile_fail reason=${error.debugReason}');
      driverStartupLog('rtdb_session_done');
      debugPrint(
        '[AuthGate] driver bootstrap recovered with fallback uid=${user.uid} reason=${error.debugReason}',
      );
      _setDebugStep(
        error.debugReason.contains('timeout')
            ? 'driver profile timeout'
            : 'driver profile failed',
      );
      if (!mounted ||
          attempt != _bootstrapAttempt ||
          gate != _authGateGeneration ||
          _auth.currentUser?.uid != user.uid) {
        return;
      }
      setState(() {
        _profile = _profile ?? _buildFallbackProfile(user);
        _stage = _AuthGateStage.ready;
        _statusMessage = null;
        _profileSyncIssueMessage = error.userMessage;
      });
      driverStartupStep('startup_ready_fallback', fields: {'uid': user.uid});
    } catch (error, stackTrace) {
      driverStartupLog('driver_profile_fail reason=$error');
      driverStartupLog('rtdb_session_done');
      debugPrint(
          '[AuthGate] driver bootstrap failed uid=${user.uid} error=$error');
      debugPrintStack(
        label: '[AuthGate] driver bootstrap stack',
        stackTrace: stackTrace,
      );
      _setDebugStep('driver profile failed');
      if (!mounted ||
          attempt != _bootstrapAttempt ||
          gate != _authGateGeneration ||
          _auth.currentUser?.uid != user.uid) {
        return;
      }
      setState(() {
        _profile = _profile ?? _buildFallbackProfile(user);
        _stage = _AuthGateStage.ready;
        _statusMessage = null;
        _profileSyncIssueMessage =
            'We could not refresh your driver profile right now. The map is open, and you can retry in a moment.';
      });
      driverStartupStep('startup_ready_degraded', fields: {'uid': user.uid});
    }
  }

  Future<DriverProfileData> _loadDriverProfile(User user) async {
    final path = driverProfilePath(user.uid);
    final int maxAttempts = driverStartupIsIosSimulator ? 1 : 2;
    final Duration authGateBudget = driverStartupIsIosSimulator
        ? const Duration(seconds: 8)
        : const Duration(seconds: 22);

    for (var attempt = 1; attempt <= maxAttempts; attempt += 1) {
      try {
        debugPrint(
          '[AuthGate] driver profile fetch started uid=${user.uid} attempt=$attempt path=$path timeout=${authGateBudget.inSeconds}s',
        );
        final result = await fetchDriverProfileRecord(
          rootRef: _rootRef,
          user: user,
          source: 'auth_gate_attempt_$attempt',
          role: AppRole.driver,
          createIfMissing: true,
        ).timeout(authGateBudget);

        debugPrint(
          '[AuthGate] driver profile fetch resolved uid=${user.uid} attempt=$attempt path=${result.path} found=${result.snapshotFound} createdFallback=${result.createdFallbackProfile} uidMatches=${result.uidMatchesRecord} parseWarning=${result.parseWarning ?? 'none'} readError=${result.readError ?? 'none'} persistWarning=${result.persistWarning ?? 'none'}',
        );
        driverStartupLog('rtdb_session_done');
        driverStartupLog('driver_profile_done');
        return DriverProfileData.fromMap(user.uid, result.profile);
      } on TimeoutException catch (error, stackTrace) {
        driverStartupLog('driver_profile_fail reason=timeout');
        debugPrint(
          '[AuthGate] driver profile timeout uid=${user.uid} attempt=$attempt path=$path reason=exceeded_auth_gate_budget_s',
        );
        debugPrintStack(
          label: '[AuthGate] driver profile timeout stack',
          stackTrace: stackTrace,
        );
        if (attempt == 1 && attempt < maxAttempts) {
          _setDebugStep('retrying driver profile');
          continue;
        }
        throw _DriverProfileSyncFailure(
          debugReason:
              'driver profile timeout path=$path attempts=$attempt error=$error',
          userMessage:
              'We could not refresh your driver profile right now. The map is open, and you can retry in a moment.',
        );
      } catch (error, stackTrace) {
        driverStartupLog('driver_profile_fail reason=$error');
        debugPrint(
          '[AuthGate] driver profile fetch failed uid=${user.uid} attempt=$attempt path=$path error=$error',
        );
        debugPrintStack(
          label: '[AuthGate] driver profile fetch stack',
          stackTrace: stackTrace,
        );
        throw _DriverProfileSyncFailure(
          debugReason: 'driver profile failed path=$path error=$error',
          userMessage:
              'We could not refresh your driver profile right now. The map is open, and you can retry in a moment.',
        );
      }
    }

    throw _DriverProfileSyncFailure(
      debugReason: 'driver profile failed path=$path error=unexpected_exit',
      userMessage:
          'We could not refresh your driver profile right now. The map is open, and you can retry in a moment.',
    );
  }

  DriverProfileData _buildFallbackProfile(User user) {
    final fallbackProfile = buildDriverProfileRecord(
      driverId: user.uid,
      existing: const <String, dynamic>{},
      fallbackName: user.displayName ?? user.email?.split('@').first,
      fallbackEmail: user.email,
      fallbackPhone: user.phoneNumber,
    );
    return DriverProfileData.fromMap(user.uid, fallbackProfile);
  }

  Future<void> _retryBootstrap() async {
    final user = _currentUser ?? _auth.currentUser;
    if (user == null) {
      if (!mounted) {
        return;
      }
      setState(() {
        _stage = _AuthGateStage.signInRequired;
        _statusMessage = null;
        _profileSyncIssueMessage = null;
      });
      _setDebugStep('sign in required');
      return;
    }
    final int gate = ++_authGateGeneration;
    if (mounted) {
      setState(() {
        _stage = _AuthGateStage.bootstrapping;
        _statusMessage = 'Refreshing your driver profile…';
        _profileSyncIssueMessage = null;
        _profile = _profile?.driverId == user.uid
            ? _profile
            : _buildFallbackProfile(user);
      });
    }
    _setDebugStep('retrying driver profile');
    await _bootstrapDriverSession(user, gate: gate);
  }

  @override
  void dispose() {
    _authStuckGuardTimer?.cancel();
    _authSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    switch (_stage) {
      case _AuthGateStage.signInRequired:
        return const DriverLoginScreen();
      case _AuthGateStage.ready:
        final profile = _profile;
        if (profile == null) {
          return _StartupStatusView(
            title: 'Loading your driver workspace',
            message: _statusMessage ?? 'Please wait a moment.',
            loading: true,
          );
        }
        return DriverMapScreen(
          driverId: profile.driverId,
          driverName: profile.driverName,
          car: profile.car,
          plate: profile.plate,
          profileSyncIssueMessage: _profileSyncIssueMessage,
          onRetryProfileSync: _retryBootstrap,
        );
      case _AuthGateStage.failed:
        return _StartupStatusView(
          title: 'Driver map still loading',
          message: _statusMessage ??
              'We need a little more time to prepare the driver map.',
          loading: false,
          actionLabel: 'Retry',
          onAction: _retryBootstrap,
        );
      case _AuthGateStage.checkingSession:
      case _AuthGateStage.bootstrapping:
        return _StartupStatusView(
          title: 'Loading your driver workspace',
          message: _statusMessage ??
              'Restoring your session and preparing the driver map.',
          loading: true,
        );
    }
  }
}

class _StartupStatusView extends StatelessWidget {
  const _StartupStatusView({
    required this.title,
    required this.message,
    required this.loading,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String message;
  final bool loading;
  final String? actionLabel;
  final Future<void> Function()? onAction;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kDriverCream,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Container(
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: const <BoxShadow>[
                    BoxShadow(
                      color: Color(0x14000000),
                      blurRadius: 24,
                      offset: Offset(0, 16),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: kDriverGold.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Icon(
                        Icons.directions_car_filled_rounded,
                        color: kDriverGold,
                        size: 30,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      message,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.black.withValues(alpha: 0.64),
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 22),
                    if (loading)
                      const CircularProgressIndicator(color: kDriverGold)
                    else
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: onAction == null
                              ? null
                              : () {
                                  unawaited(onAction!.call());
                                },
                          child: Text(actionLabel ?? 'Continue'),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../firebase_options.dart';
import 'admin_config.dart';
import 'screens/admin_gate_screen.dart';
import 'services/admin_auth_service.dart';
import 'services/admin_data_service.dart';
import 'widgets/admin_components.dart';

final ValueNotifier<_AdminFatalError?> _fatalAdminError =
    ValueNotifier<_AdminFatalError?>(null);

void logAdminStartup(String message) {
  debugPrint('[AdminApp] $message');
}

void configureAdminErrorHandling({
  required Uri startupUri,
}) {
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    logAdminStartup('FlutterError caught: ${details.exception}');
    if (details.stack != null) {
      debugPrintStack(
        label: '[AdminApp] FlutterError stack',
        stackTrace: details.stack,
      );
    }
    _fatalAdminError.value = _AdminFatalError(
      phase: 'flutter_error',
      error: details.exception,
      stackTrace: details.stack,
    );
  };

  PlatformDispatcher.instance.onError = (
    Object error,
    StackTrace stackTrace,
  ) {
    logAdminStartup('PlatformDispatcher caught: $error');
    debugPrintStack(
      label: '[AdminApp] PlatformDispatcher stack',
      stackTrace: stackTrace,
    );
    _fatalAdminError.value = _AdminFatalError(
      phase: 'platform_dispatcher',
      error: error,
      stackTrace: stackTrace,
    );
    return true;
  };

  ErrorWidget.builder = (FlutterErrorDetails details) {
    return AdminFullscreenState(
      title: 'Admin screen failed to load',
      message:
          'A widget error interrupted NexRide Admin before the current page could finish rendering.',
      error: details.exception,
      stackTrace: details.stack,
      icon: Icons.error_outline_rounded,
    );
  };

  logAdminStartup('Error handling configured for $startupUri');
}

Future<void> initializeAdminFirebase() async {
  try {
    if (kIsWeb && DefaultFirebaseOptions.webAppIdLooksLikeMobileConfig) {
      logAdminStartup(
        'Web Firebase appId looks like a mobile config: ${DefaultFirebaseOptions.webAppId}',
      );
    }
    logAdminStartup(
      'Initializing Firebase authDomain=${DefaultFirebaseOptions.webAuthDomain} databaseUrl=${DefaultFirebaseOptions.webDatabaseUrl}',
    );
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    logAdminStartup('Firebase initializeApp succeeded for admin.');
  } catch (error, stackTrace) {
    logAdminStartup('Firebase initializeApp failed for admin: $error');
    _fatalAdminError.value = _AdminFatalError(
      phase: 'firebase_initialize',
      error: error,
      stackTrace: stackTrace,
    );
    rethrow;
  }
}

class AdminApp extends StatelessWidget {
  const AdminApp({
    required this.initialization,
    required this.startupUri,
    super.key,
    this.authService,
    this.dataService,
  });

  final Future<void> initialization;
  final Uri startupUri;
  final AdminAuthService? authService;
  final AdminDataService? dataService;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'NexRide Admin',
      initialRoute: AdminPortalRoutePaths.login,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: AdminThemeTokens.canvas,
        colorScheme: ColorScheme.fromSeed(
          seedColor: AdminThemeTokens.gold,
          primary: AdminThemeTokens.gold,
          brightness: Brightness.light,
          surface: Colors.white,
        ),
        fontFamily: 'Segoe UI',
      ),
      onGenerateRoute: (RouteSettings settings) {
        final effectiveUri = kIsWeb ? Uri.base : startupUri;
        final resolvedRoute = _resolveAdminRoute(
          settings.name,
          startupUri: effectiveUri,
        );
        logAdminStartup(
          'onGenerateRoute requested=${settings.name ?? '(null)'} resolved=$resolvedRoute uri=$effectiveUri',
        );

        if (resolvedRoute == AdminPortalRoutePaths.login) {
          return _buildAdminRoute(
            routeName: resolvedRoute,
            child: AdminGateScreen(
              mode: AdminGateMode.login,
              authService: authService,
              dataService: dataService,
              inlineMessage: settings.arguments?.toString(),
              loginRoute: AdminPortalRoutePaths.login,
              dashboardRoute: AdminPortalRoutePaths.dashboard,
              routeForSection: AdminPortalRoutePaths.pathForSection,
            ),
          );
        }

        if (resolvedRoute == AdminPortalRoutePaths.root ||
            AdminPortalRoutePaths.isProtectedRoute(resolvedRoute)) {
          return _buildAdminRoute(
            routeName: resolvedRoute,
            child: AdminGateScreen(
              mode: AdminGateMode.dashboard,
              authService: authService,
              dataService: dataService,
              initialSection:
                  AdminPortalRoutePaths.sectionForPath(resolvedRoute),
              loginRoute: AdminPortalRoutePaths.login,
              dashboardRoute: AdminPortalRoutePaths.dashboard,
              routeForSection: AdminPortalRoutePaths.pathForSection,
            ),
          );
        }

        return _buildAdminRoute(
          routeName: AdminPortalRoutePaths.login,
          child: AdminGateScreen(
            mode: AdminGateMode.login,
            authService: authService,
            dataService: dataService,
            loginRoute: AdminPortalRoutePaths.login,
            dashboardRoute: AdminPortalRoutePaths.dashboard,
            routeForSection: AdminPortalRoutePaths.pathForSection,
          ),
        );
      },
      onUnknownRoute: (RouteSettings settings) => _buildAdminRoute(
        routeName: AdminPortalRoutePaths.login,
        child: AdminGateScreen(
          mode: AdminGateMode.login,
          authService: authService,
          dataService: dataService,
          loginRoute: AdminPortalRoutePaths.login,
          dashboardRoute: AdminPortalRoutePaths.dashboard,
          routeForSection: AdminPortalRoutePaths.pathForSection,
        ),
      ),
    );
  }

  MaterialPageRoute<void> _buildAdminRoute({
    required String routeName,
    required Widget child,
  }) {
    return MaterialPageRoute<void>(
      builder: (_) => _AdminBootstrapRoute(
        initialization: initialization,
        routeName: routeName,
        child: child,
      ),
      settings: RouteSettings(name: routeName),
    );
  }
}

String _resolveAdminRoute(
  String? requestedRoute, {
  required Uri startupUri,
}) {
  final routeFromPath = AdminPortalRoutePaths.normalize(startupUri.path);
  final normalizedRequested = AdminPortalRoutePaths.normalize(
    requestedRoute ?? AdminPortalRoutePaths.login,
  );

  final shouldPreferStartupUri = requestedRoute == null ||
      normalizedRequested == AdminPortalRoutePaths.root ||
      normalizedRequested == AdminPortalRoutePaths.login;

  if (!shouldPreferStartupUri) {
    return normalizedRequested;
  }

  if (routeFromPath != AdminPortalRoutePaths.root) {
    return routeFromPath;
  }

  return normalizedRequested;
}

class _AdminBootstrapRoute extends StatelessWidget {
  const _AdminBootstrapRoute({
    required this.initialization,
    required this.routeName,
    required this.child,
  });

  final Future<void> initialization;
  final String routeName;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<_AdminFatalError?>(
      valueListenable: _fatalAdminError,
      builder: (
        BuildContext context,
        _AdminFatalError? fatalError,
        Widget? _,
      ) {
        if (fatalError != null) {
          return AdminFullscreenState(
            title: 'Admin screen failed to load',
            message:
                'NexRide Admin hit a startup error before the current route could finish loading.',
            error: fatalError.error,
            stackTrace: fatalError.stackTrace,
            icon: Icons.error_outline_rounded,
          );
        }

        return FutureBuilder<void>(
          future: initialization,
          builder: (
            BuildContext context,
            AsyncSnapshot<void> snapshot,
          ) {
            if (snapshot.connectionState != ConnectionState.done) {
              logAdminStartup('Bootstrap waiting route=$routeName');
              return const AdminFullscreenState(
                title: 'Loading NexRide Admin',
                message:
                    'Starting Firebase and restoring NexRide admin authentication.',
                icon: Icons.admin_panel_settings_outlined,
                isLoading: true,
              );
            }

            if (snapshot.hasError) {
              logAdminStartup(
                'Bootstrap failed route=$routeName error=${snapshot.error}',
              );
              return AdminFullscreenState(
                title: 'Admin screen failed to load',
                message:
                    'Firebase startup failed before NexRide Admin could finish rendering.',
                error: snapshot.error ??
                    StateError('Unknown admin bootstrap error'),
                stackTrace: snapshot.stackTrace,
                icon: Icons.error_outline_rounded,
              );
            }

            logAdminStartup('Bootstrap ready route=$routeName');
            return child;
          },
        );
      },
    );
  }
}

class _AdminFatalError {
  const _AdminFatalError({
    required this.phase,
    required this.error,
    this.stackTrace,
  });

  final String phase;
  final Object error;
  final StackTrace? stackTrace;
}

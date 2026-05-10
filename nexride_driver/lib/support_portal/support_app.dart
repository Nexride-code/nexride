import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../firebase_options.dart';
import '../portal_security/portal_account_security_screen.dart';
import '../portal_security/portal_change_password_screen.dart';
import 'models/support_models.dart';
import 'screens/support_gate_screen.dart';
import 'support_config.dart';
import '../admin/widgets/admin_components.dart';

final ValueNotifier<_SupportFatalError?> _fatalSupportError =
    ValueNotifier<_SupportFatalError?>(null);

void configureSupportErrorHandling({
  required Uri startupUri,
}) {
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    _fatalSupportError.value = _SupportFatalError(
      phase: 'flutter_error',
      error: details.exception,
      stackTrace: details.stack,
    );
  };

  PlatformDispatcher.instance.onError = (
    Object error,
    StackTrace stackTrace,
  ) {
    _fatalSupportError.value = _SupportFatalError(
      phase: 'platform_dispatcher',
      error: error,
      stackTrace: stackTrace,
    );
    return true;
  };

  ErrorWidget.builder = (FlutterErrorDetails details) {
    return AdminFullscreenState(
      title: 'Support portal failed to load',
      message:
          'A widget error interrupted NexRide Support before the current page could finish rendering.',
      error: details.exception,
      stackTrace: details.stack,
      icon: Icons.error_outline_rounded,
    );
  };
}

Future<void> initializeSupportFirebase() async {
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
}

class SupportApp extends StatelessWidget {
  const SupportApp({
    required this.initialization,
    required this.startupUri,
    super.key,
  });

  final Future<void> initialization;
  final Uri startupUri;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'NexRide Support',
      initialRoute: SupportRoutePaths.login,
      theme: SupportThemeTokens.buildTheme(),
      onGenerateRoute: (RouteSettings settings) {
        final effectiveUri = kIsWeb ? Uri.base : startupUri;
        final resolution = SupportRoutePaths.resolve(
          settings.name,
          startupUri: effectiveUri,
        );

        if (resolution.routePath == SupportRoutePaths.login) {
          return _buildLoginRoute(
            routeName: resolution.routePath,
            inlineMessage: settings.arguments?.toString(),
            initialView: resolution.initialView,
            initialTicketDocumentId: resolution.ticketDocumentId,
          );
        }

        if (resolution.routePath == SupportRoutePaths.changePassword) {
          return _buildRoute(
            routeName: resolution.routePath,
            child: const PortalChangePasswordScreen(
              theme: SupportThemeTokens.portalSecurityTheme,
              loginRoute: SupportRoutePaths.login,
              successRoute: SupportRoutePaths.accountSecurity,
            ),
          );
        }

        if (resolution.routePath == SupportRoutePaths.accountSecurity) {
          return _buildRoute(
            routeName: resolution.routePath,
            child: const PortalAccountSecurityScreen(
              theme: SupportThemeTokens.portalSecurityTheme,
              changePasswordRoute: SupportRoutePaths.changePassword,
              loginRoute: SupportRoutePaths.login,
            ),
          );
        }

        if (SupportRoutePaths.isProtectedRoute(resolution.routePath)) {
          return _buildDashboardRoute(
            routeName: resolution.routePath,
            initialView: resolution.initialView,
            initialTicketDocumentId: resolution.ticketDocumentId,
          );
        }

        return _buildLoginRoute(
          routeName: SupportRoutePaths.login,
          initialView: SupportInboxView.dashboard,
        );
      },
      onUnknownRoute: (RouteSettings settings) => _buildLoginRoute(
        routeName: SupportRoutePaths.login,
        initialView: SupportInboxView.dashboard,
      ),
    );
  }

  MaterialPageRoute<void> _buildLoginRoute({
    required String routeName,
    String? inlineMessage,
    required SupportInboxView initialView,
    String? initialTicketDocumentId,
  }) {
    return _buildRoute(
      routeName: routeName,
      child: SupportGateScreen(
        mode: SupportGateMode.login,
        loginRoute: SupportRoutePaths.login,
        dashboardRoute: SupportRoutePaths.dashboard,
        inlineMessage: inlineMessage,
        initialView: initialView,
        initialTicketDocumentId: initialTicketDocumentId,
        routeForView: SupportRoutePaths.pathForView,
        routeForTicket: SupportRoutePaths.ticketPath,
      ),
    );
  }

  MaterialPageRoute<void> _buildDashboardRoute({
    required String routeName,
    required SupportInboxView initialView,
    String? initialTicketDocumentId,
  }) {
    return _buildRoute(
      routeName: routeName,
      child: SupportGateScreen(
        mode: SupportGateMode.dashboard,
        loginRoute: SupportRoutePaths.login,
        dashboardRoute: SupportRoutePaths.dashboard,
        initialView: initialView,
        initialTicketDocumentId: initialTicketDocumentId,
        routeForView: SupportRoutePaths.pathForView,
        routeForTicket: SupportRoutePaths.ticketPath,
      ),
    );
  }

  MaterialPageRoute<void> _buildRoute({
    required String routeName,
    required Widget child,
  }) {
    return MaterialPageRoute<void>(
      builder: (_) => _SupportBootstrapRoute(
        initialization: initialization,
        routeName: routeName,
        child: child,
      ),
      settings: RouteSettings(name: routeName),
    );
  }
}

class _SupportBootstrapRoute extends StatelessWidget {
  const _SupportBootstrapRoute({
    required this.initialization,
    required this.routeName,
    required this.child,
  });

  final Future<void> initialization;
  final String routeName;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<_SupportFatalError?>(
      valueListenable: _fatalSupportError,
      builder: (
        BuildContext context,
        _SupportFatalError? fatalError,
        Widget? _,
      ) {
        if (fatalError != null) {
          return AdminFullscreenState(
            title: 'Support portal failed to load',
            message:
                'NexRide Support hit a startup error before the current route could finish loading.',
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
              return const AdminFullscreenState(
                title: 'Loading NexRide Support',
                message:
                    'Starting Firebase and restoring NexRide support authentication.',
                icon: Icons.support_agent_rounded,
                isLoading: true,
              );
            }

            if (snapshot.hasError) {
              return AdminFullscreenState(
                title: 'Support portal failed to load',
                message:
                    'Firebase startup failed before NexRide Support could finish rendering.',
                error: snapshot.error ??
                    StateError(
                        'Unknown support bootstrap error on route $routeName'),
                stackTrace: snapshot.stackTrace,
                icon: Icons.error_outline_rounded,
              );
            }

            return child;
          },
        );
      },
    );
  }
}

class _SupportFatalError {
  const _SupportFatalError({
    required this.phase,
    required this.error,
    this.stackTrace,
  });

  final String phase;
  final Object error;
  final StackTrace? stackTrace;
}

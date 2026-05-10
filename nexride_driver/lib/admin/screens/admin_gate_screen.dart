import 'package:flutter/material.dart';

import '../admin_config.dart';
import '../models/admin_models.dart';
import '../services/admin_auth_service.dart';
import '../services/admin_data_service.dart';
import '../widgets/admin_components.dart';
import 'admin_login_screen.dart';
import 'admin_panel_screen.dart';

enum AdminGateMode {
  dashboard,
  login,
}

class AdminGateScreen extends StatefulWidget {
  const AdminGateScreen({
    required this.mode,
    super.key,
    this.authService,
    this.inlineMessage,
    this.dataService,
    this.initialSection = AdminSection.dashboard,
    this.loginRoute = AdminRoutePaths.adminLogin,
    this.dashboardRoute = AdminRoutePaths.admin,
    this.routeForSection,
    this.enableRealtimeBadgeListeners = true,
  });

  final AdminGateMode mode;
  final AdminAuthService? authService;
  final String? inlineMessage;
  final AdminDataService? dataService;
  final AdminSection initialSection;
  final String loginRoute;
  final String dashboardRoute;
  final String Function(AdminSection section)? routeForSection;
  final bool enableRealtimeBadgeListeners;

  @override
  State<AdminGateScreen> createState() => _AdminGateScreenState();
}

class _AdminGateScreenState extends State<AdminGateScreen> {
  late final AdminAuthService _authService;
  late Future<AdminSession?> _sessionFuture;
  bool _redirectScheduled = false;
  bool _unauthorizedResetScheduled = false;
  String? _lastDecision;

  @override
  void initState() {
    super.initState();
    _authService = widget.authService ?? AdminAuthService();
    _logDecision('init mode=${widget.mode.name}');
    _sessionFuture = _authService.currentSession();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AdminSession?>(
      future: _sessionFuture,
      builder: (BuildContext context, AsyncSnapshot<AdminSession?> snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          _logDecision('waiting for admin session');
          return const AdminFullscreenState(
            title: 'Loading admin access',
            message:
                'Checking your NexRide admin session before we open the control center.',
            icon: Icons.shield_outlined,
            isLoading: true,
          );
        }

        if (snapshot.hasError) {
          _logDecision('session check failed error=${snapshot.error}');
          return AdminFullscreenState(
            title: 'Admin screen failed to load',
            message:
                'We could not finish the admin authentication check. Review the exception below and refresh the page after fixing the underlying issue.',
            error: snapshot.error,
            stackTrace: snapshot.stackTrace,
            icon: Icons.error_outline_rounded,
          );
        }

        final session = snapshot.data;
        final signedInButUnauthorized =
            session == null && _authService.hasAuthenticatedUser;
        if (signedInButUnauthorized) {
          const message =
              'Your account is signed in but does not have access. Contact the NexRide system administrator.';
          if (widget.mode == AdminGateMode.dashboard) {
            _logDecision(
              'signed-in but unauthorized for dashboard uid=${_authService.authenticatedUid}',
            );
            _scheduleUnauthorizedReset(
              route: widget.loginRoute,
              arguments: message,
            );
            return const AdminFullscreenState(
              title: 'Admin access not authorized',
              message:
                  'Your account is signed in but does not have access. Contact the NexRide system administrator.',
              icon: Icons.lock_outline_rounded,
              isLoading: true,
            );
          }
          _logDecision(
            'signed-in but unauthorized on login route uid=${_authService.authenticatedUid}',
          );
          _scheduleUnauthorizedReset();
          return AdminLoginScreen(
            authService: _authService,
            inlineMessage: message,
            dashboardRoute: widget.dashboardRoute,
          );
        }

        if (session != null && widget.mode == AdminGateMode.login) {
          _logDecision(
            'signed-in admin on login route -> redirect ${widget.dashboardRoute}',
          );
          _redirectTo(widget.dashboardRoute);
          return const AdminFullscreenState(
            title: 'Opening NexRide control center',
            message:
                'Admin access confirmed. Redirecting you to the dashboard now.',
            icon: Icons.dashboard_outlined,
            isLoading: true,
          );
        }

        if (session == null && widget.mode == AdminGateMode.dashboard) {
          _logDecision(
            'not signed in for dashboard -> redirect ${widget.loginRoute}',
          );
          _redirectTo(
            widget.loginRoute,
            arguments:
                'Admin authentication is required before you can open the control center.',
          );
          return const AdminFullscreenState(
            title: 'Redirecting to admin login',
            message:
                'You need to sign in with an admin account before entering the NexRide control center.',
            icon: Icons.login_rounded,
            isLoading: true,
          );
        }

        if (session != null) {
          _logDecision('admin session ready uid=${session.uid}');
          return AdminPanelScreen(
            session: session,
            dataService: widget.dataService,
            authService: _authService,
            initialSection: widget.initialSection,
            loginRoute: widget.loginRoute,
            routeForSection: widget.routeForSection,
            enableRealtimeBadgeListeners: widget.enableRealtimeBadgeListeners,
          );
        }

        _logDecision('signed out on login route -> render login screen');
        return AdminLoginScreen(
          authService: _authService,
          inlineMessage: widget.inlineMessage,
          dashboardRoute: widget.dashboardRoute,
        );
      },
    );
  }

  void _redirectTo(
    String route, {
    Object? arguments,
  }) {
    if (_redirectScheduled) {
      return;
    }
    _redirectScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _logDecision('navigating to $route');
      Navigator.of(context).pushReplacementNamed(route, arguments: arguments);
    });
  }

  void _scheduleUnauthorizedReset({
    String? route,
    Object? arguments,
  }) {
    if (_unauthorizedResetScheduled) {
      return;
    }
    _unauthorizedResetScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _authService.signOut();
      if (!mounted || route == null) {
        return;
      }
      Navigator.of(context).pushReplacementNamed(route, arguments: arguments);
    });
  }

  void _logDecision(String decision) {
    if (_lastDecision == decision) {
      return;
    }
    _lastDecision = decision;
    debugPrint('[AdminGate] $decision');
  }
}

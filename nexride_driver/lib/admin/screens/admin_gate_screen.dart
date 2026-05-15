import 'package:flutter/material.dart';

import '../admin_config.dart';
import '../models/admin_models.dart';
import '../services/admin_auth_service.dart';
import '../services/admin_data_service.dart';
import '../widgets/admin_components.dart';
import 'admin_panel_screen.dart';

/// Thrown when [AdminAuthService.currentSession] does not finish within the
/// gate timeout — avoids an indefinite loading spinner on protected routes.
class AdminAccessCheckTimedOut implements Exception {
  const AdminAccessCheckTimedOut();
}

/// Session + admin-privilege gate for **protected** admin routes only.
///
/// `/admin/login` must not use this widget — it renders [AdminLoginScreen]
/// directly so the sign-in form is never blocked on [currentSession].
class AdminGateScreen extends StatefulWidget {
  const AdminGateScreen({
    super.key,
    this.authService,
    this.dataService,
    this.initialSection = AdminSection.dashboard,
    this.initialDriverDeepLink,
    this.loginRoute = AdminRoutePaths.adminLogin,
    this.dashboardRoute = AdminRoutePaths.admin,
    this.changePasswordRoute = AdminPortalRoutePaths.changePassword,
    this.routeForSection,
    this.enableRealtimeBadgeListeners = true,
  });

  final AdminAuthService? authService;
  final AdminDataService? dataService;
  final AdminSection initialSection;
  final AdminDriverDeepLink? initialDriverDeepLink;
  final String loginRoute;
  final String dashboardRoute;
  final String changePasswordRoute;
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

  static const Duration _kSessionCheckTimeout = Duration(seconds: 25);

  Future<AdminSession?> _sessionFutureWithGateTimeout() {
    return _authService.currentSession().timeout(
      _kSessionCheckTimeout,
      onTimeout: () {
        debugPrint(
          '[AdminGate] currentSession exceeded ${_kSessionCheckTimeout.inSeconds}s',
        );
        throw const AdminAccessCheckTimedOut();
      },
    );
  }

  void _retrySessionCheck() {
    if (!mounted) {
      return;
    }
    setState(() {
      _redirectScheduled = false;
      _unauthorizedResetScheduled = false;
      _lastDecision = null;
      _sessionFuture = _sessionFutureWithGateTimeout();
    });
  }

  Future<void> _signOutAfterTimeout() async {
    try {
      await _authService.signOut();
    } catch (e) {
      debugPrint('[AdminGate] signOut after timeout failed: $e');
    }
    if (!mounted) {
      return;
    }
    _retrySessionCheck();
  }

  @override
  void initState() {
    super.initState();
    _authService = widget.authService ?? AdminAuthService();
    _logDecision('init protected gate');
    _sessionFuture = _sessionFutureWithGateTimeout();
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
          if (snapshot.error is AdminAccessCheckTimedOut) {
            return _buildAccessTimeoutScreen(context);
          }
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
          _logDecision(
            'signed-in but unauthorized for protected route uid=${_authService.authenticatedUid ?? 'unknown'}',
          );
          _scheduleUnauthorizedReset(
            route: widget.loginRoute,
            arguments: const AdminLoginIntent(
              message:
                  'Your account is signed in but does not have access. Contact the NexRide system administrator.',
            ),
          );
          return const AdminFullscreenState(
            title: 'Admin access not authorized',
            message:
                'Your account is signed in but does not have access. Contact the NexRide system administrator.',
            icon: Icons.lock_outline_rounded,
            isLoading: true,
          );
        }

        if (session == null) {
          _logDecision('not signed in for protected route -> ${widget.loginRoute}');
          _redirectTo(
            widget.loginRoute,
            arguments: AdminLoginIntent(
              message:
                  'Admin authentication is required before you can open the control center.',
              returnRoute: ModalRoute.of(context)?.settings.name,
            ),
          );
          return const AdminFullscreenState(
            title: 'Redirecting to admin login',
            message:
                'You need to sign in with an admin account before entering the NexRide control center.',
            icon: Icons.login_rounded,
            isLoading: true,
          );
        }

        if (session.mustChangePassword) {
          _logDecision(
            'admin session ready uid=${session.uid} but mustChangePassword=true '
            '-> ${widget.changePasswordRoute}',
          );
          _redirectTo(widget.changePasswordRoute);
          return const AdminFullscreenState(
            title: 'Password change required',
            message:
                'You\'re using a temporary password. Redirecting to the change-password screen.',
            icon: Icons.lock_clock_rounded,
            isLoading: true,
          );
        }

        _logDecision('admin session ready uid=${session.uid}');
        return AdminPanelScreen(
          session: session,
          dataService: widget.dataService,
          authService: _authService,
          initialSection: widget.initialSection,
          initialDriverDeepLink: widget.initialDriverDeepLink,
          loginRoute: widget.loginRoute,
          routeForSection: widget.routeForSection,
          enableRealtimeBadgeListeners: widget.enableRealtimeBadgeListeners,
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

  Widget _buildAccessTimeoutScreen(BuildContext context) {
    return Scaffold(
      backgroundColor: AdminThemeTokens.canvas,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Icon(
                    Icons.timer_off_outlined,
                    size: 56,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Could not verify admin access',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'The admin access check took longer than '
                    '${_kSessionCheckTimeout.inSeconds} seconds and was stopped '
                    'so this page would not load forever. Retry, or sign out and '
                    'try again.',
                    style: const TextStyle(
                      color: Color(0xFF6F675D),
                      fontSize: 14,
                      height: 1.55,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 28),
                  FilledButton(
                    onPressed: _retrySessionCheck,
                    child: const Text('Retry'),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton(
                    onPressed: _signOutAfterTimeout,
                    child: const Text('Log out'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

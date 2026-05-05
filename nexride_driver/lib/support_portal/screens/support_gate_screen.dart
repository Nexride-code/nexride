import 'package:flutter/material.dart';

import '../../admin/widgets/admin_components.dart';
import '../models/support_models.dart';
import '../services/support_auth_service.dart';
import 'support_login_screen.dart';
import '../widgets/support_workspace_screen.dart';

enum SupportGateMode {
  dashboard,
  login,
}

class SupportGateScreen extends StatefulWidget {
  const SupportGateScreen({
    required this.mode,
    required this.loginRoute,
    required this.dashboardRoute,
    super.key,
    this.authService,
    this.inlineMessage,
    this.initialView = SupportInboxView.dashboard,
    this.initialTicketDocumentId,
    this.routeForView,
    this.routeForTicket,
  });

  final SupportGateMode mode;
  final String loginRoute;
  final String dashboardRoute;
  final SupportAuthService? authService;
  final String? inlineMessage;
  final SupportInboxView initialView;
  final String? initialTicketDocumentId;
  final String Function(SupportInboxView view)? routeForView;
  final String Function(String ticketDocumentId)? routeForTicket;

  @override
  State<SupportGateScreen> createState() => _SupportGateScreenState();
}

class _SupportGateScreenState extends State<SupportGateScreen> {
  late final SupportAuthService _authService;
  late Future<SupportSession?> _sessionFuture;
  bool _redirectScheduled = false;
  bool _unauthorizedResetScheduled = false;
  String? _lastDecision;

  @override
  void initState() {
    super.initState();
    _authService = widget.authService ?? SupportAuthService();
    _logDecision('init mode=${widget.mode.name}');
    _sessionFuture = _authService.currentSession();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<SupportSession?>(
      future: _sessionFuture,
      builder: (
        BuildContext context,
        AsyncSnapshot<SupportSession?> snapshot,
      ) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          _logDecision('waiting for support session');
          return const AdminFullscreenState(
            title: 'Loading support access',
            message:
                'Checking your NexRide support session before we open the workspace.',
            icon: Icons.support_agent_outlined,
            isLoading: true,
          );
        }

        if (snapshot.hasError) {
          _logDecision('session check failed error=${snapshot.error}');
          return AdminFullscreenState(
            title: 'Support portal failed to load',
            message:
                'We could not finish the support authentication check. Review the exception below and refresh after fixing the underlying issue.',
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
          if (widget.mode == SupportGateMode.dashboard) {
            _logDecision(
              'signed-in but unauthorized for support dashboard uid=${_authService.authenticatedUid}',
            );
            _scheduleUnauthorizedReset(
              route: widget.loginRoute,
              arguments: message,
            );
            return const AdminFullscreenState(
              title: 'Support access not authorized',
              message:
                  'Your account is signed in but does not have access. Contact the NexRide system administrator.',
              icon: Icons.lock_outline_rounded,
              isLoading: true,
            );
          }
          _logDecision(
            'signed-in but unauthorized on support login route uid=${_authService.authenticatedUid}',
          );
          _scheduleUnauthorizedReset();
          return SupportLoginScreen(
            authService: _authService,
            inlineMessage: message,
            dashboardRoute: widget.initialTicketDocumentId != null
                ? widget.routeForTicket
                        ?.call(widget.initialTicketDocumentId!) ??
                    widget.dashboardRoute
                : widget.routeForView?.call(widget.initialView) ??
                    widget.dashboardRoute,
          );
        }

        if (session != null && widget.mode == SupportGateMode.login) {
          final route = widget.initialTicketDocumentId != null
              ? widget.routeForTicket?.call(widget.initialTicketDocumentId!) ??
                  widget.dashboardRoute
              : widget.routeForView?.call(widget.initialView) ??
                  widget.dashboardRoute;
          _redirectTo(route);
          return const AdminFullscreenState(
            title: 'Opening support workspace',
            message:
                'Support access confirmed. Redirecting you to the ticket workspace now.',
            icon: Icons.mark_email_read_outlined,
            isLoading: true,
          );
        }

        if (session == null && widget.mode == SupportGateMode.dashboard) {
          _redirectTo(
            widget.loginRoute,
            arguments:
                'Support authentication is required before you can open the support portal.',
          );
          return const AdminFullscreenState(
            title: 'Redirecting to support login',
            message:
                'You need to sign in with a support or admin account before entering the workspace.',
            icon: Icons.login_rounded,
            isLoading: true,
          );
        }

        if (session != null) {
          return SupportWorkspaceScreen(
            session: session,
            authService: _authService,
            loginRoute: widget.loginRoute,
            initialView: widget.initialView,
            initialTicketDocumentId: widget.initialTicketDocumentId,
            routeForView: widget.routeForView,
            routeForTicket: widget.routeForTicket,
          );
        }

        return SupportLoginScreen(
          authService: _authService,
          inlineMessage: widget.inlineMessage,
          dashboardRoute: widget.initialTicketDocumentId != null
              ? widget.routeForTicket?.call(widget.initialTicketDocumentId!) ??
                  widget.dashboardRoute
              : widget.routeForView?.call(widget.initialView) ??
                  widget.dashboardRoute,
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
    debugPrint('[SupportGate] $decision');
  }
}

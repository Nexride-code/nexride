import 'package:flutter/material.dart';

import '../admin/admin_config.dart';
import 'dispatch_fleet_routes.dart';
import 'screens/dispatch_fleet_bikers_screen.dart';
import 'screens/dispatch_fleet_dashboard_screen.dart';
import 'screens/dispatch_fleet_invite_screen.dart';
import 'screens/dispatch_fleet_landing_screen.dart';
import 'screens/dispatch_fleet_login_screen.dart';
import 'screens/dispatch_fleet_pending_screen.dart';
import 'screens/dispatch_fleet_rejected_screen.dart';
import 'screens/dispatch_fleet_suspended_screen.dart';
import 'screens/dispatch_fleet_session_gate_screen.dart';
import 'screens/dispatch_fleet_signup_screen.dart';
import 'screens/dispatch_fleet_support_screen.dart';

/// Standalone Dispatch Fleet portal (hosted at `/fleet/`).
class DispatchFleetPortalApp extends StatelessWidget {
  const DispatchFleetPortalApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'NexRide Dispatch Fleet',
      theme: _dispatchFleetTheme(),
      initialRoute: DispatchFleetRoutes.root,
      routes: <String, WidgetBuilder>{
        DispatchFleetRoutes.root: (_) => const DispatchFleetLandingScreen(),
        DispatchFleetRoutes.login: (_) => const DispatchFleetLoginScreen(),
        DispatchFleetRoutes.signup: (_) => const DispatchFleetSignupScreen(),
        DispatchFleetRoutes.session: (_) => const DispatchFleetSessionGateScreen(),
        DispatchFleetRoutes.pending: (_) => const DispatchFleetPendingScreen(),
        DispatchFleetRoutes.rejected: (_) => const DispatchFleetRejectedScreen(),
        DispatchFleetRoutes.suspended: (_) => const DispatchFleetSuspendedScreen(),
        DispatchFleetRoutes.dashboard: (_) => const DispatchFleetDashboardScreen(),
        DispatchFleetRoutes.bikers: (_) => const DispatchFleetBikersScreen(),
        DispatchFleetRoutes.invites: (_) => const DispatchFleetInviteScreen(),
        DispatchFleetRoutes.support: (_) => const DispatchFleetSupportScreen(),
      },
    );
  }
}

ThemeData _dispatchFleetTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AdminThemeTokens.gold,
    brightness: Brightness.light,
    primary: AdminThemeTokens.gold,
    onPrimary: Colors.white,
    surface: AdminThemeTokens.surface,
    onSurface: AdminThemeTokens.ink,
    outline: AdminThemeTokens.border,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AdminThemeTokens.canvas,
    appBarTheme: const AppBarTheme(
      backgroundColor: AdminThemeTokens.ink,
      foregroundColor: Colors.white,
      elevation: 0,
    ),
    cardTheme: CardThemeData(
      elevation: 2,
      shadowColor: Colors.black.withValues(alpha: 0.08),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AdminThemeTokens.border),
      ),
      color: AdminThemeTokens.surface,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AdminThemeTokens.gold,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      ),
    ),
  );
}

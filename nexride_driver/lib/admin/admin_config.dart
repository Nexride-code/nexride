import 'package:flutter/material.dart';

import '../portal_security/portal_security_theme.dart';

/// Arguments for [AdminLoginScreen] when a protected route sends the user to
/// `/login`. Preserves the intended post-auth destination (base-relative route
/// name, e.g. `/live-ops`).
@immutable
class AdminLoginIntent {
  const AdminLoginIntent({
    this.message,
    this.returnRoute,
  });

  final String? message;
  final String? returnRoute;

  /// Returns a safe Navigator route name, or `null` if [raw] should be ignored.
  static String? validatedReturnRoute(String? raw) {
    if (raw == null || raw.isEmpty) {
      return null;
    }
    final String n = AdminPortalRoutePaths.normalize(raw);
    if (n == AdminPortalRoutePaths.login) {
      return null;
    }
    if (!AdminPortalRoutePaths.isProtectedRoute(n)) {
      return null;
    }
    return n;
  }
}

/// User-facing banner on the admin login screen from [Navigator] arguments.
String? adminLoginBannerFromArguments(Object? arguments) {
  if (arguments is AdminLoginIntent) {
    return arguments.message;
  }
  if (arguments is String) {
    return arguments;
  }
  return null;
}

/// Deep link to a driver entity drawer (`/drivers/{id}?tab=…`).
@immutable
class AdminDriverDeepLink {
  const AdminDriverDeepLink({
    required this.driverId,
    this.tab,
  });

  final String driverId;
  final String? tab;
}

/// Legacy string constants used by a few widgets/tests. Navigator route names
/// for the hosted admin app are **base-relative** (see [AdminPortalRoutePaths])
/// so PathUrlStrategy does not emit `/admin/admin/...` URLs.
class AdminRoutePaths {
  static const String driverHome = '/';
  static const String admin = AdminPortalRoutePaths.dashboard;
  static const String adminLogin = AdminPortalRoutePaths.login;
}

/// Route names passed to [Navigator] under `<base href="/admin/">` + path URL
/// strategy must **not** repeat the `/admin` prefix — the engine prepends the
/// base path when syncing the browser address bar.
class AdminPortalRoutePaths {
  /// Public URL prefix for deep links (documentation / emails only).
  static const String adminPrefix = '/admin';

  /// Default signed-in landing (browser `/admin` or `/admin/` maps here).
  static const String dashboard = '/dashboard';
  static const String login = '/login';
  static const String riders = '/riders';
  static const String drivers = '/drivers';
  static const String trips = '/trips';
  static const String liveOps = '/live-ops';
  static const String systemHealth = '/system-health';
  static const String finance = '/finance';
  static const String withdrawals = '/withdrawals';
  static const String pricing = '/pricing';
  static const String subscriptions = '/subscriptions';
  static const String verification = '/verification';
  static const String support = '/support';
  static const String regions = '/regions';
  static const String serviceAreas = '/service-areas';
  static const String merchants = '/merchants';
  static const String settings = '/settings';
  static const String auditLogs = '/audit-logs';
  static const String accountSecurity = '/account/security';
  static const String changePassword = '/account/change-password';

  /// Alias for [dashboard] used by routing heuristics.
  static const String root = dashboard;

  static const Map<String, String> _relativeAliases = <String, String>{
    '/': dashboard,
    '/login': login,
    '/dashboard': dashboard,
    '/riders': riders,
    '/drivers': drivers,
    '/trips': trips,
    '/live-ops': liveOps,
    '/system-health': systemHealth,
    '/finance': finance,
    '/withdrawals': withdrawals,
    '/pricing': pricing,
    '/subscriptions': subscriptions,
    '/verification': verification,
    '/support': support,
    '/regions': regions,
    '/service-areas': serviceAreas,
    '/merchants': merchants,
    '/settings': settings,
    '/audit-logs': auditLogs,
    '/account/security': accountSecurity,
    '/account/change-password': changePassword,
  };

  static const List<String> protectedRoutes = <String>[
    dashboard,
    riders,
    drivers,
    trips,
    liveOps,
    systemHealth,
    finance,
    withdrawals,
    pricing,
    subscriptions,
    verification,
    support,
    regions,
    serviceAreas,
    merchants,
    settings,
    auditLogs,
    accountSecurity,
    changePassword,
  ];

  static String normalize(String rawPath) {
    var path = rawPath.trim();
    if (path.isEmpty) {
      return dashboard;
    }
    if (!path.startsWith('/')) {
      path = '/$path';
    }
    if (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    // Production hosting: strip one or more `/admin` segments (bad URLs from
    // older builds or manual edits) so routing recovers.
    while (path.startsWith('$adminPrefix/')) {
      path = path.substring(adminPrefix.length);
      if (!path.startsWith('/')) {
        path = '/$path';
      }
    }
    if (path == adminPrefix) {
      return dashboard;
    }
    if (!path.startsWith('/')) {
      path = '/$path';
    }
    final aliasedPath = _relativeAliases[path];
    if (aliasedPath != null) {
      return aliasedPath;
    }
    return path;
  }

  static bool isLoginRoute(String path) => normalize(path) == login;

  static bool isProtectedRoute(String path) {
    final normalized = normalize(path);
    if (parseDriverDeepLinkUri(Uri(path: normalized)) != null) {
      return true;
    }
    return normalized == dashboard || protectedRoutes.contains(normalized);
  }

  /// Parses `/drivers/{driverId}` (and optional `?tab=` on [uri]).
  static AdminDriverDeepLink? parseDriverDeepLinkUri(Uri uri) {
    final String path = normalize(uri.path);
    if (!path.startsWith('$drivers/')) {
      return null;
    }
    var suffix = path.substring(drivers.length + 1);
    if (suffix.isEmpty) {
      return null;
    }
    if (suffix.contains('/')) {
      suffix = suffix.split('/').first;
    }
    if (suffix.isEmpty) {
      return null;
    }
    final String driverId = Uri.decodeComponent(suffix);
    if (driverId.isEmpty) {
      return null;
    }
    final String? rawTab = uri.queryParameters['tab']?.trim();
    final String? tab =
        rawTab != null && rawTab.isNotEmpty ? rawTab : null;
    return AdminDriverDeepLink(driverId: driverId, tab: tab);
  }

  static String pathForSection(AdminSection section) {
    return switch (section) {
      AdminSection.dashboard => dashboard,
      AdminSection.riders => riders,
      AdminSection.drivers => drivers,
      AdminSection.trips => trips,
      AdminSection.liveOperations => liveOps,
      AdminSection.systemHealth => systemHealth,
      AdminSection.finance => finance,
      AdminSection.withdrawals => withdrawals,
      AdminSection.pricing => pricing,
      AdminSection.subscriptions => subscriptions,
      AdminSection.verification => verification,
      AdminSection.support => support,
      AdminSection.regions => regions,
      AdminSection.serviceAreas => serviceAreas,
      AdminSection.merchants => merchants,
      AdminSection.settings => settings,
      AdminSection.auditLogs => auditLogs,
    };
  }

  static AdminSection sectionForPath(String path) {
    final String n = normalize(path);
    if (parseDriverDeepLinkUri(Uri(path: n)) != null) {
      return AdminSection.drivers;
    }
    final AdminSection section = switch (n) {
      dashboard => AdminSection.dashboard,
      riders => AdminSection.riders,
      drivers => AdminSection.drivers,
      trips => AdminSection.trips,
      liveOps => AdminSection.liveOperations,
      finance => AdminSection.finance,
      withdrawals => AdminSection.withdrawals,
      pricing => AdminSection.pricing,
      subscriptions => AdminSection.subscriptions,
      verification => AdminSection.verification,
      support => AdminSection.support,
      regions => AdminSection.regions,
      serviceAreas => AdminSection.serviceAreas,
      merchants => AdminSection.merchants,
      settings => AdminSection.settings,
      auditLogs => AdminSection.auditLogs,
      _ => AdminSection.dashboard,
    };
    if (section == AdminSection.liveOperations) {
      debugPrint('[LIVE_OPS][ROUTE] resolved section=liveOperations');
    }
    if (section == AdminSection.auditLogs) {
      debugPrint('[AUDIT_LOGS][ROUTE] resolved section=auditLogs');
    }
    return section;
  }
}

enum AdminSection {
  dashboard,
  riders,
  drivers,
  trips,
  liveOperations,
  systemHealth,
  finance,
  withdrawals,
  pricing,
  subscriptions,
  verification,
  support,
  regions,
  serviceAreas,
  merchants,
  settings,
  auditLogs,
}

/// Order of sections in the admin drawer / persistent sidebar.
///
/// **Official drawer visibility (control center):** Dashboard, Riders, Drivers,
/// Trips, Live operations, Finance, Withdrawals, **Pricing**, **Subscriptions**,
/// Verification, Support, Regions, Service areas, Merchants, Audit logs,
/// Settings. (`AdminSection` / routes must stay in sync with this list.)
///
/// Live operations is placed after Trips. Audit logs sits before Settings.
const List<AdminSection> kAdminSidebarNavOrder = <AdminSection>[
  AdminSection.dashboard,
  AdminSection.riders,
  AdminSection.drivers,
  AdminSection.trips,
  AdminSection.liveOperations,
  AdminSection.systemHealth,
  AdminSection.finance,
  AdminSection.withdrawals,
  AdminSection.pricing,
  AdminSection.subscriptions,
  AdminSection.verification,
  AdminSection.support,
  AdminSection.regions,
  AdminSection.serviceAreas,
  AdminSection.merchants,
  AdminSection.auditLogs,
  AdminSection.settings,
];

extension AdminSectionPresentation on AdminSection {
  String get label {
    return switch (this) {
      AdminSection.dashboard => 'Dashboard',
      AdminSection.riders => 'Riders',
      AdminSection.drivers => 'Drivers',
      AdminSection.trips => 'Trips',
      AdminSection.liveOperations => 'Live operations',
      AdminSection.systemHealth => 'System health',
      AdminSection.finance => 'Finance',
      AdminSection.withdrawals => 'Withdrawals',
      AdminSection.pricing => 'Pricing',
      AdminSection.subscriptions => 'Subscriptions',
      AdminSection.verification => 'Verification',
      AdminSection.support => 'Support',
      AdminSection.regions => 'Regions',
      AdminSection.serviceAreas => 'Service areas',
      AdminSection.merchants => 'Merchants',
      AdminSection.settings => 'Settings',
      AdminSection.auditLogs => 'Audit logs',
    };
  }

  String get shortLabel {
    return switch (this) {
      AdminSection.dashboard => 'Overview',
      AdminSection.riders => 'Riders',
      AdminSection.drivers => 'Drivers',
      AdminSection.trips => 'Trips',
      AdminSection.liveOperations => 'Live ops',
      AdminSection.systemHealth => 'Health',
      AdminSection.finance => 'Finance',
      AdminSection.withdrawals => 'Payouts',
      AdminSection.pricing => 'Pricing',
      AdminSection.subscriptions => 'Plans',
      AdminSection.verification => 'Verification',
      AdminSection.support => 'Issues',
      AdminSection.regions => 'Regions',
      AdminSection.serviceAreas => 'Areas',
      AdminSection.merchants => 'Merchants',
      AdminSection.settings => 'Settings',
      AdminSection.auditLogs => 'Audit',
    };
  }

  IconData get icon {
    return switch (this) {
      AdminSection.dashboard => Icons.space_dashboard_rounded,
      AdminSection.riders => Icons.person_outline_rounded,
      AdminSection.drivers => Icons.badge_outlined,
      AdminSection.trips => Icons.route_outlined,
      AdminSection.liveOperations => Icons.dashboard_customize_outlined,
      AdminSection.systemHealth => Icons.monitor_heart_outlined,
      AdminSection.finance => Icons.query_stats_rounded,
      AdminSection.withdrawals => Icons.account_balance_wallet_outlined,
      AdminSection.pricing => Icons.local_offer_outlined,
      AdminSection.subscriptions => Icons.workspace_premium_outlined,
      AdminSection.verification => Icons.verified_user_outlined,
      AdminSection.support => Icons.support_agent_outlined,
      AdminSection.regions => Icons.map_outlined,
      AdminSection.serviceAreas => Icons.location_city_outlined,
      AdminSection.merchants => Icons.storefront_outlined,
      AdminSection.settings => Icons.settings_outlined,
      AdminSection.auditLogs => Icons.fact_check_outlined,
    };
  }
}

class AdminThemeTokens {
  static const Color gold = Color(0xFFB57A2A);
  static const Color goldSoft = Color(0xFFF3E1B9);
  static const Color ink = Color(0xFF131313);
  static const Color slate = Color(0xFF21242A);
  static const Color surface = Colors.white;
  static const Color canvas = Color(0xFFF6F3EE);
  static const Color canvasDark = Color(0xFF141516);
  static const Color border = Color(0xFFE8DFD0);
  static const Color success = Color(0xFF198754);
  static const Color warning = Color(0xFFB2771A);
  static const Color danger = Color(0xFFD64545);
  static const Color info = Color(0xFF2F6DA8);

  static const Gradient heroGradient = LinearGradient(
    colors: <Color>[
      Color(0xFF131313),
      Color(0xFF2A241A),
      Color(0xFF5C4320),
    ],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  /// [PortalSecurityTheme] built from the admin tokens above so the shared
  /// account-security screens render with the admin brand palette.
  static const PortalSecurityTheme portalSecurityTheme = PortalSecurityTheme(
    canvas: canvas,
    surface: surface,
    border: border,
    subtle: Color(0xFF55514A),
    appBarBackground: ink,
    appBarForeground: Colors.white,
    primary: gold,
    onPrimary: Colors.white,
    success: success,
    successBackground: Color(0xFFE7F6EC),
    successBorder: Color(0xFFB7E1C1),
    danger: danger,
    dangerBackground: Color(0xFFFDECEE),
    dangerBorder: Color(0xFFF5C6CB),
    warningForeground: warning,
    warningBackground: Color(0xFFFFF8E1),
    warningBorder: Color(0xFFF4C430),
  );
}

import 'package:flutter/material.dart';

class AdminRoutePaths {
  static const String driverHome = '/';
  static const String admin = '/admin';
  static const String adminLogin = '/admin/login';
}

class AdminPortalRoutePaths {
  static const String adminPrefix = '/admin';
  static const String root = adminPrefix;
  static const String login = '$adminPrefix/login';
  static const String dashboard = '$adminPrefix/dashboard';
  static const String riders = '$adminPrefix/riders';
  static const String drivers = '$adminPrefix/drivers';
  static const String trips = '$adminPrefix/trips';
  static const String finance = '$adminPrefix/finance';
  static const String withdrawals = '$adminPrefix/withdrawals';
  static const String pricing = '$adminPrefix/pricing';
  static const String subscriptions = '$adminPrefix/subscriptions';
  static const String verification = '$adminPrefix/verification';
  static const String support = '$adminPrefix/support';
  static const String settings = '$adminPrefix/settings';

  static const Map<String, String> _relativeAliases = <String, String>{
    '/': root,
    '/login': login,
    '/dashboard': dashboard,
    '/riders': riders,
    '/drivers': drivers,
    '/trips': trips,
    '/finance': finance,
    '/withdrawals': withdrawals,
    '/pricing': pricing,
    '/subscriptions': subscriptions,
    '/verification': verification,
    '/support': support,
    '/settings': settings,
  };

  static const List<String> protectedRoutes = <String>[
    dashboard,
    riders,
    drivers,
    trips,
    finance,
    withdrawals,
    pricing,
    subscriptions,
    verification,
    support,
    settings,
  ];

  static String normalize(String rawPath) {
    var path = rawPath.trim();
    if (path.isEmpty) {
      return root;
    }
    if (!path.startsWith('/')) {
      path = '/$path';
    }
    if (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    final aliasedPath = _relativeAliases[path];
    if (aliasedPath != null) {
      return aliasedPath;
    }
    if (path == adminPrefix) {
      return root;
    }
    if (path.startsWith('$adminPrefix/')) {
      return path;
    }
    return path;
  }

  static bool isLoginRoute(String path) => normalize(path) == login;

  static bool isProtectedRoute(String path) {
    final normalized = normalize(path);
    return normalized == root || protectedRoutes.contains(normalized);
  }

  static String pathForSection(AdminSection section) {
    return switch (section) {
      AdminSection.dashboard => dashboard,
      AdminSection.riders => riders,
      AdminSection.drivers => drivers,
      AdminSection.trips => trips,
      AdminSection.finance => finance,
      AdminSection.withdrawals => withdrawals,
      AdminSection.pricing => pricing,
      AdminSection.subscriptions => subscriptions,
      AdminSection.verification => verification,
      AdminSection.support => support,
      AdminSection.settings => settings,
    };
  }

  static AdminSection sectionForPath(String path) {
    return switch (normalize(path)) {
      root || dashboard => AdminSection.dashboard,
      riders => AdminSection.riders,
      drivers => AdminSection.drivers,
      trips => AdminSection.trips,
      finance => AdminSection.finance,
      withdrawals => AdminSection.withdrawals,
      pricing => AdminSection.pricing,
      subscriptions => AdminSection.subscriptions,
      verification => AdminSection.verification,
      support => AdminSection.support,
      settings => AdminSection.settings,
      _ => AdminSection.dashboard,
    };
  }
}

enum AdminSection {
  dashboard,
  riders,
  drivers,
  trips,
  finance,
  withdrawals,
  pricing,
  subscriptions,
  verification,
  support,
  settings,
}

extension AdminSectionPresentation on AdminSection {
  String get label {
    return switch (this) {
      AdminSection.dashboard => 'Dashboard',
      AdminSection.riders => 'Riders',
      AdminSection.drivers => 'Drivers',
      AdminSection.trips => 'Trips',
      AdminSection.finance => 'Finance',
      AdminSection.withdrawals => 'Withdrawals',
      AdminSection.pricing => 'Pricing',
      AdminSection.subscriptions => 'Subscriptions',
      AdminSection.verification => 'Verification',
      AdminSection.support => 'Support',
      AdminSection.settings => 'Settings',
    };
  }

  String get shortLabel {
    return switch (this) {
      AdminSection.dashboard => 'Overview',
      AdminSection.riders => 'Riders',
      AdminSection.drivers => 'Drivers',
      AdminSection.trips => 'Trips',
      AdminSection.finance => 'Finance',
      AdminSection.withdrawals => 'Payouts',
      AdminSection.pricing => 'Pricing',
      AdminSection.subscriptions => 'Plans',
      AdminSection.verification => 'Compliance',
      AdminSection.support => 'Issues',
      AdminSection.settings => 'Settings',
    };
  }

  IconData get icon {
    return switch (this) {
      AdminSection.dashboard => Icons.space_dashboard_rounded,
      AdminSection.riders => Icons.person_outline_rounded,
      AdminSection.drivers => Icons.badge_outlined,
      AdminSection.trips => Icons.route_outlined,
      AdminSection.finance => Icons.query_stats_rounded,
      AdminSection.withdrawals => Icons.account_balance_wallet_outlined,
      AdminSection.pricing => Icons.local_offer_outlined,
      AdminSection.subscriptions => Icons.workspace_premium_outlined,
      AdminSection.verification => Icons.verified_user_outlined,
      AdminSection.support => Icons.support_agent_outlined,
      AdminSection.settings => Icons.settings_outlined,
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
}

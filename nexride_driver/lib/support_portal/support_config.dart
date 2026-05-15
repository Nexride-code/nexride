import 'package:flutter/material.dart';

import '../admin/admin_config.dart';
import '../portal_security/portal_security_theme.dart';
import 'models/support_models.dart';

class SupportRoutePaths {
  /// Browser / hosting mount — strip in [normalize] only. Do **not** use as a
  /// [Navigator] route name with `<base href="/support/">` + path URL strategy.
  static const String hostingPrefix = '/support';

  /// Public URL prefix (emails, docs). Same as [hostingPrefix].
  static const String prefix = hostingPrefix;

  static const String login = '/login';
  static const String dashboard = '/dashboard';
  static const String openTickets = '/open';
  static const String assignedToMe = '/assigned';
  static const String pendingUser = '/pending-user';
  static const String escalated = '/escalated';
  static const String resolved = '/resolved';
  static const String ticketPrefix = '/tickets';
  static const String accountSecurity = '/account/security';
  static const String changePassword = '/account/change-password';

  static bool _isKnownSupportPath(String path) {
    return path == login ||
        path == dashboard ||
        path == openTickets ||
        path == assignedToMe ||
        path == pendingUser ||
        path == escalated ||
        path == resolved ||
        path == accountSecurity ||
        path == changePassword ||
        path.startsWith('$ticketPrefix/');
  }

  static String normalize(String rawPath) {
    var path = rawPath.trim();
    if (path.startsWith('#')) {
      path = path.substring(1).trim();
    }
    if (path.isEmpty) {
      return login;
    }
    if (!path.startsWith('/')) {
      path = '/$path';
    }
    if (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    while (path.startsWith('$hostingPrefix/')) {
      path = path.substring(hostingPrefix.length);
      if (!path.startsWith('/')) {
        path = '/$path';
      }
    }
    if (path == hostingPrefix) {
      return login;
    }
    if (!path.startsWith('/')) {
      path = '/$path';
    }
    if (path.isEmpty || path == '/') {
      return login;
    }
    if (_isKnownSupportPath(path)) {
      return path;
    }
    return path;
  }

  static bool isSupportRoute(String path) {
    final normalized = normalize(path);
    return normalized == login ||
        normalized == dashboard ||
        normalized == openTickets ||
        normalized == assignedToMe ||
        normalized == pendingUser ||
        normalized == escalated ||
        normalized == resolved ||
        normalized == accountSecurity ||
        normalized == changePassword ||
        normalized.startsWith('$ticketPrefix/');
  }

  static bool isAccountRoute(String path) {
    final normalized = normalize(path);
    return normalized == accountSecurity || normalized == changePassword;
  }

  static bool isProtectedRoute(String path) {
    final normalized = normalize(path);
    return normalized != login && isSupportRoute(normalized);
  }

  static String pathForView(SupportInboxView view) {
    return switch (view) {
      SupportInboxView.dashboard => dashboard,
      SupportInboxView.open => openTickets,
      SupportInboxView.assignedToMe => assignedToMe,
      SupportInboxView.pendingUser => pendingUser,
      SupportInboxView.escalated => escalated,
      SupportInboxView.resolved => resolved,
    };
  }

  static SupportInboxView viewForPath(String path) {
    return switch (normalize(path)) {
      dashboard => SupportInboxView.dashboard,
      openTickets => SupportInboxView.open,
      assignedToMe => SupportInboxView.assignedToMe,
      pendingUser => SupportInboxView.pendingUser,
      escalated => SupportInboxView.escalated,
      resolved => SupportInboxView.resolved,
      _ => SupportInboxView.dashboard,
    };
  }

  static String ticketPath(String ticketDocumentId) {
    return '$ticketPrefix/${Uri.encodeComponent(ticketDocumentId)}';
  }

  static String? ticketDocumentIdFromPath(String path) {
    final normalized = normalize(path);
    if (!normalized.startsWith('$ticketPrefix/')) {
      return null;
    }
    final value = normalized.substring('$ticketPrefix/'.length).trim();
    return value.isEmpty ? null : Uri.decodeComponent(value);
  }

  static SupportRouteResolution resolve(
    String? requestedRoute, {
    required Uri startupUri,
  }) {
    final requested = normalize(requestedRoute ?? login);
    final pathCandidate = normalize(startupUri.path);

    final shouldPreferStartupUri =
        requestedRoute == null || requested == login;

    String resolvedPath;
    if (!shouldPreferStartupUri) {
      resolvedPath = isSupportRoute(requested) ? requested : login;
    } else {
      final preferred = <String>[
        if (isSupportRoute(pathCandidate)) pathCandidate,
        if (isSupportRoute(requested)) requested,
      ];
      resolvedPath = preferred.isEmpty ? login : preferred.first;
    }
    final ticketDocumentId = ticketDocumentIdFromPath(resolvedPath) ??
        startupUri.queryParameters['ticketId']?.trim();
    final safeTicketDocumentId =
        ticketDocumentId == null || ticketDocumentId.isEmpty
            ? null
            : ticketDocumentId;

    return SupportRouteResolution(
      routePath: resolvedPath,
      initialView: safeTicketDocumentId != null
          ? SupportInboxView.open
          : viewForPath(resolvedPath),
      ticketDocumentId: safeTicketDocumentId,
    );
  }
}

class SupportRouteResolution {
  const SupportRouteResolution({
    required this.routePath,
    required this.initialView,
    this.ticketDocumentId,
  });

  final String routePath;
  final SupportInboxView initialView;
  final String? ticketDocumentId;
}

class SupportThemeTokens {
  static const Color heroNavy = Color(0xFF16212E);
  static const Color heroInk = Color(0xFF0F1720);
  static const Color alert = Color(0xFFCF5C36);
  static const Color calm = Color(0xFF2B6E6A);

  static const Gradient portalGradient = LinearGradient(
    colors: <Color>[
      heroInk,
      heroNavy,
      Color(0xFF5C4320),
    ],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  /// [PortalSecurityTheme] built from the support tokens above so the shared
  /// account-security screens render with the support brand palette.
  static const PortalSecurityTheme portalSecurityTheme = PortalSecurityTheme(
    canvas: AdminThemeTokens.canvas,
    surface: AdminThemeTokens.surface,
    border: AdminThemeTokens.border,
    subtle: Color(0xFF55514A),
    appBarBackground: heroInk,
    appBarForeground: Colors.white,
    primary: AdminThemeTokens.gold,
    onPrimary: Colors.white,
    success: AdminThemeTokens.success,
    successBackground: Color(0xFFE7F6EC),
    successBorder: Color(0xFFB7E1C1),
    danger: AdminThemeTokens.danger,
    dangerBackground: Color(0xFFFDECEE),
    dangerBorder: Color(0xFFF5C6CB),
    warningForeground: AdminThemeTokens.warning,
    warningBackground: Color(0xFFFFF8E1),
    warningBorder: Color(0xFFF4C430),
  );

  static ThemeData buildTheme() {
    return ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: AdminThemeTokens.canvas,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AdminThemeTokens.gold,
        primary: AdminThemeTokens.gold,
        brightness: Brightness.light,
        surface: Colors.white,
      ),
      fontFamily: 'Segoe UI',
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

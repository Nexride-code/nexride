/// Color tokens shared by every screen in `portal_security/`. Each portal
/// (admin, support) instantiates its own [PortalSecurityTheme] so the
/// shared widgets keep working identically on both surfaces while still
/// matching their host's brand palette.
library;

import 'package:flutter/material.dart';

@immutable
class PortalSecurityTheme {
  const PortalSecurityTheme({
    required this.canvas,
    required this.surface,
    required this.border,
    required this.subtle,
    required this.appBarBackground,
    required this.appBarForeground,
    required this.primary,
    required this.onPrimary,
    required this.success,
    required this.successBackground,
    required this.successBorder,
    required this.danger,
    required this.dangerBackground,
    required this.dangerBorder,
    required this.warningForeground,
    required this.warningBackground,
    required this.warningBorder,
  });

  final Color canvas;
  final Color surface;
  final Color border;
  final Color subtle;
  final Color appBarBackground;
  final Color appBarForeground;
  final Color primary;
  final Color onPrimary;
  final Color success;
  final Color successBackground;
  final Color successBorder;
  final Color danger;
  final Color dangerBackground;
  final Color dangerBorder;
  final Color warningForeground;
  final Color warningBackground;
  final Color warningBorder;

  /// Sensible default palette so unit tests / preview tools can render
  /// the screens without depending on AdminThemeTokens / SupportThemeTokens.
  static const PortalSecurityTheme fallback = PortalSecurityTheme(
    canvas: Color(0xFFF6F3EE),
    surface: Colors.white,
    border: Color(0xFFE8DFD0),
    subtle: Color(0xFF55514A),
    appBarBackground: Color(0xFF131313),
    appBarForeground: Colors.white,
    primary: Color(0xFFB57A2A),
    onPrimary: Colors.white,
    success: Color(0xFF0A7D2C),
    successBackground: Color(0xFFE7F6EC),
    successBorder: Color(0xFFB7E1C1),
    danger: Color(0xFFB00020),
    dangerBackground: Color(0xFFFDECEE),
    dangerBorder: Color(0xFFF5C6CB),
    warningForeground: Color(0xFF8A5B00),
    warningBackground: Color(0xFFFFF8E1),
    warningBorder: Color(0xFFF4C430),
  );
}

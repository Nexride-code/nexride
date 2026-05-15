import 'package:flutter/material.dart';

import '../admin/admin_config.dart';

/// NexRide merchant portal theme (aligned with admin/driver warm palette).
ThemeData merchantPortalTheme() {
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
      centerTitle: false,
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
    dividerTheme: const DividerThemeData(color: AdminThemeTokens.border),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AdminThemeTokens.gold,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AdminThemeTokens.ink,
        side: const BorderSide(color: AdminThemeTokens.border),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AdminThemeTokens.gold,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AdminThemeTokens.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AdminThemeTokens.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AdminThemeTokens.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AdminThemeTokens.gold, width: 1.4),
      ),
    ),
  );
}

import 'package:flutter/material.dart';

/// NexRide merchant palette (aligned with admin / driver merchant portal tokens).
class NexrideMerchantColors {
  static const Color gold = Color(0xFFB57A2A);
  static const Color goldSoft = Color(0xFFF3E1B9);
  static const Color ink = Color(0xFF131313);
  static const Color surface = Colors.white;
  static const Color canvas = Color(0xFFF6F3EE);
  static const Color border = Color(0xFFE8DFD0);
  static const Color success = Color(0xFF198754);
  static const Color warning = Color(0xFFB2771A);
  static const Color danger = Color(0xFFD64545);
}

ThemeData buildMerchantTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: NexrideMerchantColors.gold,
    brightness: Brightness.light,
    primary: NexrideMerchantColors.gold,
    onPrimary: Colors.white,
    surface: NexrideMerchantColors.surface,
    onSurface: NexrideMerchantColors.ink,
    outline: NexrideMerchantColors.border,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: NexrideMerchantColors.canvas,
    appBarTheme: const AppBarTheme(
      backgroundColor: NexrideMerchantColors.ink,
      foregroundColor: Colors.white,
      elevation: 0,
    ),
    cardTheme: CardThemeData(
      elevation: 1,
      color: NexrideMerchantColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: NexrideMerchantColors.border),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: NexrideMerchantColors.gold,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: NexrideMerchantColors.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: NexrideMerchantColors.border),
      ),
    ),
  );
}

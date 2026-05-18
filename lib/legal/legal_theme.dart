import 'package:flutter/material.dart';

/// NexRide Trust & Legal Center visual system (cream / gold African super-app tone).
abstract final class LegalTheme {
  static const Color cream = Color(0xFFF7F2EA);
  static const Color creamDeep = Color(0xFFEDE4D6);
  static const Color gold = Color(0xFFD4AF37);
  static const Color goldDark = Color(0xFF8F671C);
  static const Color goldSoft = Color(0xFFE9D7A4);
  static const Color ink = Color(0xFF1A1612);
  static const Color inkMuted = Color(0xFF5C5348);
  static const Color card = Colors.white;
  static const Color divider = Color(0xFFE2D8C8);

  static ThemeData readerTheme() {
    return ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: cream,
      colorScheme: ColorScheme.fromSeed(
        seedColor: gold,
        primary: goldDark,
        surface: cream,
        brightness: Brightness.light,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: cream,
        foregroundColor: ink,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        centerTitle: false,
      ),
      textTheme: const TextTheme(
        headlineSmall: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w800,
          color: ink,
          height: 1.25,
        ),
        titleMedium: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w700,
          color: ink,
          height: 1.3,
        ),
        bodyMedium: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w400,
          color: inkMuted,
          height: 1.55,
        ),
        labelLarge: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: goldDark,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

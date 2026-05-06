import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'firebase_options.dart';
import 'services/rider_push_notification_service.dart';
import 'splash_screen.dart';
import 'support/app_startup_state.dart';

void main() async {
  debugPrint('APP_START');
  WidgetsFlutterBinding.ensureInitialized();
  debugPrint('FIREBASE_INIT_START');

  AppStartupState startupState = const AppStartupState(firebaseReady: false);
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    ).timeout(const Duration(seconds: 4));
    final database = FirebaseDatabase.instance;
    database.setPersistenceEnabled(true);
    database.setPersistenceCacheSizeBytes(10000000);
    startupState = const AppStartupState(firebaseReady: true);
    debugPrint('FIREBASE_INIT_OK');
    debugPrint('SPLASH_INIT_OK');
  } catch (error) {
    debugPrint('FIREBASE_INIT_FAIL error=$error');
    debugPrint('SPLASH_INIT_FAIL error=$error');
    startupState = const AppStartupState(
      firebaseReady: false,
      safeErrorMessage:
          'Unable to connect to NexRide services right now. Please sign in again.',
    );
  }

  runApp(NexRideApp(startupState: startupState));

  if (startupState.firebaseReady) {
    unawaited(
      RiderPushNotificationService.instance.initialize().catchError((Object e) {
        debugPrint('PUSH_INIT_FAIL error=$e');
      }),
    );
  }
}

class NexRideApp extends StatelessWidget {
  const NexRideApp({super.key, required this.startupState});

  final AppStartupState startupState;

  static const Color _brandGold = Color(0xFFD4AF37);
  static const Color _brandGoldSoft = Color(0xFFE9D7A4);
  static const Color _brandGoldDark = Color(0xFF8F671C);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NexRide',
      debugShowCheckedModeBanner: false,

      theme: ThemeData(
        useMaterial3: true,
        primaryColor: _brandGold,
        scaffoldBackgroundColor: Colors.white,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _brandGold,
          primary: _brandGold,
          brightness: Brightness.light,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ButtonStyle(
            backgroundColor: WidgetStateProperty.resolveWith<Color>(
              (states) => states.contains(WidgetState.disabled)
                  ? _brandGoldSoft
                  : _brandGold,
            ),
            foregroundColor: const WidgetStatePropertyAll<Color>(Colors.black),
            elevation: WidgetStateProperty.resolveWith<double>(
              (states) => states.contains(WidgetState.disabled) ? 0 : 4,
            ),
            shadowColor: WidgetStateProperty.resolveWith<Color>(
              (states) => _brandGold.withValues(
                alpha: states.contains(WidgetState.disabled) ? 0.0 : 0.28,
              ),
            ),
            padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
              EdgeInsets.symmetric(horizontal: 20, vertical: 15),
            ),
            shape: WidgetStatePropertyAll<RoundedRectangleBorder>(
              RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
                side: const BorderSide(color: _brandGoldDark),
              ),
            ),
            textStyle: const WidgetStatePropertyAll<TextStyle>(
              TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: ButtonStyle(
            backgroundColor: WidgetStateProperty.resolveWith<Color>(
              (states) => states.contains(WidgetState.disabled)
                  ? _brandGoldSoft
                  : _brandGold,
            ),
            foregroundColor: const WidgetStatePropertyAll<Color>(Colors.black),
            padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
              EdgeInsets.symmetric(horizontal: 20, vertical: 15),
            ),
            shape: WidgetStatePropertyAll<RoundedRectangleBorder>(
              RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
                side: const BorderSide(color: _brandGoldDark),
              ),
            ),
            textStyle: const WidgetStatePropertyAll<TextStyle>(
              TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ),
      ),

      // START APP WITH SPLASH SCREEN
      home: SplashScreen(startupState: startupState),
    );
  }
}

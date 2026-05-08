import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'firebase_options.dart';
import 'payment_methods_screen.dart';
import 'services/rider_ride_cloud_functions_service.dart';
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

class NexRideApp extends StatefulWidget {
  const NexRideApp({super.key, required this.startupState});

  final AppStartupState startupState;

  @override
  State<NexRideApp> createState() => _NexRideAppState();
}

class _NexRideAppState extends State<NexRideApp> {
  static const Color _brandGold = Color(0xFFD4AF37);
  static const Color _brandGoldSoft = Color(0xFFE9D7A4);
  static const Color _brandGoldDark = Color(0xFF8F671C);
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();
  final RiderRideCloudFunctionsService _rideCloud =
      RiderRideCloudFunctionsService.instance;
  StreamSubscription<Uri>? _deepLinkSubscription;
  bool _handlingCardLink = false;

  @override
  void initState() {
    super.initState();
    _initDeepLinks();
  }

  Future<void> _initDeepLinks() async {
    final appLinks = AppLinks();
    _deepLinkSubscription = appLinks.uriLinkStream.listen(_handleDeepLinkUri);
    final initial = await appLinks.getInitialLink();
    if (initial != null) {
      await _handleDeepLinkUri(initial);
    }
  }

  bool _isCardLinkUri(Uri uri) {
    return uri.scheme.toLowerCase() == 'nexride' &&
        uri.host.toLowerCase() == 'card-link-complete';
  }

  Future<void> _handleDeepLinkUri(Uri uri) async {
    if (!_isCardLinkUri(uri) || _handlingCardLink) {
      return;
    }
    _handlingCardLink = true;
    try {
      final txRef = (uri.queryParameters['tx_ref'] ?? '').trim();
      final transactionId = (uri.queryParameters['transaction_id'] ?? '').trim();
      final reference = txRef.isNotEmpty ? txRef : transactionId;
      final user = FirebaseAuth.instance.currentUser;
      final riderId = (user?.uid ?? '').trim();
      if (reference.isEmpty || riderId.isEmpty) {
        _showSnack('Unable to verify card link yet. Please try again.');
        return;
      }
      _showLoadingDialog();
      final verify = await _rideCloud.verifyFlutterwavePayment(
        reference: reference,
        transactionId: transactionId.isEmpty ? null : transactionId,
        verifyCardLinkOnly: true,
      );
      _hideLoadingDialog();
      if (verify['success'] == true) {
        _showSnack('Card linked successfully!');
        final nav = _navigatorKey.currentState;
        if (nav != null) {
          await nav.push(
            MaterialPageRoute<void>(
              builder: (_) => PaymentMethodsScreen(riderId: riderId),
            ),
          );
        }
      } else {
        final reason = (verify['reason'] ?? '').toString().trim();
        _showSnack(
          reason.isNotEmpty
              ? 'Card verification failed: $reason'
              : 'Card verification failed. Please try again.',
        );
      }
    } catch (error) {
      _hideLoadingDialog();
      _showSnack('Card verification failed: $error');
    } finally {
      _handlingCardLink = false;
    }
  }

  void _showLoadingDialog() {
    final context = _navigatorKey.currentContext;
    if (context == null) {
      return;
    }
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
  }

  void _hideLoadingDialog() {
    final nav = _navigatorKey.currentState;
    if (nav?.canPop() ?? false) {
      nav?.pop();
    }
  }

  void _showSnack(String message) {
    _messengerKey.currentState?.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    _deepLinkSubscription?.cancel();
    super.dispose();
  }

@override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NexRide',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      scaffoldMessengerKey: _messengerKey,

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
      home: SplashScreen(startupState: widget.startupState),
    );
  }
}

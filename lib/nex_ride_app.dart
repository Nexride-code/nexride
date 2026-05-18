import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'map_screen.dart';
import 'payment_methods_screen.dart';
import 'services/rider_ride_cloud_functions_service.dart';
import 'services/rider_trip_deep_link_service.dart';
import 'splash_screen.dart';
import 'support/app_startup_state.dart';
import 'support/rider_root_navigation.dart';

/// Root navigator for post-auth routing (login, deep links) without local [BuildContext].
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

/// App-wide snackbars without a route [BuildContext].
final GlobalKey<ScaffoldMessengerState> rootScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

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
  final RiderRideCloudFunctionsService _rideCloud =
      RiderRideCloudFunctionsService.instance;
  StreamSubscription<Uri>? _deepLinkSubscription;
  bool _handlingCardLink = false;
  bool _handlingTripLink = false;

  @override
  void initState() {
    super.initState();
    _initDeepLinks();
  }

  Future<void> _initDeepLinks() async {
    try {
      final appLinks = AppLinks();
      _deepLinkSubscription = appLinks.uriLinkStream.listen(_handleDeepLinkUri);
      final initial = await appLinks.getInitialLink();
      if (initial != null) {
        await _handleDeepLinkUri(initial);
      }
    } catch (e, st) {
      debugPrint('DEEP_LINK_INIT_FAIL error=$e');
      debugPrintStack(label: 'DEEP_LINK_INIT', stackTrace: st);
    }
  }

  bool _isCardLinkUri(Uri uri) {
    return uri.scheme.toLowerCase() == 'nexride' &&
        uri.host.toLowerCase() == 'card-link-complete';
  }

  Future<void> _handleDeepLinkUri(Uri uri) async {
    final tripLinks = RiderTripDeepLinkService.instance;
    if (tripLinks.looksLikeTripDeepLink(uri)) {
      await _handleTripDeepLink(uri);
      return;
    }

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
        await riderRootPush(
          PaymentMethodsScreen(riderId: riderId),
          logTag: 'DEEP_LINK_CARD_METHODS',
        );
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

  Future<void> _handleTripDeepLink(Uri uri) async {
    if (_handlingTripLink) {
      return;
    }
    _handlingTripLink = true;
    final svc = RiderTripDeepLinkService.instance;
    try {
      await svc.logOpen(uri);
      final rideId = svc.parseTripRideId(uri)?.trim() ?? '';
      final token = (uri.queryParameters['token'] ?? '').trim();
      if (rideId.isEmpty || token.isEmpty) {
        await svc.logInvalid('missing_ride_or_token');
        _showSnack('This trip link is missing details.');
        return;
      }

      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        await svc.persistPendingLink(rideId: rideId, token: token);
        _showSnack('Sign in to open this shared trip.');
        return;
      }

      final ok = await svc.verifyShareToken(rideId: rideId, token: token);
      if (!ok) {
        await svc.clearPendingLink();
        await svc.logInvalid('token_verify_failed');
        _showSnack('This trip link is invalid or expired.');
        return;
      }

      await svc.clearPendingLink();

      if (rootNavigatorKey.currentState == null) {
        return;
      }

      unawaited(() async {
        await riderRootPush(
          MapScreen(initialOpenRideId: rideId),
          logTag: 'DEEP_LINK_TRIP_MAP',
        );
        await svc.logNavigated(rideId);
      }());
    } finally {
      _handlingTripLink = false;
    }
  }

  void _showLoadingDialog() {
    final context = rootNavigatorKey.currentContext;
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
    final nav = rootNavigatorKey.currentState;
    if (nav?.canPop() ?? false) {
      nav?.pop();
    }
  }

  void _showSnack(String message) {
    rootScaffoldMessengerKey.currentState?.showSnackBar(
      SnackBar(content: Text(message)),
    );
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
      navigatorKey: rootNavigatorKey,
      scaffoldMessengerKey: rootScaffoldMessengerKey,
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
      home: SplashScreen(startupState: widget.startupState),
    );
  }
}

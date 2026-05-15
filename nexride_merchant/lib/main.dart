import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'fcm_background.dart';
import 'firebase_options.dart';
import 'screens/merchant_bootstrap_screen.dart';
import 'services/merchant_connectivity.dart';
import 'services/merchant_payment_return_bus.dart';
import 'state/merchant_app_state.dart';
import 'theme/merchant_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  unawaited(_initMerchantPaymentDeepLinks());
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<MerchantAppState>(
          create: (_) => MerchantAppState(),
        ),
        ChangeNotifierProvider<MerchantConnectivity>(
          create: (_) => MerchantConnectivity(),
        ),
      ],
      child: const NexrideMerchantApp(),
    ),
  );
}

Future<void> _initMerchantPaymentDeepLinks() async {
  final appLinks = AppLinks();
  appLinks.uriLinkStream.listen(_handleMerchantPaymentUri);
  final initial = await appLinks.getInitialLink();
  if (initial != null) {
    await _handleMerchantPaymentUri(initial);
  }
}

Future<void> _handleMerchantPaymentUri(Uri uri) async {
  final scheme = uri.scheme.toLowerCase();
  final host = uri.host.toLowerCase();
  if (scheme != 'nexride-merchant') {
    return;
  }
  if (host != 'pay' && !uri.path.contains('flutterwave-return')) {
    return;
  }
  final txRef = (uri.queryParameters['tx_ref'] ?? '').trim();
  final status = (uri.queryParameters['status'] ?? '').trim();
  final flow = (uri.queryParameters['flow'] ?? '').trim();
  final merchantId = (uri.queryParameters['merchantId'] ?? '').trim();
  final transactionId = (uri.queryParameters['transaction_id'] ?? '').trim();
  debugPrint(
    '[merchant_payment_return] deep_link tx_ref=$txRef status=$status flow=$flow merchantId=$merchantId',
  );
  if (txRef.isEmpty && transactionId.isEmpty) {
    return;
  }
  MerchantPaymentReturnBus.instance.publish(
    MerchantPaymentReturnEvent(
      txRef: txRef.isNotEmpty ? txRef : transactionId,
      transactionId: transactionId.isEmpty ? null : transactionId,
      status: status.isEmpty ? null : status,
      flow: flow.isEmpty ? null : flow,
      merchantId: merchantId.isEmpty ? null : merchantId,
    ),
  );
}

class NexrideMerchantApp extends StatelessWidget {
  const NexrideMerchantApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'NexRide Merchant',
      theme: buildMerchantTheme(),
      home: const MerchantBootstrapScreen(),
    );
  }
}

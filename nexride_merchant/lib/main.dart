import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'fcm_background.dart';
import 'firebase_options.dart';
import 'screens/merchant_bootstrap_screen.dart';
import 'services/merchant_connectivity.dart';
import 'state/merchant_app_state.dart';
import 'theme/merchant_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
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

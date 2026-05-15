import 'package:flutter/material.dart';

import 'merchant_portal_routes.dart';
import 'merchant_theme.dart';
import 'screens/merchant_dashboard_screen.dart';
import 'screens/merchant_entry_screens.dart';
import 'screens/merchant_login_screen.dart';
import 'screens/merchant_onboarding_screen.dart';
import 'screens/merchant_signup_screen.dart';

/// Standalone merchant onboarding / status portal (hosted at `/merchant/`).
class MerchantPortalApp extends StatelessWidget {
  const MerchantPortalApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'NexRide Merchant',
      theme: merchantPortalTheme(),
      initialRoute: MerchantPortalRoutes.root,
      routes: <String, WidgetBuilder>{
        MerchantPortalRoutes.root: (_) => const MerchantLandingScreen(),
        MerchantPortalRoutes.login: (_) => const MerchantLoginScreen(),
        MerchantPortalRoutes.signup: (_) => const MerchantSignupScreen(),
        MerchantPortalRoutes.onboarding: (_) =>
            const MerchantOnboardingScreen(),
        MerchantPortalRoutes.dashboard: (_) => const MerchantDashboardScreen(),
      },
    );
  }
}

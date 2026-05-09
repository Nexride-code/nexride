import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';

import 'firebase_options.dart';
import 'src/app_router.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  setUrlStrategy(PathUrlStrategy());
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const NexRideWebsiteApp());
}

class NexRideWebsiteApp extends StatelessWidget {
  const NexRideWebsiteApp({super.key});

  @override
  Widget build(BuildContext context) {
    final baseTheme = ThemeData(
      useMaterial3: true,
      colorSchemeSeed: const Color(0xFFC9A227),
      brightness: Brightness.light,
    );
    final dark = ThemeData(
      useMaterial3: true,
      colorSchemeSeed: const Color(0xFFC9A227),
      brightness: Brightness.dark,
    );
    return MaterialApp.router(
      title: 'NexRide Africa',
      debugShowCheckedModeBanner: false,
      theme: baseTheme,
      darkTheme: dark,
      themeMode: ThemeMode.system,
      routerConfig: buildRouter(),
    );
  }
}

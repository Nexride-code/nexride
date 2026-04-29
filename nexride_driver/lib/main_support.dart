import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_web_plugins/url_strategy.dart';

import 'support_portal/support_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) {
    usePathUrlStrategy();
  }
  final startupUri = Uri.base;
  configureSupportErrorHandling(startupUri: startupUri);
  final initialization = initializeSupportFirebase();
  runApp(
    SupportApp(
      initialization: initialization,
      startupUri: startupUri,
    ),
  );
}

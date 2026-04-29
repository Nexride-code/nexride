import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_web_plugins/url_strategy.dart';

import 'admin/admin_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) {
    usePathUrlStrategy();
  }
  final startupUri = Uri.base;
  final startupRoute =
      WidgetsBinding.instance.platformDispatcher.defaultRouteName;

  configureAdminErrorHandling(startupUri: startupUri);
  logAdminStartup(
    'main() starting route=$startupRoute uri=$startupUri mode=${kDebugMode ? 'debug' : 'release'}',
  );

  final initialization = initializeAdminFirebase();
  logAdminStartup(
    'Booting standalone AdminApp only; driver startup is disabled for this entrypoint.',
  );
  runApp(
    AdminApp(
      initialization: initialization,
      startupUri: startupUri,
    ),
  );
}

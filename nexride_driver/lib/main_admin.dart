import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_web_plugins/url_strategy.dart';

import 'admin/admin_app.dart';

Future<void> main() async {
  final tStart = DateTime.now().toIso8601String();
  debugPrint('[main_admin] start t=$tStart entrypoint=lib/main_admin.dart');
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
  debugPrint('[main_admin] before runApp t=${DateTime.now().toIso8601String()}');
  runApp(
    AdminApp(
      initialization: initialization,
      startupUri: startupUri,
      enableRealtimeBadgeListeners: false,
    ),
  );
  debugPrint('[main_admin] after runApp t=${DateTime.now().toIso8601String()}');
}

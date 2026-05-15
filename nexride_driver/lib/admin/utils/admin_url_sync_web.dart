import 'dart:js_interop';

import 'package:web/web.dart';

import '../admin_config.dart';

void adminUrlSyncDriverOpen(String driverId, {String? tab}) {
  final String enc = Uri.encodeComponent(driverId);
  final String q = (tab != null && tab.trim().isNotEmpty)
      ? '?tab=${Uri.encodeQueryComponent(tab.trim())}'
      : '';
  final String path = '${AdminPortalRoutePaths.adminPrefix}'
      '${AdminPortalRoutePaths.drivers}/$enc$q';
  window.history.pushState(null, '', path);
}

void adminUrlSyncDriverClose() {
  final String path =
      '${AdminPortalRoutePaths.adminPrefix}${AdminPortalRoutePaths.drivers}';
  window.history.replaceState(null, '', path);
}

void adminUrlSyncReplaceDriverTab(String driverId, {String? tab}) {
  final String enc = Uri.encodeComponent(driverId);
  final String q = (tab != null && tab.trim().isNotEmpty)
      ? '?tab=${Uri.encodeQueryComponent(tab.trim())}'
      : '';
  final String path = '${AdminPortalRoutePaths.adminPrefix}'
      '${AdminPortalRoutePaths.drivers}/$enc$q';
  window.history.replaceState(window.history.state, '', path);
}

void Function() adminUrlSyncListenPop(void Function(Uri uri) onUri) {
  void handler(Event _) {
    onUri(Uri.base);
  }

  final JSFunction jsHandler = handler.toJS;
  window.addEventListener('popstate', jsHandler);
  return () {
    window.removeEventListener('popstate', jsHandler);
  };
}

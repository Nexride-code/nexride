/// No-op outside web.
void adminUrlSyncDriverOpen(String driverId, {String? tab}) {}

void adminUrlSyncDriverClose() {}

void adminUrlSyncReplaceDriverTab(String driverId, {String? tab}) {}

/// Returns dispose callback.
void Function() adminUrlSyncListenPop(void Function(Uri uri) onUri) {
  return () {};
}

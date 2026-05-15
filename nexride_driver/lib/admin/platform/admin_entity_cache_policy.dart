import 'package:flutter/foundation.dart';

/// Tab-scoped TTL resolver shared by all entity drawers (Phase 3Y / 4J).
@immutable
class AdminEntityCachePolicy {
  const AdminEntityCachePolicy(this._ttlByTab, {this.fallback});

  final Map<String, Duration> _ttlByTab;
  final Duration? fallback;

  /// Driver drawer defaults (overview / wallet / trips / audit).
  factory AdminEntityCachePolicy.driverDrawer() {
    return const AdminEntityCachePolicy(
      <String, Duration>{
        'overview': Duration(seconds: 30),
        'wallet': Duration(seconds: 10),
        'trips': Duration(seconds: 15),
        'audit': Duration(seconds: 5),
      },
      fallback: Duration(seconds: 60),
    );
  }

  Duration? cacheTtlForTab(String tabId) {
    return _ttlByTab[tabId] ?? fallback;
  }

  bool isStale(String tabId, int resolvedAtEpochMs, DateTime now) {
    final Duration? ttl = cacheTtlForTab(tabId);
    if (ttl == null) {
      return false;
    }
    return now.millisecondsSinceEpoch - resolvedAtEpochMs > ttl.inMilliseconds;
  }
}

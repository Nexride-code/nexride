import 'package:flutter/foundation.dart';

import '../widgets/admin_entity_drawer_controller.dart';
import 'admin_cache_invalidation_registry.dart';
import 'admin_entity_cache_policy.dart';

/// Coordinates drawer cache policy + invalidation for one on-screen entity (Phase 4J).
@immutable
class AdminEntityTabController {
  const AdminEntityTabController({
    required this.drawer,
    required this.cachePolicy,
    required this.entityType,
    required this.entityId,
  });

  final AdminEntityDrawerController drawer;
  final AdminEntityCachePolicy cachePolicy;
  final String entityType;
  final String entityId;

  Duration? cacheTtlFor(String tabId) => cachePolicy.cacheTtlForTab(tabId);

  void invalidateForMutation(String mutationKey) {
    drawer.invalidateTabs(AdminCacheInvalidationRegistry.tabsFor(mutationKey));
  }
}

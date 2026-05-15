import 'admin_entity_payload_budget.dart';

/// Strict tab contract for entity drawers (Phase 4K).
///
/// Concrete tabs may be services or controllers; the shell drawer may wrap
/// these while migrating off ad-hoc loaders.
abstract class AdminEntityTabContract {
  String get tabId;

  Future<void> load();

  Future<void> refresh();

  void invalidate();

  void dispose();

  /// Return true when [resolvedAt] is older than [cacheTTL] policy allows.
  bool staleCheck(DateTime now, DateTime resolvedAt);

  Duration? cacheTTL();

  AdminEntityPayloadBudget payloadBudget();
}

import 'package:flutter/foundation.dart';

/// Handle passed into [AdminEntityDrawer] for cache invalidation + coordinated close
/// (Phase 3W / 3Y / 3Z).
class AdminEntityDrawerController {
  void Function(Set<String>? tabIds)? _invalidate;
  VoidCallback? _close;

  bool get isAttached => _invalidate != null;

  void attach({
    required void Function(Set<String>? tabIds) invalidateTabs,
    required VoidCallback close,
  }) {
    _invalidate = invalidateTabs;
    _close = close;
  }

  void detach() {
    _invalidate = null;
    _close = null;
  }

  /// When [tabIds] is null, all cached tabs for this drawer are cleared.
  void invalidateTabs([Set<String>? tabIds]) {
    _invalidate?.call(tabIds);
  }

  void close() {
    _close?.call();
  }
}

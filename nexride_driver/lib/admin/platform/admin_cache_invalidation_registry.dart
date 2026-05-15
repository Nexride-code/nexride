/// Maps a mutation name (usually [AdminActionExecutor] `actionName`) to drawer tab ids
/// that must be refreshed (Phase 4P client-side slice).
abstract final class AdminCacheInvalidationRegistry {
  /// `null` means **invalidate every cached tab** for the active drawer.
  static Set<String>? tabsFor(String mutationKey) {
    switch (mutationKey) {
      case 'driver_approve_verification':
        return <String>{
          'overview',
          'verification',
          'audit',
          'wallet',
          'trips',
        };
      case 'driver_suspend':
        return <String>{
          'overview',
          'violations',
          'notes',
          'audit',
          'wallet',
          'trips',
        };
      case 'driver_warn':
        return <String>{
          'overview',
          'violations',
          'notes',
          'audit',
        };
      case 'driver_delete':
      case 'driver_update_status':
        return null;
      default:
        return null;
    }
  }
}

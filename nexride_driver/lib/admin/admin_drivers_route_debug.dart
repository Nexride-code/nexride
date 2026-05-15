/// Surgical isolation switches for admin web `/admin/drivers` performance hangs.
///
/// **Use one flag at a time**, rebuild admin web, deploy hosting (and functions when
/// noted), then interpret:
///
/// 1. [driversRouteStaticPlaceholder] — must stay `false` in committed code (reserved).
/// 2. [driversRouteFakeLocalDrivers] — five in-memory rows; if it hangs, table/filter
///    code is suspect; if it works, callable/decode/mapping is suspect.
/// 3. [debugMaxDriversTreeFetch] — only when using legacy tree callable (see below).
///
/// **Production path** uses [useLegacyFullDriversTreeCallable] == `false` so the client
/// calls [adminListDriversPage] (paged, capped server-side) instead of loading the full tree.
library;

class AdminDriversRouteDebug {
  /// Reserved isolation flag — **must remain `false`** in production commits.
  static const bool driversRouteStaticPlaceholder = false;

  /// Five fake [AdminDriverRecord]s; **no** Firebase (debug only).
  static const bool driversRouteFakeLocalDrivers = false;

  /// Callable returns empty map (client skips HTTP); requires no server change.
  static const bool driversRouteSkipCallable = false;

  /// Step 2 — passed as `maxDrivers` to legacy `adminFetchDriversTree` when > 0.
  static const int debugMaxDriversTreeFetch = 0;

  /// When `true`, drivers list uses legacy `adminFetchDriversTree` (full or [debugMaxDriversTreeFetch] cap).
  /// When `false` (default), uses paginated `adminListDriversPage`.
  static const bool useLegacyFullDriversTreeCallable = false;
}

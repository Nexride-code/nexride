/// Whether a searching ride is still eligible for driver dispatch (popup queue).
/// - Respects [expiresAtMs] when set (rider search window).
/// - Without expiry, rejects rows older than [maxAgeMs] from the earliest of
///   created/requested timestamps (production-safe backlog cap).
/// - Does not use [onlineSessionStartedAt] (avoids rejecting fresh requests).
bool isRideRequestFreshForDispatch({
  required int createdAtMs,
  required int requestedAtMs,
  required int expiresAtMs,
  required int nowMs,
  int maxAgeMs = 90000,
}) {
  if (createdAtMs <= 0 && requestedAtMs <= 0) {
    return false;
  }

  if (expiresAtMs > 0 && expiresAtMs <= nowMs) {
    return false;
  }

  if (expiresAtMs > 0) {
    return true;
  }

  final baseMs = _earliestPositiveTimestamp(
    createdAtMs,
    requestedAtMs,
  );
  if (baseMs <= 0) {
    return false;
  }

  return nowMs - baseMs <= maxAgeMs;
}

int _earliestPositiveTimestamp(int a, int b) {
  if (a <= 0) {
    return b;
  }
  if (b <= 0) {
    return a;
  }
  return a < b ? a : b;
}

@Deprecated('Use isRideRequestFreshForDispatch')
bool isSearchRequestVisibleForCurrentDriverSession({
  required int createdAt,
  required int expiresAt,
  required int onlineSessionStartedAt,
  required int freshnessGraceMs,
  int? nowTimestamp,
}) {
  final nowMs = nowTimestamp ?? DateTime.now().millisecondsSinceEpoch;
  return isRideRequestFreshForDispatch(
    createdAtMs: createdAt,
    requestedAtMs: 0,
    expiresAtMs: expiresAt,
    nowMs: nowMs,
  );
}

bool wasPendingAcceptanceStartedBeforeExpiry({
  required int acceptRequestedAt,
  required int assignmentExpiresAt,
}) {
  if (assignmentExpiresAt <= 0) {
    return true;
  }

  if (acceptRequestedAt <= 0) {
    return false;
  }

  return acceptRequestedAt <= assignmentExpiresAt;
}

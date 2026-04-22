/// Canonical Realtime Database field names for `ride_requests/{rideId}`.
/// Rider and driver apps use **snake_case** for all fields below.
/// Rules also accept legacy `riderId` / `matchedDriverId` for creates and reads.
///
/// **Discovery (driver):** `orderByChild('market_pool').equalTo(citySlug)` only.
/// - While a request is in the open pool, set [marketPool] to the same canonical
///   slug as [market] (e.g. `lagos`). Clear [marketPool] (null) when a driver is
///   reserved or the trip leaves the pool so other drivers’ queries are not denied.
/// - Keep [market] for analytics / UI even when not indexed for discovery.
abstract final class RtdbRideRequestFields {
  static const rideId = 'ride_id';
  static const riderId = 'rider_id';
  static const driverId = 'driver_id';
  static const matchedDriverId = 'matched_driver_id';
  static const market = 'market';
  static const marketPool = 'market_pool';
  static const status = 'status';
  static const tripState = 'trip_state';
  static const paymentMethod = 'payment_method';
  static const paymentStatus = 'payment_status';
  static const settlementStatus = 'settlement_status';
  static const supportStatus = 'support_status';
  static const pickup = 'pickup';
  static const dropoff = 'dropoff';
  static const fare = 'fare';
  static const distanceKm = 'distance_km';
  static const etaMin = 'eta_min';
  static const createdAt = 'created_at';
  static const updatedAt = 'updated_at';
  static const acceptedAt = 'accepted_at';
  static const cancelledAt = 'cancelled_at';
  static const completedAt = 'completed_at';
  static const cancelReason = 'cancel_reason';
  static const expiresAt = 'expires_at';
}

String? normalizeRideMarketSlug(dynamic rawMarket) {
  final raw = rawMarket?.toString().trim().toLowerCase() ?? '';
  if (raw.isEmpty) {
    return null;
  }

  final spaced = raw
      .replaceAll(RegExp(r'[^a-z0-9]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (spaced.isEmpty) {
    return null;
  }

  bool hasAny(List<String> tokens) {
    for (final token in tokens) {
      if (spaced.contains(token)) {
        return true;
      }
    }
    return false;
  }

  if (hasAny(const <String>[
    'lagos',
    'ikeja',
    'yaba',
    'lekki',
    'ajah',
    'surulere',
    'ikoyi',
    'victoria island',
  ])) {
    return 'lagos';
  }
  if (hasAny(const <String>[
    'abuja',
    'fct',
    'federal capital territory',
    'wuse',
    'garki',
    'maitama',
    'asokoro',
  ])) {
    return 'abuja';
  }
  if (hasAny(const <String>['delta', 'asaba', 'warri', 'effurun'])) {
    return 'delta';
  }
  if (hasAny(const <String>['anambra', 'awka', 'onitsha', 'nnewi'])) {
    return 'anambra';
  }

  return spaced.replaceAll(' ', '_');
}

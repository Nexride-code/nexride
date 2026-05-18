/// Client-side offer lease validation (server is source of truth).
class DriverOfferLeaseSupport {
  DriverOfferLeaseSupport._();

  static int? leaseExpiresAtMs(Map<String, dynamic>? offer) {
    if (offer == null) return null;
    final lease = int.tryParse('${offer['lease_expires_at'] ?? ''}');
    if (lease != null && lease > 0) return lease;
    final exp = int.tryParse('${offer['expires_at'] ?? ''}');
    if (exp != null && exp > 0) return exp;
    return null;
  }

  static int popupGeneration(Map<String, dynamic>? offer) {
    if (offer == null) return 0;
    final dispatchGen = int.tryParse('${offer['dispatch_generation'] ?? ''}');
    if (dispatchGen != null && dispatchGen > 0) return dispatchGen;
    return int.tryParse('${offer['popup_generation'] ?? ''}') ?? 0;
  }

  static String? leaseId(Map<String, dynamic>? offer) {
    if (offer == null) return null;
    final id = '${offer['lease_id'] ?? ''}'.trim();
    return id.isEmpty ? null : id;
  }

  /// Returns null when valid; otherwise rejection reason for logs/UI.
  static String? rejectReason({
    required Map<String, dynamic> offer,
    required String rideId,
    required int serverNowMs,
    int? lastSeenGeneration,
    int? rideDispatchGeneration,
    String? activeAcceptedRideId,
  }) {
    if (activeAcceptedRideId != null &&
        activeAcceptedRideId.trim().isNotEmpty &&
        activeAcceptedRideId.trim() != rideId.trim()) {
      return 'active_trip_other_ride';
    }
    final exp = leaseExpiresAtMs(offer);
    if (exp != null && serverNowMs > exp) {
      return 'lease_expired';
    }
    final gen = popupGeneration(offer);
    if (lastSeenGeneration != null && gen > 0 && gen < lastSeenGeneration) {
      return 'stale_generation';
    }
    final rideGen = rideDispatchGeneration ?? 0;
    if (rideGen > 0 && gen > 0 && gen < rideGen) {
      return 'generation_mismatch';
    }
    final lid = leaseId(offer);
    if (lid == null || lid.isEmpty) {
      return 'lease_missing';
    }
    return null;
  }
}

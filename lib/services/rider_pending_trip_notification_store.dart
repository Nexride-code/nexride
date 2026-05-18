import 'package:flutter/foundation.dart';

/// Ride id from tapping the in-trip status notification (before [MapScreen] mounts).
class RiderPendingTripNotificationStore {
  RiderPendingTripNotificationStore._();

  static final RiderPendingTripNotificationStore instance =
      RiderPendingTripNotificationStore._();

  String? _rideId;
  int? _capturedAtMs;

  void captureRideId(String? rideId) {
    final normalized = rideId?.trim();
    if (normalized == null || normalized.isEmpty) {
      return;
    }
    _rideId = normalized;
    _capturedAtMs = DateTime.now().millisecondsSinceEpoch;
    debugPrint('RIDER_TRIP_NOTIFICATION_TAP rideId=$normalized');
  }

  bool get hasPendingTrip => _rideId != null && _rideId!.isNotEmpty;

  String? peekRideId() => _rideId;

  String? consumeRideId() {
    final id = _rideId;
    _rideId = null;
    _capturedAtMs = null;
    return id;
  }

  void clear() {
    _rideId = null;
    _capturedAtMs = null;
  }
}

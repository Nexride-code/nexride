/// User-visible copy aligned with canonical `trip_state` from RTDB.
abstract final class RiderTripStatusMessages {
  static const String creatingRide = 'Creating your ride…';
  static const String searchingForDriver = 'Searching for a driver…';
  static const String driverAssigned = 'Driver assigned';
  static const String driverArriving = 'Driver is on the way';
  static const String arrived = 'Driver has arrived';
  static const String tripStarted = 'Trip started';
  static const String tripCompleted = 'Trip completed';
  static const String cancelled = 'Ride cancelled';
  static const String paymentPending = 'Payment pending';
  static const String paymentFailed = 'Payment failed';

  /// Primary line for the active trip card from RTDB snapshot.
  static String headlineFromRideData(Map<String, dynamic>? ride) {
    if (ride == null || ride.isEmpty) {
      return searchingForDriver;
    }
    final tripState =
        ride['trip_state']?.toString().trim().toLowerCase() ?? '';
    final payStatus =
        ride['payment_status']?.toString().trim().toLowerCase() ?? '';

    if (payStatus == 'failed' || payStatus == 'declined') {
      return paymentFailed;
    }
    if (payStatus == 'pending' || payStatus == 'processing') {
      return paymentPending;
    }

    return switch (tripState) {
      'searching' ||
      'requested' ||
      'searching_driver' ||
      'matching' ||
      'awaiting_match' ||
      'offered' ||
      'offer_pending' =>
        searchingForDriver,
      'driver_assigned' ||
      'driver_accepted' ||
      'pending_driver_action' ||
      'pending_driver_acceptance' =>
        driverAssigned,
      'driver_arriving' => driverArriving,
      'arrived' || 'driver_arrived' => arrived,
      'in_progress' || 'trip_started' => tripStarted,
      'completed' || 'trip_completed' => tripCompleted,
      'cancelled' || 'trip_cancelled' || 'canceled' => cancelled,
      'expired' => cancelled,
      _ => searchingForDriver,
    };
  }
}

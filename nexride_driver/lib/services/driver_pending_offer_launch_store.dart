import 'package:flutter/foundation.dart';

/// Persists incoming-offer identifiers from push **before** the map screen is mounted.
///
/// NexRide stores live requests in **Realtime Database** (`ride_requests` /
/// `delivery_requests` and per-driver queues); this only holds IDs copied from FCM `data`,
/// keyed as sent by [`ride_callables.js`][] / [`delivery_callables.js`][] (`rideId`, `deliveryId`, etc.).
class DriverPendingOfferLaunchStore {
  DriverPendingOfferLaunchStore._();

  static final DriverPendingOfferLaunchStore instance =
      DriverPendingOfferLaunchStore._();

  String? _rideRequestId;
  String? _deliveryRequestId;
  int? _capturedAtMs;

  static String? _nz(String? s) {
    final t = s?.trim();
    if (t == null || t.isEmpty) {
      return null;
    }
    return t;
  }

  /// Call as soon as FCM delivers [data] ([RemoteMessage.data]) — typically during
  /// Firebase bootstrap (`getInitialMessage` / taps) **before** the driver map mounts.
  void captureFromFcmData(Map<String, dynamic> data) {
    String? pick(String key) => _nz(data[key]?.toString());

    final ride =
        pick('rideRequestId') ?? pick('rideId') ?? pick('ride_id');
    final delivery = pick('deliveryId') ?? pick('delivery_id');
    final svc = pick('serviceType')?.trim().toLowerCase() ?? '';
    final isDeliverySvc = svc == 'dispatch_delivery';

    if (delivery != null &&
        delivery.isNotEmpty &&
        (isDeliverySvc || ride == null || ride.isEmpty)) {
      _deliveryRequestId = delivery;
      _rideRequestId = null;
    } else if (ride != null && ride.isNotEmpty) {
      _rideRequestId = ride;
      _deliveryRequestId = null;
    } else {
      return;
    }
    _capturedAtMs = DateTime.now().millisecondsSinceEpoch;
    debugPrint(
      '[DRIVER_PENDING_LAUNCH_CAPTURE] ride=$_rideRequestId '
      'delivery=$_deliveryRequestId serviceType=$svc',
    );
  }

  bool get hasPendingOffer =>
      (_rideRequestId != null && _rideRequestId!.isNotEmpty) ||
      (_deliveryRequestId != null && _deliveryRequestId!.isNotEmpty);

  String? peekRideRequestId() => _rideRequestId;

  String? peekDeliveryRequestId() => _deliveryRequestId;

  int? get capturedAtMs => _capturedAtMs;

  /// Clears saved intent after the popup flow finishes or we verify the ride is unavailable.
  void clearPendingLaunchIntent() {
    _rideRequestId = null;
    _deliveryRequestId = null;
    _capturedAtMs = null;
  }
}

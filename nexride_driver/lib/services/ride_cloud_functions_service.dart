import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// HTTPS callables for ride lifecycle (server is source of truth).
class RideCloudFunctionsService {
  RideCloudFunctionsService({FirebaseFunctions? functions})
      : _functions =
            functions ?? FirebaseFunctions.instanceFor(region: 'us-central1');

  final FirebaseFunctions _functions;
  static const Duration _kCallableTimeout = Duration(seconds: 30);

  Future<Map<String, dynamic>> _call(
    String name,
    Map<String, dynamic> payload,
  ) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      await user.getIdToken(true);
    }
    final callable = _functions.httpsCallable(
      name,
      options: HttpsCallableOptions(timeout: _kCallableTimeout),
    );
    final result = await callable.call(payload).timeout(_kCallableTimeout);
    final data = result.data;
    if (data is Map) {
      return Map<String, dynamic>.from(data);
    }
    return <String, dynamic>{};
  }

  /// Backend-controlled accept (driver uid from auth).
  Future<Map<String, dynamic>> acceptRide({required String rideId}) =>
      _call('acceptRide', <String, dynamic>{
        'rideId': rideId,
        'ride_id': rideId,
        'requestId': rideId,
        'tripId': rideId,
      });

  Future<Map<String, dynamic>> driverEnroute({required String rideId}) =>
      _call('driverEnroute', <String, dynamic>{'rideId': rideId});

  Future<Map<String, dynamic>> driverArrived({required String rideId}) =>
      _call('driverArrived', <String, dynamic>{
        'rideId': rideId,
        'ride_id': rideId,
        'requestId': rideId,
        'tripId': rideId,
      });

  Future<Map<String, dynamic>> startTrip({required String rideId}) =>
      _call('startTrip', <String, dynamic>{'rideId': rideId});

  Future<Map<String, dynamic>> completeTrip({required String rideId}) =>
      _call('completeTrip', <String, dynamic>{'rideId': rideId});

  Future<Map<String, dynamic>> cancelRide({
    required String rideId,
    required String cancelReason,
  }) =>
      _call('cancelRide', <String, dynamic>{
        'rideId': rideId,
        'cancel_reason': cancelReason,
      });

  /// @deprecated Prefer [cancelRide]
  Future<Map<String, dynamic>> cancelRideRequest({
    required String rideId,
    required String cancelReason,
  }) =>
      cancelRide(rideId: rideId, cancelReason: cancelReason);

  Future<Map<String, dynamic>> patchRideRequestMetadata({
    required String rideId,
    required Map<String, dynamic> patch,
  }) =>
      _call('patchRideRequestMetadata', <String, dynamic>{
        'rideId': rideId,
        'patch': patch,
      });

  Future<Map<String, dynamic>> initiateFlutterwavePayment({
    required String rideId,
    required double amount,
    String currency = 'NGN',
    String? redirectUrl,
    String? customerName,
    String? email,
  }) =>
      _call('initiateFlutterwavePayment', <String, dynamic>{
        'rideId': rideId,
        'amount': amount,
        'currency': currency,
        if (redirectUrl != null) 'redirect_url': redirectUrl,
        if (customerName != null) 'customer_name': customerName,
        if (email != null) 'email': email,
      });

  Future<Map<String, dynamic>> verifyFlutterwavePayment({
    required String rideId,
    required String reference,
  }) =>
      _call('verifyFlutterwavePayment', <String, dynamic>{
        'rideId': rideId,
        'reference': reference,
      });

  Future<Map<String, dynamic>> getRideCallRtcToken({
    required String rideId,
    required String uid,
    String? channelName,
    bool force = false,
    bool forceClearStale = true,
  }) async {
    final payload = <String, dynamic>{
      'rideId': rideId,
      'ride_id': rideId,
      'requestId': rideId,
      'tripId': rideId,
      'uid': uid,
      if (channelName != null && channelName.trim().isNotEmpty)
        'channelName': channelName.trim(),
      'force': force,
      'force_clear_stale': forceClearStale,
    };
    final callable = _functions.httpsCallable(
      'generateAgoraToken',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
    );
    final result = await callable.call(payload).timeout(_kCallableTimeout);
    final data = result.data;
    if (data is Map) {
      return Map<String, dynamic>.from(data);
    }
    return <String, dynamic>{};
  }

  Future<Map<String, dynamic>> clearStaleRideCall({
    required String rideId,
  }) =>
      _call('clearStaleRideCall', <String, dynamic>{
        'rideId': rideId,
        'ride_id': rideId,
      });

  Future<Map<String, dynamic>> registerDevicePushToken({
    required String token,
    required String platform,
  }) =>
      _call('registerDevicePushToken', <String, dynamic>{
        'token': token,
        'platform': platform,
        'app': 'driver',
      });

  Future<Map<String, dynamic>> listDeliveryRegions() =>
      _call('listDeliveryRegions', <String, dynamic>{});

  Future<Map<String, dynamic>> validateServiceLocation({
    required String regionId,
    required String cityId,
    required String service,
  }) =>
      _call('validateServiceLocation', <String, dynamic>{
        'region_id': regionId,
        'city_id': cityId,
        'service': service,
      });

  /// Server-authoritative go-online (availability mode, rollout, verification).
  Future<Map<String, dynamic>> setDriverOnline({
    required String availabilityMode,
    required String dispatchMarket,
    double? latitude,
    double? longitude,
    String? serviceRegionId,
    String? serviceCityId,
    String? selectedServiceAreaName,
  }) =>
      _call('setDriverOnline', <String, dynamic>{
        'driver_availability_mode': availabilityMode,
        'availability_mode': availabilityMode,
        'dispatch_market': dispatchMarket,
        if (latitude != null) 'latitude': latitude,
        if (longitude != null) 'longitude': longitude,
        if (serviceRegionId != null && serviceRegionId.trim().isNotEmpty)
          'service_region_id': serviceRegionId.trim(),
        if (serviceCityId != null && serviceCityId.trim().isNotEmpty)
          'service_city_id': serviceCityId.trim(),
        if (selectedServiceAreaName != null &&
            selectedServiceAreaName.trim().isNotEmpty)
          'selected_service_area_name': selectedServiceAreaName.trim(),
      });

  Future<Map<String, dynamic>> setDriverOffline() =>
      _call('setDriverOffline', <String, dynamic>{});

  /// Clears stale active-trip pointers, profile trip summary, and expired offers (server-owned).
  Future<Map<String, dynamic>> refreshDriverAvailability({
    String source = 'driver_app',
  }) =>
      _call('refreshDriverAvailability', <String, dynamic>{
        'source': source,
      });

  /// Server-authoritative decline: clears offer queue/fanout and marks driver exhausted for that ride only.
  Future<Map<String, dynamic>> withdrawDriverOffer({
    required String rideId,
    String reason = 'driver_declined',
  }) =>
      _call('withdrawDriverOffer', <String, dynamic>{
        'rideId': rideId,
        'ride_id': rideId,
        'reason': reason,
        'withdraw_reason': reason,
      });

  /// Clears stale active-trip pointers blocking new offers (server-owned).
  Future<Map<String, dynamic>> recordDriverOfferPopupAck({
    required String rideId,
    required String leaseId,
    required int generation,
    required int popupRenderedAtMs,
  }) =>
      _call('recordDriverOfferPopupAck', <String, dynamic>{
        'rideId': rideId,
        'ride_id': rideId,
        'lease_id': leaseId,
        'leaseId': leaseId,
        'generation': generation,
        'popup_generation': generation,
        'popup_rendered_at': popupRenderedAtMs,
      });

  Future<Map<String, dynamic>> repairDriverDispatchBlockers({
    required String driverId,
    String incomingRideId = '',
    String source = 'driver_app',
  }) =>
      _call('repairDriverDispatchBlockers', <String, dynamic>{
        'driverId': driverId,
        'driver_id': driverId,
        if (incomingRideId.trim().isNotEmpty) 'incomingRideId': incomingRideId.trim(),
        if (incomingRideId.trim().isNotEmpty) 'incoming_ride_id': incomingRideId.trim(),
        'source': source,
      });

  Future<Map<String, dynamic>> driverUpdateLiveLocation({
    required double latitude,
    required double longitude,
  }) =>
      _call('driverUpdateLiveLocation', <String, dynamic>{
        'latitude': latitude,
        'longitude': longitude,
      });

  Future<Map<String, dynamic>> escalateSafetyIncident({
    required String rideId,
    required String riderId,
    required String driverId,
    required String flagType,
    required String details,
    String sourceFlagId = '',
    String serviceType = 'ride',
  }) =>
      _call('escalateSafetyIncident', <String, dynamic>{
        'rideId': rideId,
        'riderId': riderId,
        'driverId': driverId,
        'serviceType': serviceType,
        'flagType': flagType,
        'details': details,
        if (sourceFlagId.trim().isNotEmpty) 'sourceFlagId': sourceFlagId.trim(),
      });

  Future<Map<String, dynamic>> verifyPayment({required String reference}) =>
      _call('verifyPayment', <String, dynamic>{
        'reference': reference,
        'tx_ref': reference,
      });

  Future<Map<String, dynamic>> driverStartSubscriptionFlutterwaveCard({
    required String driverId,
    required String planType,
    String? email,
    String? redirectUrl,
  }) =>
      _call('driverStartSubscriptionFlutterwaveCard', <String, dynamic>{
        'driverId': driverId,
        'driver_id': driverId,
        'planType': planType,
        'plan_type': planType,
        if (email != null && email.trim().isNotEmpty) 'email': email.trim(),
        if (redirectUrl != null && redirectUrl.trim().isNotEmpty)
          'redirect_url': redirectUrl.trim(),
      });

  Future<Map<String, dynamic>> driverCreateSubscriptionFlutterwaveVa({
    required String driverId,
    required String planType,
    String? email,
  }) =>
      _call('driverCreateSubscriptionFlutterwaveVa', <String, dynamic>{
        'driverId': driverId,
        'driver_id': driverId,
        'planType': planType,
        'plan_type': planType,
        if (email != null && email.trim().isNotEmpty) 'email': email.trim(),
      });

  Future<Map<String, dynamic>> driverPaySubscriptionFromWallet({
    required String driverId,
    required String planType,
  }) =>
      _call('driverPaySubscriptionFromWallet', <String, dynamic>{
        'driverId': driverId,
        'driver_id': driverId,
        'planType': planType,
        'plan_type': planType,
      });

  /// Canonical subscription amounts (same as payment callables). Display only — payment still server-resolved.
  Future<Map<String, dynamic>> getDriverSubscriptionPricing({required String driverId}) =>
      _call('getDriverSubscriptionPricing', <String, dynamic>{
        'driverId': driverId,
        'driver_id': driverId,
      });

  /// Fare/pricing config for driver UI (RTDB `app_config/pricing` is not client-readable).
  Future<Map<String, dynamic>> getAppPricingConfig() =>
      _call('getAppPricingConfig', <String, dynamic>{});

  Future<Map<String, dynamic>> driverStartWalletTopUpFlutterwaveCard({
    required String driverId,
    required int amountNgn,
    String? email,
    String? redirectUrl,
  }) =>
      _call('driverStartWalletTopUpFlutterwaveCard', <String, dynamic>{
        'driverId': driverId,
        'driver_id': driverId,
        'amount_ngn': amountNgn,
        'amount': amountNgn,
        if (email != null && email.trim().isNotEmpty) 'email': email.trim(),
        if (redirectUrl != null && redirectUrl.trim().isNotEmpty)
          'redirect_url': redirectUrl.trim(),
      });

  Future<Map<String, dynamic>> driverCreateWalletTopUpFlutterwaveVa({
    required String driverId,
    required int amountNgn,
    String? email,
  }) =>
      _call('driverCreateWalletTopUpFlutterwaveVa', <String, dynamic>{
        'driverId': driverId,
        'driver_id': driverId,
        'amount_ngn': amountNgn,
        'amount': amountNgn,
        if (email != null && email.trim().isNotEmpty) 'email': email.trim(),
      });

  Future<Map<String, dynamic>> getNexrideOfficialBankAccount() =>
      _call('getNexrideOfficialBankAccount', <String, dynamic>{});

  Future<Map<String, dynamic>> applyRideWaitFeeInterval({
    required String rideId,
  }) =>
      _call('applyRideWaitFeeInterval', <String, dynamic>{
        'rideId': rideId,
        'ride_id': rideId,
      });

  Future<Map<String, dynamic>> submitTripRating({
    required String rideId,
    required double rating,
    required String role,
  }) =>
      _call('submitTripRating', <String, dynamic>{
        'rideId': rideId,
        'ride_id': rideId,
        'rating': rating,
        'role': role,
      });

  Future<Map<String, dynamic>> driverConfirmBankTransferPayment({
    required String rideId,
    required String reference,
  }) =>
      _call('driverConfirmBankTransferPayment', <String, dynamic>{
        'rideId': rideId,
        'reference': reference,
        'tx_ref': reference,
      });
}

bool rideCallableSucceeded(Map<String, dynamic>? response) =>
    response != null && response['success'] == true;

String rideCallableReason(Map<String, dynamic>? response) {
  final r = response?['reason']?.toString().trim() ?? '';
  return r.isEmpty ? 'unknown' : r;
}

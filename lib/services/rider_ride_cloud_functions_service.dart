import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// HTTPS callables — Realtime Database `ride_requests` writes are server-side only.
class RiderRideCloudFunctionsService {
  RiderRideCloudFunctionsService._internal({FirebaseFunctions? functions})
      : _functions =
            functions ?? FirebaseFunctions.instanceFor(region: 'us-central1');

  /// Single shared client (field initializers cannot reference sibling fields).
  static final RiderRideCloudFunctionsService instance =
      RiderRideCloudFunctionsService._internal();

  factory RiderRideCloudFunctionsService({FirebaseFunctions? functions}) {
    if (functions != null) {
      return RiderRideCloudFunctionsService._internal(functions: functions);
    }
    return instance;
  }

  final FirebaseFunctions _functions;
  static const Duration _kCallableTimeout = Duration(seconds: 30);
  static const int _kMaxAttempts = 2;

  Future<Map<String, dynamic>> _call(
    String name,
    Map<String, dynamic> payload, {
    Duration? timeout,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      await user.getIdToken(true);
    }
    final effectiveTimeout = timeout ?? _kCallableTimeout;
    final callable = _functions.httpsCallable(
      name,
      options: HttpsCallableOptions(timeout: effectiveTimeout),
    );
    debugPrint(
      'API_REQUEST_START name=$name region=us-central1 '
      'project=${_functions.app.options.projectId} timeout_ms=${effectiveTimeout.inMilliseconds}',
    );
    dynamic result;
    Object? lastError;
    for (var attempt = 1; attempt <= _kMaxAttempts; attempt++) {
      try {
        result = await callable.call(payload).timeout(effectiveTimeout);
        break;
      } on TimeoutException catch (error) {
        lastError = TimeoutException(
          'Request timed out while contacting backend.',
          effectiveTimeout,
        );
        debugPrint(
          'API_TIMEOUT name=$name region=us-central1 timeout_ms=${effectiveTimeout.inMilliseconds} '
          'attempt=$attempt error=$error',
        );
      } on FirebaseFunctionsException catch (error) {
        lastError = error;
        final code = error.code.trim().toLowerCase();
        if (code == 'not-found') {
          debugPrint(
            'CALLABLE_NOT_FOUND name=$name project=${_functions.app.options.projectId} region=us-central1',
          );
        }
        final isUnreachable =
            code == 'unavailable' ||
            code == 'deadline-exceeded' ||
            code == 'internal';
        if (isUnreachable) {
          debugPrint(
            'FUNCTION_UNREACHABLE name=$name code=${error.code} message=${error.message}',
          );
        }
        debugPrint(
          'API_REQUEST_FAIL name=$name code=${error.code} message=${error.message} details=${error.details} attempt=$attempt',
        );
        if (!isUnreachable) {
          rethrow;
        }
      } catch (error) {
        lastError = error;
        debugPrint('API_REQUEST_FAIL name=$name error=$error attempt=$attempt');
      }
      if (attempt < _kMaxAttempts) {
        await Future<void>.delayed(const Duration(milliseconds: 450));
      }
    }
    if (result == null && lastError != null) {
      throw lastError;
    }
    final data = result.data;
    debugPrint('API_REQUEST_SUCCESS name=$name');
    if (data is Map) {
      return Map<String, dynamic>.from(data);
    }
    return <String, dynamic>{};
  }

  /// Body must match backend [createRideRequest] (snake_case + optional `ride_metadata`).
  Future<Map<String, dynamic>> createRideRequest(
    Map<String, dynamic> body,
  ) =>
      _call(
        'createRideRequest',
        body,
        timeout: const Duration(seconds: 45),
      );

  /// Enabled rollout regions + cities (server-filtered).
  Future<Map<String, dynamic>> listDeliveryRegions({
    String? riderSelectedRegionId,
    String? riderSelectedCityId,
  }) =>
      _call(
        'listDeliveryRegions',
        <String, dynamic>{
          if (riderSelectedRegionId != null && riderSelectedRegionId.trim().isNotEmpty)
            'rider_selected_region_id': riderSelectedRegionId.trim(),
          if (riderSelectedCityId != null && riderSelectedCityId.trim().isNotEmpty)
            'rider_selected_city_id': riderSelectedCityId.trim(),
        },
      );

  /// Validates state + city + service flags before booking / dispatch.
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

  Future<Map<String, dynamic>> initiateFlutterwaveRideIntent(
    Map<String, dynamic> body,
  ) =>
      _call(
        'initiateFlutterwaveRideIntent',
        body,
        timeout: const Duration(seconds: 45),
      );

  Future<Map<String, dynamic>> initiateFlutterwaveCardLinkIntent(
    Map<String, dynamic> body,
  ) =>
      _call(
        'initiateFlutterwaveCardLinkIntent',
        body,
        timeout: const Duration(seconds: 45),
      );

  Future<Map<String, dynamic>> abandonFlutterwaveRideIntent({
    required String reference,
  }) =>
      _call(
        'abandonFlutterwaveRideIntent',
        <String, dynamic>{
          'reference': reference,
          'tx_ref': reference,
        },
        timeout: const Duration(seconds: 30),
      );

  /// Server exports this callable as [cancelRide] (see nexride_driver/functions/index.js).
  Future<Map<String, dynamic>> cancelRideRequest({
    required String rideId,
    required String cancelReason,
  }) =>
      _call('cancelRide', <String, dynamic>{
        'rideId': rideId,
        'cancel_reason': cancelReason,
      });

  /// Re-run driver fan-out while ride is still searching (server-owned).
  Future<Map<String, dynamic>> retryRideMatching({required String rideId}) =>
      _call('retryRideMatching', <String, dynamic>{
        'rideId': rideId,
        'ride_id': rideId,
      });

  Future<Map<String, dynamic>> expireRideRequest({required String rideId}) =>
      _call('expireRideRequest', <String, dynamic>{'rideId': rideId});

  Future<Map<String, dynamic>> patchRideRequestMetadata({
    required String rideId,
    required Map<String, dynamic> patch,
  }) =>
      _call('patchRideRequestMetadata', <String, dynamic>{
        'rideId': rideId,
        'patch': patch,
      });

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
  }) =>
      _call('submitTripRating', <String, dynamic>{
        'rideId': rideId,
        'ride_id': rideId,
        'rating': rating,
        'role': 'rider',
      });

  /// Agora RTC token (same backend as driver app).
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
    final result = await callable.call(payload);
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
        'ride_id': rideId,
        'amount': amount,
        'currency': currency,
        if (redirectUrl != null) 'redirect_url': redirectUrl,
        if (customerName != null) 'customer_name': customerName,
        if (email != null) 'email': email,
      });

  Future<Map<String, dynamic>> verifyFlutterwavePayment({
    String? rideId,
    required String reference,
    String? transactionId,
    bool verifyIntentOnly = false,
    bool verifyCardLinkOnly = false,
  }) =>
      _call(
        'verifyFlutterwavePayment',
        <String, dynamic>{
          if (rideId != null && rideId.isNotEmpty) 'rideId': rideId,
          if (rideId != null && rideId.isNotEmpty) 'ride_id': rideId,
          'reference': reference,
          if (transactionId != null && transactionId.isNotEmpty)
            'transaction_id': transactionId,
          if (verifyIntentOnly) 'verify_intent_only': true,
          if (verifyCardLinkOnly) 'verify_card_link_only': true,
        },
        timeout: const Duration(seconds: 45),
      );

  Future<Map<String, dynamic>> registerBankTransferPayment({
    String? rideId,
    String? deliveryId,
  }) =>
      _call(
        'registerBankTransferPayment',
        <String, dynamic>{
          if (rideId != null && rideId.trim().isNotEmpty) ...<String, dynamic>{
            'rideId': rideId.trim(),
            'ride_id': rideId.trim(),
          },
          if (deliveryId != null && deliveryId.trim().isNotEmpty) ...<String,
              dynamic>{
            'deliveryId': deliveryId.trim(),
            'delivery_id': deliveryId.trim(),
          },
        },
        timeout: const Duration(seconds: 45),
      );

  Future<Map<String, dynamic>> getNexrideOfficialBankAccount() =>
      _call('getNexrideOfficialBankAccount', <String, dynamic>{});

  Future<Map<String, dynamic>> registerDevicePushToken({
    required String token,
    required String platform,
  }) =>
      _call('registerDevicePushToken', <String, dynamic>{
        'token': token,
        'platform': platform,
        'app': 'rider',
      });

  Future<Map<String, dynamic>> riderNotifySelfieSubmittedForReview() =>
      _call(
        'riderNotifySelfieSubmittedForReview',
        <String, dynamic>{},
      );

  Future<Map<String, dynamic>> escalateSafetyIncident({
    required String rideId,
    required String riderId,
    required String driverId,
    required String flagType,
    required String details,
    String sourceFlagId = '',
  }) =>
      _call('escalateSafetyIncident', <String, dynamic>{
        'rideId': rideId,
        'riderId': riderId,
        'driverId': driverId,
        'serviceType': 'ride',
        'flagType': flagType,
        'details': details,
        if (sourceFlagId.trim().isNotEmpty) 'sourceFlagId': sourceFlagId.trim(),
      });

  Future<Map<String, dynamic>> riderListApprovedMerchants({
    String? cityId,
    String? regionId,
    double? lat,
    double? lng,
    double? riderLat,
    double? riderLng,
    String? market,
    String? dispatchMarketId,
    String? serviceAreaId,
  }) =>
      _call('riderListApprovedMerchants', <String, dynamic>{
        if (cityId != null && cityId.trim().isNotEmpty) 'city_id': cityId.trim(),
        if (serviceAreaId != null && serviceAreaId.trim().isNotEmpty)
          'service_area_id': serviceAreaId.trim(),
        if (regionId != null && regionId.isNotEmpty) 'region_id': regionId,
        if (riderLat != null) 'rider_lat': riderLat,
        if (riderLng != null) 'rider_lng': riderLng,
        if (lat != null) 'lat': lat,
        if (lng != null) 'lng': lng,
        if (market != null && market.isNotEmpty) 'market': market,
        if (dispatchMarketId != null && dispatchMarketId.isNotEmpty)
          'dispatch_market_id': dispatchMarketId,
      });

  Future<Map<String, dynamic>> riderGetMerchantCatalog({
    required String merchantId,
    double? riderLat,
    double? riderLng,
  }) =>
      _call('riderGetMerchantCatalog', <String, dynamic>{
        'merchant_id': merchantId,
        if (riderLat != null) 'rider_lat': riderLat,
        if (riderLng != null) 'rider_lng': riderLng,
      });

  Future<Map<String, dynamic>> initiateFlutterwaveMerchantOrderPayment({
    double? amount,
    int? subtotalNgn,
    int? deliveryFeeNgn,
    String currency = 'NGN',
    String? customerName,
    String? email,
    String? redirectUrl,
    String orderFlow = 'food_order',
  }) =>
      _call('initiateFlutterwaveMerchantOrderPayment', <String, dynamic>{
        if (amount != null) 'amount': amount,
        if (subtotalNgn != null) 'subtotal_ngn': subtotalNgn,
        if (deliveryFeeNgn != null) 'delivery_fee_ngn': deliveryFeeNgn,
        'order_flow': orderFlow,
        'currency': currency,
        if (customerName != null) 'customer_name': customerName,
        if (email != null) 'email': email,
        if (redirectUrl != null) 'redirect_url': redirectUrl,
      });

  Future<Map<String, dynamic>> riderPlaceMerchantOrder({
    required String merchantId,
    required List<Map<String, dynamic>> cart,
    required Map<String, dynamic> dropoff,
    required String prepaidFlutterwaveRef,
    double? deliveryFeeNgn,
    int? totalNgn,
    String? recipientName,
    String? recipientPhone,
    String? serviceCityId,
    String? serviceRegionId,
  }) =>
      _call('riderPlaceMerchantOrder', <String, dynamic>{
        'merchant_id': merchantId,
        'cart': cart,
        'dropoff': dropoff,
        'prepaid_flutterwave_ref': prepaidFlutterwaveRef,
        if (deliveryFeeNgn != null) 'delivery_fee_ngn': deliveryFeeNgn,
        if (totalNgn != null) 'total_ngn': totalNgn,
        if (recipientName != null) 'recipient_name': recipientName,
        if (recipientPhone != null) 'recipient_phone': recipientPhone,
        if (serviceCityId != null) 'service_city_id': serviceCityId,
        if (serviceRegionId != null) 'service_region_id': serviceRegionId,
      });

  Future<Map<String, dynamic>> riderListMyOrders() =>
      _call('riderListMyOrders', <String, dynamic>{});

  Future<Map<String, dynamic>> createTripShareToken({
    required String rideId,
  }) =>
      _call('createTripShareToken', <String, dynamic>{
        'rideId': rideId,
      });

  Future<Map<String, dynamic>> getRideTrackSummary({
    required String token,
  }) =>
      _call('getRideTrackSummary', <String, dynamic>{
        'token': token,
      });
}

bool riderRideCallableSucceeded(Map<String, dynamic>? response) =>
    response != null && response['success'] == true;

String riderRideCallableReason(Map<String, dynamic>? response) {
  final r = response?['reason']?.toString().trim() ?? '';
  return r.isEmpty ? 'unknown' : r;
}

/// Prefer server [message] / [user_message]; never show raw secret / internal codes in UI.
String riderRideCallableUserMessage(Map<String, dynamic>? reg) {
  if (reg == null) {
    return 'Something went wrong. Please try again.';
  }
  for (final key in <String>['message', 'user_message']) {
    final u = reg[key]?.toString().trim();
    if (u != null && u.isNotEmpty) {
      return u;
    }
  }
  final rc = (reg['reason_code'] ?? '').toString().trim().toLowerCase();
  if (rc == 'flutterwave_secret_not_in_runtime') {
    return 'Payment provider is temporarily unavailable. Please use a card or try again later.';
  }
  final reasonLower = riderRideCallableReason(reg).toLowerCase();
  if (reasonLower == 'flutterwave_secret_missing' ||
      reasonLower.contains('flutterwave_secret_missing')) {
    return 'Payment provider is temporarily unavailable. Please use a card or try again later.';
  }
  if (reasonLower == 'payment_provider_unavailable' ||
      reasonLower.contains('flutterwave_secret')) {
    return 'Payment provider is temporarily unavailable. Please use a card or try again later.';
  }
  if (reasonLower == 'flutterwave_va_failed') {
    return 'Bank transfer could not be set up. Please try again or choose another payment method.';
  }
  if (reasonLower == 'official_bank_not_configured') {
    return 'Bank transfer is temporarily unavailable (official NexRide account not configured). '
        'Try card payment or contact support@nexride.africa.';
  }
  final human = reasonLower.replaceAll('_', ' ');
  return 'Bank transfer could not be registered ($human). '
      'Please try again or pick another payment method.';
}


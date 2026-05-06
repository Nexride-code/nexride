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
  static const Duration _kCallableTimeout = Duration(seconds: 15);
  static const int _kMaxAttempts = 2;

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
    debugPrint(
      'API_REQUEST_START name=$name region=us-central1 '
      'project=${_functions.app.options.projectId} timeout_ms=${_kCallableTimeout.inMilliseconds}',
    );
    dynamic result;
    Object? lastError;
    for (var attempt = 1; attempt <= _kMaxAttempts; attempt++) {
      try {
        result = await callable.call(payload).timeout(_kCallableTimeout);
        break;
      } on TimeoutException catch (error) {
        lastError = TimeoutException(
          'Request timed out while contacting backend.',
          _kCallableTimeout,
        );
        debugPrint(
          'API_TIMEOUT name=$name region=us-central1 timeout_ms=${_kCallableTimeout.inMilliseconds} '
          'attempt=$attempt error=$error',
        );
      } on FirebaseFunctionsException catch (error) {
        lastError = error;
        final code = error.code.trim().toLowerCase();
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
      _call('createRideRequest', body);

  Future<Map<String, dynamic>> cancelRideRequest({
    required String rideId,
    required String cancelReason,
  }) =>
      _call('cancelRideRequest', <String, dynamic>{
        'rideId': rideId,
        'cancel_reason': cancelReason,
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

  /// Agora RTC token (same backend as driver app).
  Future<Map<String, dynamic>> getRideCallRtcToken({required String rideId}) =>
      _call('getRideCallRtcToken', <String, dynamic>{
        'rideId': rideId,
        'ride_id': rideId,
        'requestId': rideId,
        'tripId': rideId,
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
    required String rideId,
    required String reference,
  }) =>
      _call('verifyFlutterwavePayment', <String, dynamic>{
        'rideId': rideId,
        'ride_id': rideId,
        'reference': reference,
      });

  Future<Map<String, dynamic>> registerBankTransferPayment({
    required String rideId,
  }) =>
      _call('registerBankTransferPayment', <String, dynamic>{
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
        'app': 'rider',
      });

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
}

bool riderRideCallableSucceeded(Map<String, dynamic>? response) =>
    response != null && response['success'] == true;

String riderRideCallableReason(Map<String, dynamic>? response) {
  final r = response?['reason']?.toString().trim() ?? '';
  return r.isEmpty ? 'unknown' : r;
}

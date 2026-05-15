import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Delivery (dispatch) HTTPS callables — parallel to [RiderRideCloudFunctionsService].
class RiderDeliveryCloudFunctionsService {
  RiderDeliveryCloudFunctionsService._internal({FirebaseFunctions? functions})
      : _functions =
            functions ?? FirebaseFunctions.instanceFor(region: 'us-central1');

  static final RiderDeliveryCloudFunctionsService instance =
      RiderDeliveryCloudFunctionsService._internal();

  factory RiderDeliveryCloudFunctionsService({FirebaseFunctions? functions}) {
    if (functions != null) {
      return RiderDeliveryCloudFunctionsService._internal(functions: functions);
    }
    return instance;
  }

  final FirebaseFunctions _functions;
  static const Duration _kCallableTimeout = Duration(seconds: 30);
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

  Future<Map<String, dynamic>> createDeliveryRequest(
    Map<String, dynamic> body,
  ) =>
      _call('createDeliveryRequest', body);

  Future<Map<String, dynamic>> expireDeliveryRequest({
    required String deliveryId,
  }) =>
      _call('expireDeliveryRequest', <String, dynamic>{
        'deliveryId': deliveryId,
        'delivery_id': deliveryId,
      });

  Future<Map<String, dynamic>> cancelDeliveryRequest({
    required String deliveryId,
    required String cancelReason,
  }) =>
      _call('cancelDeliveryRequest', <String, dynamic>{
        'deliveryId': deliveryId,
        'delivery_id': deliveryId,
        'cancel_reason': cancelReason,
      });

  Future<Map<String, dynamic>> initiateFlutterwavePayment({
    required String deliveryId,
    required double amount,
    String currency = 'NGN',
    String? redirectUrl,
    String? customerName,
    String? email,
  }) =>
      _call('initiateFlutterwavePayment', <String, dynamic>{
        'deliveryId': deliveryId,
        'delivery_id': deliveryId,
        'amount': amount,
        'currency': currency,
        if (redirectUrl != null) 'redirect_url': redirectUrl,
        if (customerName != null) 'customer_name': customerName,
        if (email != null) 'email': email,
      });

  Future<Map<String, dynamic>> verifyFlutterwavePayment({
    required String deliveryId,
    required String reference,
  }) =>
      _call('verifyFlutterwavePayment', <String, dynamic>{
        'deliveryId': deliveryId,
        'delivery_id': deliveryId,
        'reference': reference,
      });
}

bool riderDeliveryCallableSucceeded(Map<String, dynamic>? response) =>
    response != null && response['success'] == true;

String riderDeliveryCallableReason(Map<String, dynamic>? response) {
  final r = response?['reason']?.toString().trim() ?? '';
  return r.isEmpty ? 'unknown' : r;
}

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';

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

  Future<Map<String, dynamic>> _call(
    String name,
    Map<String, dynamic> payload,
  ) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      await user.getIdToken(true);
    }
    final callable = _functions.httpsCallable(name);
    final result = await callable.call(payload);
    final data = result.data;
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
}

bool riderRideCallableSucceeded(Map<String, dynamic>? response) =>
    response != null && response['success'] == true;

String riderRideCallableReason(Map<String, dynamic>? response) {
  final r = response?['reason']?.toString().trim() ?? '';
  return r.isEmpty ? 'unknown' : r;
}

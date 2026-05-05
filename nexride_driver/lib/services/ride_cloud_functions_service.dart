import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// HTTPS callables for ride lifecycle (server is source of truth).
class RideCloudFunctionsService {
  RideCloudFunctionsService({FirebaseFunctions? functions})
      : _functions =
            functions ?? FirebaseFunctions.instanceFor(region: 'us-central1');

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
      _call('driverArrived', <String, dynamic>{'rideId': rideId});

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

  Future<Map<String, dynamic>> getRideCallRtcToken({required String rideId}) =>
      _call('getRideCallRtcToken', <String, dynamic>{
        'rideId': rideId,
        'ride_id': rideId,
        'requestId': rideId,
        'tripId': rideId,
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
}

bool rideCallableSucceeded(Map<String, dynamic>? response) =>
    response != null && response['success'] == true;

String rideCallableReason(Map<String, dynamic>? response) {
  final r = response?['reason']?.toString().trim() ?? '';
  return r.isEmpty ? 'unknown' : r;
}

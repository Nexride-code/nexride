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

  Future<Map<String, dynamic>> acceptRideRequest({
    required String rideId,
    required String driverId,
  }) =>
      _call('acceptRideRequest', <String, dynamic>{
        'rideId': rideId,
        'driverId': driverId,
      });

  Future<Map<String, dynamic>> driverEnroute({required String rideId}) =>
      _call('driverEnroute', <String, dynamic>{'rideId': rideId});

  Future<Map<String, dynamic>> driverArrived({required String rideId}) =>
      _call('driverArrived', <String, dynamic>{'rideId': rideId});

  Future<Map<String, dynamic>> startTrip({required String rideId}) =>
      _call('startTrip', <String, dynamic>{'rideId': rideId});

  Future<Map<String, dynamic>> completeTrip({required String rideId}) =>
      _call('completeTrip', <String, dynamic>{'rideId': rideId});

  Future<Map<String, dynamic>> cancelRideRequest({
    required String rideId,
    required String cancelReason,
  }) =>
      _call('cancelRideRequest', <String, dynamic>{
        'rideId': rideId,
        'cancel_reason': cancelReason,
      });

  Future<Map<String, dynamic>> patchRideRequestMetadata({
    required String rideId,
    required Map<String, dynamic> patch,
  }) =>
      _call('patchRideRequestMetadata', <String, dynamic>{
        'rideId': rideId,
        'patch': patch,
      });
}

bool rideCallableSucceeded(Map<String, dynamic>? response) =>
    response != null && response['success'] == true;

String rideCallableReason(Map<String, dynamic>? response) {
  final r = response?['reason']?.toString().trim() ?? '';
  return r.isEmpty ? 'unknown' : r;
}

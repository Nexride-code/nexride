import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';

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

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Driver delivery lifecycle callables (parallel to ride callables).
class DeliveryCloudFunctionsService {
  DeliveryCloudFunctionsService({FirebaseFunctions? functions})
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

  Future<Map<String, dynamic>> acceptDeliveryRequest({
    required String deliveryId,
  }) =>
      _call('acceptDeliveryRequest', <String, dynamic>{
        'deliveryId': deliveryId,
        'delivery_id': deliveryId,
      });

  Future<Map<String, dynamic>> updateDeliveryState({
    required String deliveryId,
    String? deliveryState,
  }) =>
      _call('updateDeliveryState', <String, dynamic>{
        'deliveryId': deliveryId,
        'delivery_id': deliveryId,
        if (deliveryState != null && deliveryState.isNotEmpty)
          'delivery_state': deliveryState,
      });
}

bool deliveryCallableSucceeded(Map<String, dynamic>? response) =>
    response != null && response['success'] == true;

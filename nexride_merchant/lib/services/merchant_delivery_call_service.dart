import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart' as rtdb;

/// Masked in-app voice call entry for merchant ↔ driver (Agora via Cloud Functions).
class MerchantDeliveryCallService {
  MerchantDeliveryCallService({FirebaseFunctions? functions})
      : _functions =
            functions ?? FirebaseFunctions.instanceFor(region: 'us-central1');

  final FirebaseFunctions _functions;

  /// Fetches RTC token for delivery channel `nexride_{deliveryId}`.
  Future<String> prefetchToken({
    required String deliveryId,
    required String uid,
  }) async {
    final res = await _functions.httpsCallable('getRideCallRtcToken').call(
      <String, dynamic>{
        'rideId': deliveryId,
        'deliveryId': deliveryId,
        'uid': uid,
      },
    );
    final data = Map<String, dynamic>.from(res.data as Map);
    final token = '${data['token'] ?? data['rtcToken'] ?? ''}'.trim();
    if (token.isEmpty) {
      throw StateError('token_unavailable');
    }
    return token;
  }

  Future<void> startMerchantToDriverCall({
    required String deliveryId,
    required String merchantUid,
    String? driverId,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw StateError('not_authenticated');
    }
    var resolvedDriver = driverId?.trim() ?? '';
    if (resolvedDriver.isEmpty) {
      final snap =
          await rtdb.FirebaseDatabase.instance.ref('delivery_requests/$deliveryId').get();
      if (snap.exists && snap.value is Map) {
        final row = Map<String, dynamic>.from(snap.value as Map);
        resolvedDriver = '${row['matched_driver_id'] ?? row['driver_id'] ?? ''}'.trim();
      }
    }
    if (resolvedDriver.isEmpty) {
      throw StateError('driver_not_assigned');
    }
    await prefetchToken(deliveryId: deliveryId, uid: merchantUid);
    await _functions.httpsCallable('generateAgoraToken').call(
      <String, dynamic>{
        'rideId': deliveryId,
        'deliveryId': deliveryId,
        'channelName': 'nexride_$deliveryId',
        'uid': merchantUid,
        'startedBy': 'merchant',
        'driverId': resolvedDriver,
        'riderId': merchantUid,
      },
    );
  }
}

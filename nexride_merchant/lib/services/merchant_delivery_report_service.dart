import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart' as rtdb;

/// Merchant delivery issue reports → RTDB + support ticket bridge.
class MerchantDeliveryReportService {
  MerchantDeliveryReportService({
    rtdb.FirebaseDatabase? database,
    FirebaseFunctions? functions,
  })  : _database = database ?? rtdb.FirebaseDatabase.instance,
        _functions =
            functions ?? FirebaseFunctions.instanceFor(region: 'us-central1');

  final rtdb.FirebaseDatabase _database;
  final FirebaseFunctions _functions;

  Future<void> submitReport({
    required String deliveryId,
    required String reason,
    required String message,
    String? merchantId,
    String? customerId,
    String? driverId,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw StateError('not_authenticated');
    }
    final reportRef =
        _database.ref('support_reports/deliveries/$deliveryId').push();
    final reportId = reportRef.key ?? '';
    final payload = <String, dynamic>{
      'reportId': reportId,
      'deliveryId': deliveryId,
      'delivery_id': deliveryId,
      'reason': reason.trim(),
      'message': message.trim(),
      'reporter_id': user.uid,
      'reporter_role': 'merchant',
      'merchant_id': merchantId,
      'customer_id': customerId,
      'driver_id': driverId,
      'status': 'pending',
      'assignment_status': 'unassigned',
      'created_at': rtdb.ServerValue.timestamp,
      'created_at_ms': DateTime.now().millisecondsSinceEpoch,
    };
    await reportRef.set(payload);
    try {
      await _functions.httpsCallable('createDeliverySupportTicket').call(
        <String, dynamic>{
          'deliveryId': deliveryId,
          'reportId': reportId,
          'reason': reason,
          'message': message,
          'reporterRole': 'merchant',
        },
      );
    } catch (_) {
      // Ticket bridge optional until functions deploy.
    }
  }
}

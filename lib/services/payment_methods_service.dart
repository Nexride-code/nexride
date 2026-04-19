import 'package:firebase_database/firebase_database.dart' as rtdb;

import '../support/payment_method_support.dart';
import '../support/startup_rtdb_support.dart';

class PaymentMethodsService {
  const PaymentMethodsService();

  rtdb.DatabaseReference get _rootRef => rtdb.FirebaseDatabase.instance.ref();

  Future<List<PaymentMethodRecord>> fetchPaymentMethods(String riderId) async {
    final snapshot = await runOptionalStartupRead<rtdb.DataSnapshot>(
      source: 'payment_methods.fetch',
      path: paymentMethodsPath(riderId),
      action: () => _rootRef.child(paymentMethodsPath(riderId)).get(),
    );
    if (snapshot == null || !snapshot.exists || snapshot.value is! Map) {
      return const <PaymentMethodRecord>[];
    }

    final values = Map<String, dynamic>.from(snapshot.value as Map);
    final methods =
        values.entries
            .map(
              (entry) => PaymentMethodRecord.fromMap(
                riderId,
                entry.key,
                Map<String, dynamic>.from(entry.value as Map),
              ),
            )
            .toList()
          ..sort((a, b) {
            if (a.isDefault != b.isDefault) {
              return a.isDefault ? -1 : 1;
            }
            return b.updatedAt.compareTo(a.updatedAt);
          });

    return methods;
  }

  Future<void> saveLinkedPaymentMethod(PaymentMethodDraft draft) async {
    final existing = await fetchPaymentMethods(draft.riderId);
    final ref = _rootRef.child(paymentMethodsPath(draft.riderId)).push();
    final methodId =
        ref.key ?? 'payment_${DateTime.now().millisecondsSinceEpoch}';
    final shouldMakeDefault =
        draft.makeDefault || existing.every((method) => !method.isDefault);

    final updates = <String, Object?>{
      '${paymentMethodsPath(draft.riderId)}/$methodId': <String, Object?>{
        'id': methodId,
        'riderId': draft.riderId,
        'type': draft.type.key,
        'provider': draft.provider,
        'maskedDetails': draft.maskedDetails,
        'status': 'linked',
        'isDefault': shouldMakeDefault,
        'displayTitle': draft.displayTitle,
        'detailLabel': draft.detailLabel,
        'createdAt': rtdb.ServerValue.timestamp,
        'updatedAt': rtdb.ServerValue.timestamp,
      },
      'users/${draft.riderId}/paymentMethodsEnabled': true,
      'users/${draft.riderId}/updated_at': rtdb.ServerValue.timestamp,
    };

    if (shouldMakeDefault) {
      for (final method in existing.where((method) => method.isDefault)) {
        updates['${paymentMethodsPath(draft.riderId)}/${method.id}/isDefault'] =
            false;
        updates['${paymentMethodsPath(draft.riderId)}/${method.id}/updatedAt'] =
            rtdb.ServerValue.timestamp;
      }
      updates['users/${draft.riderId}/defaultPaymentMethodId'] = methodId;
    }

    await _rootRef.update(updates);
  }

  Future<void> setDefaultPaymentMethod({
    required String riderId,
    required String methodId,
  }) async {
    final methods = await fetchPaymentMethods(riderId);
    if (methods.isEmpty) {
      return;
    }

    final updates = <String, Object?>{
      'users/$riderId/defaultPaymentMethodId': methodId,
      'users/$riderId/updated_at': rtdb.ServerValue.timestamp,
    };

    for (final method in methods) {
      final isDefault = method.id == methodId;
      updates['${paymentMethodsPath(riderId)}/${method.id}/isDefault'] =
          isDefault;
      updates['${paymentMethodsPath(riderId)}/${method.id}/updatedAt'] =
          rtdb.ServerValue.timestamp;
    }

    await _rootRef.update(updates);
  }
}

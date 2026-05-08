import 'package:firebase_database/firebase_database.dart' as rtdb;
import 'package:flutter/foundation.dart';

import '../support/payment_method_support.dart';
import '../support/startup_rtdb_support.dart';

class PaymentMethodsService {
  const PaymentMethodsService();

  rtdb.DatabaseReference get _rootRef => rtdb.FirebaseDatabase.instance.ref();

  Future<List<PaymentMethodRecord>> fetchPaymentMethods(String riderId) async {
    debugPrint('[PAYMENT_METHODS_LOAD] riderId=$riderId');
    final snapshot = await runOptionalStartupRead<rtdb.DataSnapshot>(
      source: 'payment_methods.fetch',
      path: userPaymentMethodsPath(riderId),
      action: () => _rootRef.child(userPaymentMethodsPath(riderId)).get(),
    );
    if (snapshot == null) {
      debugPrint('[PAYMENT_METHODS_LOAD_FAIL] riderId=$riderId reason=null_snapshot');
      return const <PaymentMethodRecord>[];
    }
    rtdb.DataSnapshot resolvedSnapshot = snapshot;
    if (!resolvedSnapshot.exists || resolvedSnapshot.value is! Map) {
      final legacy = await _rootRef.child(paymentMethodsPath(riderId)).get();
      if (legacy.exists && legacy.value is Map) {
        resolvedSnapshot = legacy;
      } else {
        debugPrint('[PAYMENT_METHODS_LOAD_OK] riderId=$riderId count=0');
        return const <PaymentMethodRecord>[];
      }
    }

    final values = Map<String, dynamic>.from(resolvedSnapshot.value as Map);
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

    debugPrint('[PAYMENT_METHODS_LOAD_OK] riderId=$riderId count=${methods.length}');
    return methods;
  }

  Future<void> saveLinkedPaymentMethod(PaymentMethodDraft draft) async {
    debugPrint('[${draft.type == PaymentMethodType.card ? 'CARD_LINK_START' : 'BANK_LINK_START'}] riderId=${draft.riderId} provider=${draft.provider}');
    final existing = await fetchPaymentMethods(draft.riderId);
    final ref = _rootRef.child(userPaymentMethodsPath(draft.riderId)).push();
    final methodId =
        ref.key ?? 'payment_${DateTime.now().millisecondsSinceEpoch}';
    final shouldMakeDefault =
        draft.makeDefault || existing.every((method) => !method.isDefault);

    final providerStored = draft.provider.toLowerCase().contains('flutterwave')
        ? 'flutterwave'
        : draft.provider.trim();
    final updates = <String, Object?>{
      '${userPaymentMethodsPath(draft.riderId)}/$methodId': <String, Object?>{
        if (draft.brand.trim().isNotEmpty) 'brand': draft.brand.trim(),
        'last4': draft.last4,
        'provider':
            providerStored.isNotEmpty ? providerStored : 'flutterwave',
        'token_ref': draft.tokenRef.trim(),
        'provider_reference': draft.providerReference.trim(),
        'type': draft.type.key,
        'isDefault': shouldMakeDefault,
        'is_default': shouldMakeDefault,
        'createdAt': rtdb.ServerValue.timestamp,
        'updatedAt': rtdb.ServerValue.timestamp,
        'created_at': rtdb.ServerValue.timestamp,
        'updated_at': rtdb.ServerValue.timestamp,
      },
      'users/${draft.riderId}/paymentMethodsEnabled': true,
      'users/${draft.riderId}/updated_at': rtdb.ServerValue.timestamp,
    };

    if (shouldMakeDefault) {
      for (final method in existing.where((method) => method.isDefault)) {
        updates['${userPaymentMethodsPath(draft.riderId)}/${method.id}/isDefault'] =
            false;
        updates['${userPaymentMethodsPath(draft.riderId)}/${method.id}/is_default'] =
            false;
        updates['${userPaymentMethodsPath(draft.riderId)}/${method.id}/updatedAt'] =
            rtdb.ServerValue.timestamp;
        updates['${userPaymentMethodsPath(draft.riderId)}/${method.id}/updated_at'] =
            rtdb.ServerValue.timestamp;
      }
      updates['users/${draft.riderId}/defaultPaymentMethodId'] = methodId;
    }

    try {
      await _rootRef.update(updates);
      debugPrint('[${draft.type == PaymentMethodType.card ? 'CARD_LINK_OK' : 'BANK_LINK_OK'}] riderId=${draft.riderId} methodId=$methodId');
    } catch (error) {
      debugPrint('[${draft.type == PaymentMethodType.card ? 'CARD_LINK_FAIL' : 'BANK_LINK_FAIL'}] riderId=${draft.riderId} error=$error');
      rethrow;
    }
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
      updates['${userPaymentMethodsPath(riderId)}/${method.id}/isDefault'] =
          isDefault;
      updates['${userPaymentMethodsPath(riderId)}/${method.id}/is_default'] =
          isDefault;
      updates['${userPaymentMethodsPath(riderId)}/${method.id}/updatedAt'] =
          rtdb.ServerValue.timestamp;
      updates['${userPaymentMethodsPath(riderId)}/${method.id}/updated_at'] =
          rtdb.ServerValue.timestamp;
    }

    await _rootRef.update(updates);
  }

  Future<void> deletePaymentMethod({
    required String riderId,
    required String methodId,
  }) async {
    final methods = await fetchPaymentMethods(riderId);
    final deletingDefault =
        methods.any((m) => m.id == methodId && m.isDefault);
    final updates = <String, Object?>{
      '${userPaymentMethodsPath(riderId)}/$methodId': null,
      'users/$riderId/updated_at': rtdb.ServerValue.timestamp,
    };
    if (deletingDefault) {
      final fallback = methods.where((m) => m.id != methodId).toList();
      final nextDefault = fallback.isEmpty ? null : fallback.first.id;
      updates['users/$riderId/defaultPaymentMethodId'] = nextDefault;
      if (nextDefault != null) {
        updates['${userPaymentMethodsPath(riderId)}/$nextDefault/isDefault'] = true;
        updates['${userPaymentMethodsPath(riderId)}/$nextDefault/is_default'] = true;
      }
    }
    await _rootRef.update(updates);
  }
}

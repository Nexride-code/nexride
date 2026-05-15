import 'dart:convert';

import 'package:cloud_functions/cloud_functions.dart';

/// Callable bridge for the standalone merchant web portal (nexride_dispatch).
class MerchantPortalFunctions {
  MerchantPortalFunctions({FirebaseFunctions? functions})
      : _fn = functions ??
            FirebaseFunctions.instanceFor(region: 'us-central1');

  final FirebaseFunctions _fn;

  Future<Map<String, dynamic>> listDeliveryRegions() async {
    final result = await _fn
        .httpsCallable(
          'listDeliveryRegions',
          options: HttpsCallableOptions(timeout: const Duration(seconds: 45)),
        )
        .call(<String, dynamic>{});
    return _asMap(result.data);
  }

  Future<Map<String, dynamic>> merchantRegister(
    Map<String, dynamic> payload,
  ) async {
    final result = await _fn
        .httpsCallable(
          'merchantRegister',
          options: HttpsCallableOptions(timeout: const Duration(seconds: 45)),
        )
        .call(payload);
    return _asMap(result.data);
  }

  Future<Map<String, dynamic>> merchantGetMyMerchant() async {
    final result = await _fn
        .httpsCallable(
          'merchantGetMyMerchant',
          options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
        )
        .call(<String, dynamic>{});
    return _asMap(result.data);
  }

  Future<Map<String, dynamic>> merchantUpdateMerchantProfile(
    Map<String, dynamic> payload,
  ) async {
    final result = await _fn
        .httpsCallable(
          'merchantUpdateMerchantProfile',
          options: HttpsCallableOptions(timeout: const Duration(seconds: 45)),
        )
        .call(payload);
    return _asMap(result.data);
  }

  Future<Map<String, dynamic>> merchantUploadVerificationDocument(
    Map<String, dynamic> payload,
  ) async {
    final result = await _fn
        .httpsCallable(
          'merchantUploadVerificationDocument',
          options: HttpsCallableOptions(timeout: const Duration(seconds: 60)),
        )
        .call(payload);
    return _asMap(result.data);
  }

  Future<Map<String, dynamic>> merchantListMyVerificationDocuments() async {
    final result = await _fn
        .httpsCallable(
          'merchantListMyVerificationDocuments',
          options: HttpsCallableOptions(timeout: const Duration(seconds: 45)),
        )
        .call(<String, dynamic>{});
    return _asMap(result.data);
  }

  Future<Map<String, dynamic>> merchantUpsertMenuCategory(
    Map<String, dynamic> payload,
  ) async {
    final result = await _fn
        .httpsCallable(
          'merchantUpsertMenuCategory',
          options: HttpsCallableOptions(timeout: const Duration(seconds: 45)),
        )
        .call(payload);
    return _asMap(result.data);
  }

  Future<Map<String, dynamic>> merchantDeleteMenuCategory(
    Map<String, dynamic> payload,
  ) async {
    final result = await _fn
        .httpsCallable(
          'merchantDeleteMenuCategory',
          options: HttpsCallableOptions(timeout: const Duration(seconds: 45)),
        )
        .call(payload);
    return _asMap(result.data);
  }

  Future<Map<String, dynamic>> merchantUpsertMenuItem(
    Map<String, dynamic> payload,
  ) async {
    final result = await _fn
        .httpsCallable(
          'merchantUpsertMenuItem',
          options: HttpsCallableOptions(timeout: const Duration(seconds: 60)),
        )
        .call(payload);
    return _asMap(result.data);
  }

  Future<Map<String, dynamic>> merchantArchiveMenuItem(
    Map<String, dynamic> payload,
  ) async {
    final result = await _fn
        .httpsCallable(
          'merchantArchiveMenuItem',
          options: HttpsCallableOptions(timeout: const Duration(seconds: 45)),
        )
        .call(payload);
    return _asMap(result.data);
  }

  Future<Map<String, dynamic>> merchantListMyMenu() async {
    final result = await _fn
        .httpsCallable(
          'merchantListMyMenu',
          options: HttpsCallableOptions(timeout: const Duration(seconds: 45)),
        )
        .call(<String, dynamic>{});
    return _asMap(result.data);
  }

  Future<Map<String, dynamic>> merchantCreateBankTransferTopUp({
    required int amountNgn,
  }) async {
    final result = await _fn
        .httpsCallable(
          'merchantCreateBankTransferTopUp',
          options: HttpsCallableOptions(timeout: const Duration(seconds: 60)),
        )
        .call(<String, dynamic>{'amount_ngn': amountNgn});
    return _asMap(result.data);
  }

  Future<Map<String, dynamic>> merchantListMyOrders() async {
    final result = await _fn
        .httpsCallable(
          'merchantListMyOrders',
          options: HttpsCallableOptions(timeout: const Duration(seconds: 45)),
        )
        .call(<String, dynamic>{});
    return _asMap(result.data);
  }

  Future<Map<String, dynamic>> merchantUpdateOrderStatus(
    Map<String, dynamic> payload,
  ) async {
    final result = await _fn
        .httpsCallable(
          'merchantUpdateOrderStatus',
          options: HttpsCallableOptions(timeout: const Duration(seconds: 45)),
        )
        .call(payload);
    return _asMap(result.data);
  }

  Map<String, dynamic> _asMap(dynamic data) {
    if (data is! Map) {
      return <String, dynamic>{};
    }
    try {
      final decoded = jsonDecode(jsonEncode(data));
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {
      /* fall through */
    }
    return data.map(
      (dynamic k, dynamic v) => MapEntry(k.toString(), v),
    );
  }
}

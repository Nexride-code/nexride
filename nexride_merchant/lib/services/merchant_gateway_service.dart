import 'dart:convert';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

import '../utils/nx_callable_messages.dart';

/// HTTPS callable bridge — mirrors `nexride_driver/lib/merchant/merchant_portal_functions.dart`
/// and adds support + merchant-ticket helpers deployed with NexRide Cloud Functions.
class MerchantGatewayService {
  MerchantGatewayService({FirebaseFunctions? functions})
      : _fn = functions ??
            FirebaseFunctions.instanceFor(region: 'us-central1');

  final FirebaseFunctions _fn;

  Future<Map<String, dynamic>> merchantRegister(Map<String, dynamic> payload) async {
    return _call('merchantRegister', payload);
  }

  Future<Map<String, dynamic>> merchantGetMyMerchant() async {
    return _call('merchantGetMyMerchant', <String, dynamic>{});
  }

  Future<Map<String, dynamic>> merchantUpdateMerchantProfile(
    Map<String, dynamic> payload,
  ) async {
    return _call('merchantUpdateMerchantProfile', payload);
  }

  Future<Map<String, dynamic>> merchantUpdateAvailability(Map<String, dynamic> payload) async {
    return _call('merchantUpdateAvailability', payload);
  }

  /// Alias for older clients — calls [merchantUpdateAvailability].
  Future<Map<String, dynamic>> merchantSetAvailability(Map<String, dynamic> payload) async {
    return merchantUpdateAvailability(payload);
  }

  Future<Map<String, dynamic>> merchantAttachMenuOrProfileImage(
    Map<String, dynamic> payload,
  ) async {
    return _call(
      'merchantAttachMenuOrProfileImage',
      payload,
      timeout: const Duration(seconds: 90),
    );
  }

  Future<Map<String, dynamic>> merchantListMyOrders() async {
    return _call('merchantListMyOrders', <String, dynamic>{});
  }

  Future<Map<String, dynamic>> merchantListMyOrdersPage(Map<String, dynamic> payload) async {
    return _call('merchantListMyOrdersPage', payload);
  }

  Future<Map<String, dynamic>> merchantGetOperationsInsights() async {
    return _call('merchantGetOperationsInsights', <String, dynamic>{});
  }

  Future<Map<String, dynamic>> merchantPortalHeartbeat(Map<String, dynamic> payload) async {
    return _call('merchantPortalHeartbeat', payload, timeout: const Duration(seconds: 20));
  }

  Future<Map<String, dynamic>> merchantPutStaffMember(Map<String, dynamic> payload) async {
    return _call('merchantPutStaffMember', payload);
  }

  Future<Map<String, dynamic>> registerDevicePushToken(Map<String, dynamic> payload) async {
    return _call('registerDevicePushToken', payload, timeout: const Duration(seconds: 30));
  }

  Future<Map<String, dynamic>> merchantUpdateOrderStatus(
    Map<String, dynamic> payload,
  ) async {
    return _call('merchantUpdateOrderStatus', payload);
  }

  Future<Map<String, dynamic>> merchantListMyMenu() async {
    return _call('merchantListMyMenu', <String, dynamic>{});
  }

  Future<Map<String, dynamic>> merchantListMyMenuPage(Map<String, dynamic> payload) async {
    return _call('merchantListMyMenuPage', payload, timeout: const Duration(seconds: 60));
  }

  Future<Map<String, dynamic>> merchantUpsertMenuCategory(
    Map<String, dynamic> payload,
  ) async {
    return _call('merchantUpsertMenuCategory', payload);
  }

  Future<Map<String, dynamic>> merchantDeleteMenuCategory(
    Map<String, dynamic> payload,
  ) async {
    return _call('merchantDeleteMenuCategory', payload);
  }

  Future<Map<String, dynamic>> merchantUpsertMenuItem(
    Map<String, dynamic> payload,
  ) async {
    return _call('merchantUpsertMenuItem', payload);
  }

  Future<Map<String, dynamic>> merchantArchiveMenuItem(
    Map<String, dynamic> payload,
  ) async {
    return _call('merchantArchiveMenuItem', payload);
  }

  Future<Map<String, dynamic>> merchantUploadVerificationDocument(
    Map<String, dynamic> payload,
  ) async {
    return _call(
      'merchantUploadVerificationDocument',
      payload,
      timeout: const Duration(seconds: 90),
    );
  }

  Future<Map<String, dynamic>> merchantListMyVerificationDocuments() async {
    return _call(
      'merchantListMyVerificationDocuments',
      <String, dynamic>{},
      timeout: const Duration(seconds: 45),
    );
  }

  Future<Map<String, dynamic>> supportCreateTicket(
    Map<String, dynamic> payload,
  ) async {
    return _call('supportCreateTicket', payload);
  }

  Future<Map<String, dynamic>> supportGetTicket(String ticketId) async {
    return _call('supportGetTicket', <String, dynamic>{
      'ticketId': ticketId,
    });
  }

  Future<Map<String, dynamic>> merchantListMySupportTickets() async {
    return _call('merchantListMySupportTickets', <String, dynamic>{});
  }

  Future<Map<String, dynamic>> merchantAppendSupportTicketMessage(
    Map<String, dynamic> payload,
  ) async {
    return _call('merchantAppendSupportTicketMessage', payload);
  }

  Future<Map<String, dynamic>> merchantCreateBankTransferTopUp(
    Map<String, dynamic> payload,
  ) async {
    return _call('merchantCreateBankTransferTopUp', payload);
  }

  Future<Map<String, dynamic>> merchantAttachBankTransferTopUpProof(
    Map<String, dynamic> payload,
  ) async {
    return _call('merchantAttachBankTransferTopUpProof', payload);
  }

  Future<Map<String, dynamic>> merchantStartWalletTopUpFlutterwave(
    Map<String, dynamic> payload,
  ) async {
    return _call('merchantStartWalletTopUpFlutterwave', payload);
  }

  Future<Map<String, dynamic>> merchantListWalletLedger() async {
    return _call('merchantListWalletLedger', <String, dynamic>{});
  }

  Future<Map<String, dynamic>> merchantRequestWithdrawal(
    Map<String, dynamic> payload,
  ) async {
    return _call('merchantRequestWithdrawal', payload);
  }

  Future<Map<String, dynamic>> merchantRequestPaymentModelChange(
    Map<String, dynamic> payload,
  ) async {
    return _call('merchantRequestPaymentModelChange', payload);
  }

  /// Server-side Flutterwave verification (same callable as rider `verifyPayment`).
  Future<Map<String, dynamic>> verifyPayment(String reference) async {
    return _call('verifyPayment', <String, dynamic>{
      'reference': reference,
    });
  }

  /// Server-backed official NexRide bank account (RTDB `app_config/nexride_official_bank_account`).
  Future<Map<String, dynamic>> getNexrideOfficialBankAccount() async {
    return _call('getNexrideOfficialBankAccount', <String, dynamic>{});
  }

  Future<Map<String, dynamic>> _call(
    String name,
    Map<String, dynamic> data, {
    Duration timeout = const Duration(seconds: 45),
  }) async {
    try {
      if (kDebugMode) {
        debugPrint('[callable $name] start payloadKeys=${data.keys.join(',')}');
      }
      final result = await _fn
          .httpsCallable(
            name,
            options: HttpsCallableOptions(timeout: timeout),
          )
          .call(data);
      final out = _asMap(result.data);
      if (kDebugMode && out['success'] != true) {
        debugPrint(
          '[callable $name] fail reason=${out['reason']} reason_code=${out['reason_code']}',
        );
      }
      return out;
    } on FirebaseFunctionsException catch (e) {
      if (kDebugMode) {
        debugPrint('[callable $name] code=${e.code} message=${e.message}');
      }
      const supportFns = <String>{
        'merchantListMySupportTickets',
        'merchantAppendSupportTicketMessage',
        'supportCreateTicket',
        'supportGetTicket',
      };
      if (supportFns.contains(name)) {
        return <String, dynamic>{
          'success': false,
          'reason': 'support_unavailable',
          'user_message': nxSupportUnavailableMessage(),
        };
      }
      return <String, dynamic>{
        'success': false,
        'reason': e.code,
        'user_message': nxUserFacingMessage(e),
      };
    }
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
    } catch (_) {}
    return data.map(
      (dynamic k, dynamic v) => MapEntry(k.toString(), v),
    );
  }
}

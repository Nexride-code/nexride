import '../trip_sync/delivery_state_machine.dart';

/// Pure helpers for dispatch delivery offer popups (queue payload + skip rules).
class DeliveryOfferPopupSupport {
  DeliveryOfferPopupSupport._();

  static bool isDeliveryOfferQueuePayload(Map<String, dynamic>? offer) {
    if (offer == null || offer.isEmpty) {
      return false;
    }
    final kind = _text(offer['__nexride_request_kind']).toLowerCase();
    if (kind == 'delivery') {
      return true;
    }
    return _serviceTypeKey(offer['service_type']) == 'dispatch_delivery';
  }

  static bool isDeliveryOfferData(Map<String, dynamic>? data) {
    if (data == null || data.isEmpty) {
      return false;
    }
    final kind = _text(data['__nexride_request_kind']).toLowerCase();
    if (kind == 'delivery') {
      return true;
    }
    return _serviceTypeKey(data['service_type']) == 'dispatch_delivery';
  }

  /// Returns a rejection reason, or null when the offer may be shown.
  static String? skipReason(
    Map<String, dynamic> data, {
    required String effectiveDriverId,
    required int nowMs,
    int expiryGraceMs = 0,
  }) {
    final state = DeliveryStateMachine.canonicalStateFromSnapshot(data);
    if (state == DeliveryLifecycleState.cancelled ||
        state == DeliveryLifecycleState.completed) {
      return 'delivery_terminal';
    }
    final assigned = DeliveryStateMachine.canonicalAssignedDriverId(data);
    if (assigned.isNotEmpty &&
        assigned != effectiveDriverId &&
        state != DeliveryLifecycleState.searching) {
      return 'assigned_to_another_driver';
    }
    final status = _text(data['status']).toLowerCase();
    if (<String>{
      'cancelled',
      'canceled',
      'completed',
      'expired',
      'withdrawn',
      'closed',
    }.contains(status)) {
      return 'delivery_status_terminal';
    }
    final expiresAt = _expiresAtMs(data);
    if (expiresAt > 0 && nowMs >= expiresAt + expiryGraceMs) {
      return 'expired';
    }
    final driverId = _text(data['driver_id']).trim();
    final driverLower = driverId.toLowerCase();
    if (driverId.isNotEmpty &&
        driverLower != 'waiting' &&
        driverId != effectiveDriverId) {
      return 'assigned_to_another_driver';
    }
    return null;
  }

  static String _text(dynamic value) => value?.toString().trim() ?? '';

  static String _serviceTypeKey(dynamic raw) =>
      _text(raw).toLowerCase().replaceAll(' ', '_');

  static int _expiresAtMs(Map<String, dynamic> data) {
    for (final key in <String>[
      'expires_at',
      'request_expires_at',
      'search_timeout_at',
    ]) {
      final raw = data[key];
      if (raw is num) {
        return raw.toInt();
      }
      final parsed = int.tryParse(_text(raw));
      if (parsed != null && parsed > 0) {
        return parsed;
      }
    }
    return 0;
  }
}

import 'package:flutter/foundation.dart';

import 'nex_trace.dart';

/// Validates whether a driver may hydrate active-delivery UI from
/// [driver_active_delivery/{driverId}] on cold start.
///
/// The pointer is a hint only; lifecycle and panel state come from
/// `delivery_requests/{deliveryId}` once active-delivery tracking attaches.
class DriverActiveDeliveryRestoreSupport {
  DriverActiveDeliveryRestoreSupport._();

  static void traceStartupCheck({required String driverId, String? source}) {
    NexTrace.log(
      event: 'DRIVER_STARTUP_ACTIVE_DELIVERY_CHECK',
      uid: driverId,
      role: 'driver',
      source: source ?? 'driver_startup',
    );
  }

  static void tracePointerFound({
    required String driverId,
    required String deliveryId,
    int? pointerUpdatedAt,
    String? source,
  }) {
    NexTrace.log(
      event: 'DRIVER_ACTIVE_DELIVERY_POINTER_FOUND',
      uid: driverId,
      role: 'driver',
      source: source ?? 'driver_startup',
      extra: <String, String>{
        'delivery_id': deliveryId,
        if (pointerUpdatedAt != null && pointerUpdatedAt > 0)
          'pointer_updated_at': '$pointerUpdatedAt',
      },
    );
    debugPrint(
      '[TRACE][DRIVER_ACTIVE_DELIVERY_POINTER_FOUND] uid=$driverId deliveryId=$deliveryId',
    );
  }

  static void traceUiRestored({
    required String driverId,
    required String deliveryId,
    String? source,
  }) {
    NexTrace.log(
      event: 'DRIVER_ACTIVE_DELIVERY_UI_RESTORED',
      uid: driverId,
      role: 'driver',
      source: source ?? 'driver_startup',
      extra: <String, String>{'delivery_id': deliveryId},
    );
    debugPrint(
      '[TRACE][DRIVER_ACTIVE_DELIVERY_UI_RESTORED] uid=$driverId deliveryId=$deliveryId',
    );
  }

  static String? pointerDeliveryId(Map<String, dynamic>? pointer) {
    if (pointer == null || pointer.isEmpty) {
      return null;
    }
    final deliveryId = pointer['delivery_id']?.toString().trim() ??
        pointer['deliveryId']?.toString().trim() ??
        '';
    return deliveryId.isEmpty ? null : deliveryId;
  }

  static int pointerUpdatedAtMs(Map<String, dynamic>? pointer) {
    if (pointer == null) {
      return 0;
    }
    return _parsePositiveInt(
          pointer['updated_at'] ?? pointer['updatedAt'],
        ) ??
        0;
  }

  /// P0-B: restore delivery tracking on startup when ride restore did not run.
  static String? resolveStartupDeliveryRestore({
    required Map<String, dynamic>? pointer,
    required bool rideWasRestored,
  }) {
    if (rideWasRestored) {
      return null;
    }
    return pointerDeliveryId(pointer);
  }

  /// Mirrors [_startActiveDeliveryTracking] duplicate-guard for tests.
  static bool shouldSkipTrackingAttach({
    required String? trackedDeliveryId,
    required bool hasActiveDeliverySubscription,
    required String candidateDeliveryId,
  }) {
    final rid = candidateDeliveryId.trim();
    if (rid.isEmpty) {
      return true;
    }
    return trackedDeliveryId?.trim() == rid && hasActiveDeliverySubscription;
  }

  static int? _parsePositiveInt(dynamic value) {
    if (value is num) {
      final n = value.toInt();
      return n > 0 ? n : null;
    }
    final parsed = int.tryParse(value?.toString() ?? '');
    if (parsed == null || parsed <= 0) {
      return null;
    }
    return parsed;
  }
}

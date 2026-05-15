/// Backend `merchant_orders.order_status` values (see `merchant_commerce.js`).
abstract class MerchantOrderBackendStatus {
  static const String pendingMerchant = 'pending_merchant';
  static const String merchantRejected = 'merchant_rejected';
  static const String merchantAccepted = 'merchant_accepted';
  static const String preparing = 'preparing';
  static const String readyForPickup = 'ready_for_pickup';
  static const String dispatching = 'dispatching';
  static const String completed = 'completed';
  static const String cancelled = 'cancelled';
}

/// Human labels for operations UI (maps to backend strings in [toBackendStatus]).
abstract class MerchantOrderLifecycleLabels {
  static const String placed = 'Placed';
  static const String acceptedByMerchant = 'Accepted';
  static const String rejectedByMerchant = 'Rejected';
  static const String preparing = 'Preparing';
  static const String readyForPickup = 'Ready for pickup';
  static const String pickedUp = 'Out for delivery';
  static const String delivered = 'Delivered';
  static const String cancelled = 'Cancelled';
}

String orderStatusLabel(String? raw) {
  switch ((raw ?? '').toLowerCase()) {
    case MerchantOrderBackendStatus.pendingMerchant:
      return MerchantOrderLifecycleLabels.placed;
    case MerchantOrderBackendStatus.merchantAccepted:
      return MerchantOrderLifecycleLabels.acceptedByMerchant;
    case MerchantOrderBackendStatus.merchantRejected:
      return MerchantOrderLifecycleLabels.rejectedByMerchant;
    case MerchantOrderBackendStatus.preparing:
      return MerchantOrderLifecycleLabels.preparing;
    case MerchantOrderBackendStatus.readyForPickup:
      return MerchantOrderLifecycleLabels.readyForPickup;
    case MerchantOrderBackendStatus.dispatching:
      return MerchantOrderLifecycleLabels.pickedUp;
    case MerchantOrderBackendStatus.completed:
      return MerchantOrderLifecycleLabels.delivered;
    case MerchantOrderBackendStatus.cancelled:
      return MerchantOrderLifecycleLabels.cancelled;
    default:
      return raw?.isNotEmpty == true ? raw! : 'Unknown';
  }
}

/// Next action chips for merchant operations (callable `merchantUpdateOrderStatus`).
List<String> nextMerchantActions(String? current) {
  final c = (current ?? '').toLowerCase();
  switch (c) {
    case MerchantOrderBackendStatus.pendingMerchant:
      return <String>[
        MerchantOrderBackendStatus.merchantAccepted,
        MerchantOrderBackendStatus.merchantRejected,
      ];
    case MerchantOrderBackendStatus.merchantAccepted:
      return <String>[MerchantOrderBackendStatus.preparing];
    case MerchantOrderBackendStatus.preparing:
      return <String>[MerchantOrderBackendStatus.readyForPickup];
    case MerchantOrderBackendStatus.readyForPickup:
      return <String>[MerchantOrderBackendStatus.dispatching];
    default:
      return const <String>[];
  }
}

String transitionCta(String backendStatus) {
  switch (backendStatus) {
    case MerchantOrderBackendStatus.merchantAccepted:
      return 'Accept order';
    case MerchantOrderBackendStatus.merchantRejected:
      return 'Reject order';
    case MerchantOrderBackendStatus.preparing:
      return 'Mark preparing';
    case MerchantOrderBackendStatus.readyForPickup:
      return 'Mark ready for pickup';
    case MerchantOrderBackendStatus.dispatching:
      return 'Release to delivery';
    default:
      return backendStatus;
  }
}

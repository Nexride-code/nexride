/// Canonical delivery lifecycle labels for merchant UI.
class DeliveryStateMachine {
  DeliveryStateMachine._();

  static String normalizeDeliveryStateKey(dynamic raw) {
    final s = raw?.toString().trim().toLowerCase() ?? '';
    const legacy = <String, String>{
      'accepted': 'driver_assigned',
      'enroute_pickup': 'driver_arriving_pickup',
      'arrived_pickup': 'driver_arriving_pickup',
      'enroute_dropoff': 'on_delivery',
      'delivered': 'completed',
    };
    return legacy[s] ?? s;
  }

  static String canonicalAssignedDriverId(Map<String, dynamic>? data) {
    if (data == null) return '';
    const bad = <String>{'waiting', 'pending', 'null', 'none', ''};
    for (final key in <String>[
      'matched_driver_id',
      'accepted_driver_id',
      'delivery_driver_id',
      'driver_id',
    ]) {
      final v = data[key]?.toString().trim() ?? '';
      if (v.isNotEmpty && !bad.contains(v.toLowerCase())) {
        return v;
      }
    }
    return '';
  }

  static bool snapshotShowsAssignedDriver(Map<String, dynamic>? data) =>
      canonicalAssignedDriverId(data).isNotEmpty;

  static String uiStatusLabel(Map<String, dynamic>? data) {
    final ds = normalizeDeliveryStateKey(data?['delivery_state']);
    return switch (ds) {
      'driver_assigned' => 'Driver assigned',
      'driver_arriving_pickup' => 'Driver heading to pickup',
      'picked_up' => 'Order picked up',
      'on_delivery' => 'On the way to customer',
      'arrived_dropoff' => 'Driver at destination',
      'completed' => 'Delivered',
      'cancelled' => 'Cancelled',
      _ => 'Finding driver',
    };
  }
}

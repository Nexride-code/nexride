/// Canonical delivery lifecycle — shared by rider, driver, merchant, and admin UIs.
library;

enum DeliveryLifecycleState {
  searching,
  driverAssigned,
  driverArrivingPickup,
  pickedUp,
  onDelivery,
  arrivedDropoff,
  completed,
  cancelled,
}

class DeliveryStateMachine {
  DeliveryStateMachine._();

  static const Map<String, String> _legacyAliases = <String, String>{
    'accepted': 'driver_assigned',
    'enroute_pickup': 'driver_arriving_pickup',
    'arrived_pickup': 'driver_arriving_pickup',
    'enroute_dropoff': 'on_delivery',
    'delivered': 'completed',
  };

  static String normalizeDeliveryStateKey(dynamic raw) {
    final s = raw?.toString().trim().toLowerCase() ?? '';
    if (s.isEmpty) return '';
    return _legacyAliases[s] ?? s;
  }

  static DeliveryLifecycleState canonicalStateFromSnapshot(
    Map<String, dynamic>? data,
  ) {
    if (data == null || data.isEmpty) {
      return DeliveryLifecycleState.searching;
    }
    final ds = normalizeDeliveryStateKey(data['delivery_state']);
    return switch (ds) {
      'driver_assigned' => DeliveryLifecycleState.driverAssigned,
      'driver_arriving_pickup' => DeliveryLifecycleState.driverArrivingPickup,
      'picked_up' => DeliveryLifecycleState.pickedUp,
      'on_delivery' => DeliveryLifecycleState.onDelivery,
      'arrived_dropoff' => DeliveryLifecycleState.arrivedDropoff,
      'completed' => DeliveryLifecycleState.completed,
      'cancelled' => DeliveryLifecycleState.cancelled,
      'searching' => DeliveryLifecycleState.searching,
      _ => _fromMirrorFields(data),
    };
  }

  static DeliveryLifecycleState _fromMirrorFields(Map<String, dynamic> data) {
    final tripState = data['trip_state']?.toString().trim().toLowerCase() ?? '';
    final status = data['status']?.toString().trim().toLowerCase() ?? '';
    if (tripState == 'accepted' || status == 'accepted') {
      return DeliveryLifecycleState.driverAssigned;
    }
    if (tripState == 'driver_arriving' || status == 'arriving') {
      return DeliveryLifecycleState.driverArrivingPickup;
    }
    if (status == 'on_trip' || tripState == 'in_progress') {
      return DeliveryLifecycleState.onDelivery;
    }
    if (status == 'completed' || tripState == 'completed') {
      return DeliveryLifecycleState.completed;
    }
    if (status == 'cancelled' || tripState == 'cancelled') {
      return DeliveryLifecycleState.cancelled;
    }
    return DeliveryLifecycleState.searching;
  }

  static String canonicalAssignedDriverId(Map<String, dynamic>? data) {
    if (data == null) return '';
    const placeholders = <String>{'waiting', 'pending', 'null', 'none', ''};
    for (final key in <String>[
      'matched_driver_id',
      'matchedDriverId',
      'accepted_driver_id',
      'acceptedDriverId',
      'delivery_driver_id',
      'deliveryDriverId',
      'driver_id',
      'driverId',
    ]) {
      final v = data[key]?.toString().trim() ?? '';
      if (v.isEmpty || placeholders.contains(v.toLowerCase())) {
        continue;
      }
      return v;
    }
    return '';
  }

  static bool snapshotShowsAssignedDriver(Map<String, dynamic>? data) {
    return canonicalAssignedDriverId(data).isNotEmpty;
  }

  static bool isChatEligible(Map<String, dynamic>? data) {
    if (data == null || data.isEmpty) return false;
    final state = canonicalStateFromSnapshot(data);
    return state != DeliveryLifecycleState.searching &&
        state != DeliveryLifecycleState.cancelled &&
        state != DeliveryLifecycleState.completed;
  }

  static String uiStatusLabel(DeliveryLifecycleState state) {
    return switch (state) {
      DeliveryLifecycleState.searching => 'Searching for driver',
      DeliveryLifecycleState.driverAssigned => 'Driver assigned',
      DeliveryLifecycleState.driverArrivingPickup => 'Driver heading to pickup',
      DeliveryLifecycleState.pickedUp => 'Order picked up',
      DeliveryLifecycleState.onDelivery => 'On the way',
      DeliveryLifecycleState.arrivedDropoff => 'Driver arrived',
      DeliveryLifecycleState.completed => 'Delivered',
      DeliveryLifecycleState.cancelled => 'Cancelled',
    };
  }
}

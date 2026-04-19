import 'package:flutter/material.dart';

import 'config/rider_app_config.dart';

enum RiderServiceType { ride, dispatchDelivery, groceriesMart, restaurantsFood }

extension RiderServiceTypeX on RiderServiceType {
  String get key => switch (this) {
    RiderServiceType.ride => 'ride',
    RiderServiceType.dispatchDelivery => 'dispatch_delivery',
    RiderServiceType.groceriesMart => 'groceries_mart',
    RiderServiceType.restaurantsFood => 'restaurants_food',
  };

  String get label => switch (this) {
    RiderServiceType.ride => 'Book a Car',
    RiderServiceType.dispatchDelivery => 'Dispatch / Delivery',
    RiderServiceType.groceriesMart => 'Groceries / Mart',
    RiderServiceType.restaurantsFood => 'Restaurants / Food',
  };

  String get detailLabel => switch (this) {
    RiderServiceType.ride => 'Ride',
    RiderServiceType.dispatchDelivery => 'Dispatch / Delivery',
    RiderServiceType.groceriesMart => 'Groceries / Mart',
    RiderServiceType.restaurantsFood => 'Restaurants / Food',
  };

  String get subtitle => switch (this) {
    RiderServiceType.ride => 'Fast city rides with live driver tracking.',
    RiderServiceType.dispatchDelivery =>
      'Send parcels and errands with live dispatch tracking.',
    RiderServiceType.groceriesMart =>
      'Fresh groceries and market runs are on the way.',
    RiderServiceType.restaurantsFood =>
      'Food ordering and delivery is coming soon.',
  };

  IconData get icon => switch (this) {
    RiderServiceType.ride => Icons.local_taxi,
    RiderServiceType.dispatchDelivery => Icons.local_shipping,
    RiderServiceType.groceriesMart => Icons.shopping_bag_outlined,
    RiderServiceType.restaurantsFood => Icons.restaurant_menu,
  };

  bool get isEnabled => RiderFeatureFlags.isServiceEnabled(key);

  bool get isLive => switch (this) {
    RiderServiceType.ride => true,
    RiderServiceType.dispatchDelivery => true,
    RiderServiceType.groceriesMart => false,
    RiderServiceType.restaurantsFood => false,
  };
}

RiderServiceType riderServiceTypeFromKey(String? rawValue) {
  final normalized = rawValue?.trim().toLowerCase() ?? '';

  return switch (normalized) {
    'dispatch' ||
    'dispatch_delivery' ||
    'dispatch/delivery' => RiderServiceType.dispatchDelivery,
    'groceries' ||
    'groceries_mart' ||
    'groceries/mart' => RiderServiceType.groceriesMart,
    'restaurants' ||
    'restaurants_food' ||
    'restaurants/food' => RiderServiceType.restaurantsFood,
    _ => RiderServiceType.ride,
  };
}

String riderServiceStatusLabel(RiderServiceType serviceType, String rawStatus) {
  final status = rawStatus.trim().toLowerCase();
  if (status.isEmpty) {
    return serviceType == RiderServiceType.dispatchDelivery
        ? 'Dispatch requested'
        : 'Trip requested';
  }

  return switch (serviceType) {
    RiderServiceType.dispatchDelivery => switch (status) {
      'searching' => 'Finding a dispatch driver',
      'pending_driver_acceptance' => 'Driver matched. Waiting for acceptance',
      'pending_driver_action' => 'Driver matched. Waiting for acceptance',
      'accepted' => 'Dispatch accepted',
      'arriving' => 'Driver heading to pickup',
      'arrived' => 'Driver arrived at pickup',
      'on_trip' => 'Dispatch in progress',
      'completed' => 'Dispatch completed',
      'cancelled' => 'Dispatch cancelled',
      _ => 'Dispatch update',
    },
    _ => switch (status) {
      'searching' => 'Finding a driver',
      'pending_driver_acceptance' => 'Driver matched. Waiting for acceptance',
      'pending_driver_action' => 'Driver matched. Waiting for acceptance',
      'accepted' => 'Ride accepted',
      'arriving' => 'Driver heading to pickup',
      'arrived' => 'Driver arrived',
      'on_trip' => 'Trip in progress',
      'completed' => 'Trip completed',
      'cancelled' => 'Trip cancelled',
      _ => 'Trip update',
    },
  };
}

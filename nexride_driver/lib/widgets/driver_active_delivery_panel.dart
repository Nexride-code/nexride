import 'package:flutter/material.dart';

import '../trip_sync/delivery_state_machine.dart';

/// Slice 3: driver-side active dispatch-delivery panel.
///
/// This is intentionally a self-contained, dependency-injected widget that is
/// driven entirely by [DeliveryStateMachine] state — it shares no code with the
/// ride trip panel (`_buildTripPanel`) and never touches the ride lifecycle.
/// The panel surfaces the canonical delivery status and a single primary action
/// that maps to the next `updateDeliveryState` transition for the driver.
class DriverActiveDeliveryPanel extends StatelessWidget {
  const DriverActiveDeliveryPanel({
    super.key,
    required this.delivery,
    required this.state,
    required this.busy,
    required this.onAdvance,
  });

  final Map<String, dynamic> delivery;
  final DeliveryLifecycleState state;
  final bool busy;

  /// Called with the canonical target delivery_state string, e.g.
  /// `driver_arriving_pickup`, `picked_up`, `on_delivery`, `arrived_dropoff`,
  /// `completed`.
  final void Function(String targetState) onAdvance;

  static const Color _gold = Color(0xFFFFC107);

  /// Driver progression: each active state maps to the next action + label.
  static ({String label, String target})? _nextActionFor(
    DeliveryLifecycleState state,
  ) {
    return switch (state) {
      DeliveryLifecycleState.driverAssigned =>
        (label: 'Head to pickup', target: 'driver_arriving_pickup'),
      DeliveryLifecycleState.driverArrivingPickup =>
        (label: 'Confirm pickup', target: 'picked_up'),
      DeliveryLifecycleState.pickedUp =>
        (label: 'Start delivery', target: 'on_delivery'),
      DeliveryLifecycleState.onDelivery =>
        (label: 'Arrived at drop-off', target: 'arrived_dropoff'),
      DeliveryLifecycleState.arrivedDropoff =>
        (label: 'Complete delivery', target: 'completed'),
      DeliveryLifecycleState.searching ||
      DeliveryLifecycleState.completed ||
      DeliveryLifecycleState.cancelled =>
        null,
    };
  }

  String _text(dynamic value) => value?.toString().trim() ?? '';

  String _addressFrom(dynamic node, String fallbackKey) {
    if (node is Map) {
      final addr = _text(node['address']);
      if (addr.isNotEmpty) return addr;
    }
    return _text(delivery[fallbackKey]);
  }

  @override
  Widget build(BuildContext context) {
    final action = _nextActionFor(state);
    final statusLabel = DeliveryStateMachine.uiStatusLabel(state);
    final pickupAddress =
        _addressFrom(delivery['pickup'], 'pickup_address');
    final dropoffAddress =
        _addressFrom(delivery['dropoff'], 'dropoff_address');
    final recipientName = _text(delivery['recipient_name']);
    final packageDescription = _text(delivery['package_description']);

    return Positioned.fill(
      child: DraggableScrollableSheet(
        initialChildSize: 0.34,
        minChildSize: 0.16,
        maxChildSize: 0.66,
        snap: true,
        snapSizes: const <double>[0.16, 0.34, 0.66],
        builder: (BuildContext context, ScrollController scrollController) {
          return SingleChildScrollView(
            controller: scrollController,
            physics: const ClampingScrollPhysics(),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: SafeArea(
                top: false,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(18),
                    boxShadow: const <BoxShadow>[
                      BoxShadow(
                        color: Color(0x1A000000),
                        blurRadius: 18,
                        offset: Offset(0, -2),
                      ),
                    ],
                  ),
                  padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Center(
                        child: Container(
                          width: 42,
                          height: 4,
                          margin: const EdgeInsets.only(bottom: 12),
                          decoration: BoxDecoration(
                            color: Colors.black12,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      Row(
                        children: <Widget>[
                          const Icon(
                            Icons.local_shipping_rounded,
                            size: 20,
                            color: Colors.black87,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              statusLabel,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: Colors.black87,
                              ),
                            ),
                          ),
                          const _DispatchBadge(),
                        ],
                      ),
                      const SizedBox(height: 14),
                      if (pickupAddress.isNotEmpty)
                        _DeliveryAddressRow(
                          icon: Icons.store_mall_directory_outlined,
                          label: 'Pickup',
                          value: pickupAddress,
                        ),
                      if (dropoffAddress.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 10),
                        _DeliveryAddressRow(
                          icon: Icons.flag_outlined,
                          label: 'Drop-off',
                          value: dropoffAddress,
                        ),
                      ],
                      if (recipientName.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 10),
                        _DeliveryAddressRow(
                          icon: Icons.person_outline,
                          label: 'Recipient',
                          value: recipientName,
                        ),
                      ],
                      if (packageDescription.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 10),
                        _DeliveryAddressRow(
                          icon: Icons.inventory_2_outlined,
                          label: 'Package',
                          value: packageDescription,
                        ),
                      ],
                      const SizedBox(height: 18),
                      if (action != null)
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _gold,
                            disabledBackgroundColor:
                                _gold.withValues(alpha: 0.5),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          onPressed:
                              busy ? null : () => onAdvance(action.target),
                          child: busy
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      Colors.black,
                                    ),
                                  ),
                                )
                              : Text(
                                  action.label,
                                  style: const TextStyle(
                                    color: Colors.black,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 15,
                                  ),
                                ),
                        )
                      else
                        const SizedBox.shrink(),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _DispatchBadge extends StatelessWidget {
  const _DispatchBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Text(
        'Dispatch',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: Colors.black54,
        ),
      ),
    );
  }
}

class _DeliveryAddressRow extends StatelessWidget {
  const _DeliveryAddressRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(icon, size: 18, color: Colors.black45),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                label,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Colors.black45,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

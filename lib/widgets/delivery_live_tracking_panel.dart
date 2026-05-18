import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../trip_sync/delivery_state_machine.dart';

/// Driver card + actions for active delivery (customer / merchant).
class DeliveryLiveTrackingPanel extends StatelessWidget {
  const DeliveryLiveTrackingPanel({
    super.key,
    required this.deliveryData,
    required this.statusLabel,
    this.driverName = 'Driver',
    this.driverRating,
    this.vehicleLabel = '',
    this.plate = '',
    this.pickupLabel = '',
    this.dropoffLabel = '',
    this.etaMinutes,
    this.onOpenChat,
    this.onCall,
    this.onReport,
    this.showChat = true,
    this.showCall = true,
    this.unreadChatCount = 0,
    this.driverPosition,
  });

  final Map<String, dynamic> deliveryData;
  final String statusLabel;
  final String driverName;
  final double? driverRating;
  final String vehicleLabel;
  final String plate;
  final String pickupLabel;
  final String dropoffLabel;
  final int? etaMinutes;
  final VoidCallback? onOpenChat;
  final VoidCallback? onCall;
  final VoidCallback? onReport;
  final bool showChat;
  final bool showCall;
  final int unreadChatCount;
  final LatLng? driverPosition;

  static bool showsAssignedDriver(Map<String, dynamic>? data) =>
      DeliveryStateMachine.snapshotShowsAssignedDriver(data);

  @override
  Widget build(BuildContext context) {
    final assigned = showsAssignedDriver(deliveryData);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.black.withValues(alpha: 0.08)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  assigned ? Icons.delivery_dining : Icons.hourglass_top,
                  color: assigned ? const Color(0xFF0F6B47) : Colors.orange,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    statusLabel,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                ),
              ],
            ),
            if (pickupLabel.isNotEmpty) ...<Widget>[
              const SizedBox(height: 10),
              Text('Pickup: $pickupLabel', style: const TextStyle(fontSize: 13)),
            ],
            if (dropoffLabel.isNotEmpty) ...<Widget>[
              const SizedBox(height: 4),
              Text('Dropoff: $dropoffLabel', style: const TextStyle(fontSize: 13)),
            ],
            if (etaMinutes != null && etaMinutes! > 0) ...<Widget>[
              const SizedBox(height: 6),
              Text('ETA ~$etaMinutes min', style: const TextStyle(fontSize: 13)),
            ],
            if (assigned) ...<Widget>[
              const SizedBox(height: 14),
              Row(
                children: <Widget>[
                  CircleAvatar(
                    backgroundColor: const Color(0xFFE8F5E9),
                    child: Text(
                      driverName.isNotEmpty ? driverName[0].toUpperCase() : 'D',
                      style: const TextStyle(
                        color: Color(0xFF1B5E20),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          driverName,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        if (driverRating != null)
                          Text('★ ${driverRating!.toStringAsFixed(1)}'),
                        if (vehicleLabel.isNotEmpty || plate.isNotEmpty)
                          Text(
                            [vehicleLabel, plate]
                                .where((s) => s.trim().isNotEmpty)
                                .join(' • '),
                            style: const TextStyle(fontSize: 12),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  if (showChat)
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: onOpenChat,
                        icon: Badge(
                          isLabelVisible: unreadChatCount > 0,
                          label: Text('$unreadChatCount'),
                          child: const Icon(Icons.chat_bubble_outline),
                        ),
                        label: const Text('Chat'),
                      ),
                    ),
                  if (showChat && showCall) const SizedBox(width: 8),
                  if (showCall)
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: onCall,
                        icon: const Icon(Icons.call_outlined),
                        label: const Text('Call'),
                      ),
                    ),
                ],
              ),
              if (onReport != null) ...<Widget>[
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: onReport,
                  icon: const Icon(Icons.flag_outlined, size: 18),
                  label: const Text('Report issue'),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

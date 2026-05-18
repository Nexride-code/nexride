import 'dart:async';

import 'package:firebase_database/firebase_database.dart' as rtdb;
import 'package:flutter/material.dart';

import '../domain/delivery_state_machine.dart';

/// Live delivery tracking on merchant order detail (RTDB `delivery_requests`).
class MerchantDeliveryLivePanel extends StatefulWidget {
  const MerchantDeliveryLivePanel({
    super.key,
    required this.deliveryId,
    this.onOpenChat,
    this.onCall,
    this.onReport,
  });

  final String deliveryId;
  final VoidCallback? onOpenChat;
  final VoidCallback? onCall;
  final VoidCallback? onReport;

  @override
  State<MerchantDeliveryLivePanel> createState() =>
      _MerchantDeliveryLivePanelState();
}

class _MerchantDeliveryLivePanelState extends State<MerchantDeliveryLivePanel> {
  StreamSubscription<rtdb.DatabaseEvent>? _sub;
  Map<String, dynamic>? _delivery;
  String? _listenerError;

  @override
  void initState() {
    super.initState();
    debugPrint(
      'MERCHANT_RESTORE_ACTIVE_DELIVERY deliveryId=${widget.deliveryId}',
    );
    _attachListener();
  }

  @override
  void didUpdateWidget(covariant MerchantDeliveryLivePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.deliveryId != widget.deliveryId) {
      unawaited(_attachListener());
    }
  }

  Future<void> _attachListener() async {
    await _sub?.cancel();
    _sub = null;
    final id = widget.deliveryId.trim();
    if (id.isEmpty) {
      return;
    }
    try {
      _sub = rtdb.FirebaseDatabase.instance
          .ref('delivery_requests/$id')
          .onValue
          .listen(
        (event) {
          if (!mounted) {
            return;
          }
          final raw = event.snapshot.value;
          setState(() {
            _listenerError = null;
            if (raw is Map) {
              _delivery = Map<String, dynamic>.from(raw);
            } else {
              _delivery = null;
            }
          });
        },
        onError: (Object error) {
          if (!mounted) {
            return;
          }
          setState(() {
            _listenerError = error.toString();
          });
        },
      );
    } catch (e) {
      if (mounted) {
        setState(() => _listenerError = e.toString());
      }
    }
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final data = _delivery;
    if (_listenerError != null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text('Delivery sync issue: $_listenerError'),
        ),
      );
    }
    if (data == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(12),
          child: Text('Waiting for delivery data…'),
        ),
      );
    }
    final assigned = DeliveryStateMachine.snapshotShowsAssignedDriver(data);
    final status = DeliveryStateMachine.uiStatusLabel(data);
    final driverName = data['driver_name']?.toString().trim().isNotEmpty == true
        ? data['driver_name'].toString()
        : 'Driver';
    final plate = data['plate']?.toString() ?? data['driver_plate']?.toString() ?? '';
    final car = data['car']?.toString() ?? data['vehicle']?.toString() ?? '';
    final eta = data['eta_minutes'];
    final pickup = data['pickup_address']?.toString() ??
        data['pickup']?.toString() ??
        '';
    final dropoff = data['destination_address']?.toString() ??
        data['dropoff_address']?.toString() ??
        '';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Delivery', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            Text(status, style: const TextStyle(fontWeight: FontWeight.w700)),
            if (!assigned)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Waiting for a driver to accept…'),
              ),
            if (assigned) ...<Widget>[
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const CircleAvatar(child: Icon(Icons.delivery_dining)),
                title: Text(driverName),
                subtitle: Text(
                  [car, plate].where((s) => s.trim().isNotEmpty).join(' • '),
                ),
              ),
              if (eta is num && eta > 0)
                Text('ETA ~${eta.toStringAsFixed(0)} min'),
              if (pickup.trim().isNotEmpty) ...<Widget>[
                const SizedBox(height: 8),
                Text('Pickup: $pickup', style: const TextStyle(fontSize: 12)),
              ],
              if (dropoff.trim().isNotEmpty)
                Text('Dropoff: $dropoff', style: const TextStyle(fontSize: 12)),
              const SizedBox(height: 10),
              Row(
                children: <Widget>[
                  if (widget.onOpenChat != null)
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: widget.onOpenChat,
                        icon: const Icon(Icons.chat_bubble_outline),
                        label: const Text('Chat'),
                      ),
                    ),
                  if (widget.onOpenChat != null && widget.onCall != null)
                    const SizedBox(width: 8),
                  if (widget.onCall != null)
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: widget.onCall,
                        icon: const Icon(Icons.call_outlined),
                        label: const Text('Call'),
                      ),
                    ),
                ],
              ),
              if (widget.onReport != null)
                TextButton.icon(
                  onPressed: widget.onReport,
                  icon: const Icon(Icons.flag_outlined, size: 18),
                  label: const Text('Report issue'),
                ),
            ],
          ],
        ),
      ),
    );
  }
}


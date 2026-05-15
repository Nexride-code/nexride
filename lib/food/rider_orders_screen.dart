import 'dart:async';

import 'package:flutter/material.dart';

import '../services/rider_ride_cloud_functions_service.dart';

/// Rider's own order history/status screen for merchant food orders.
class RiderOrdersScreen extends StatefulWidget {
  const RiderOrdersScreen({super.key});

  @override
  State<RiderOrdersScreen> createState() => _RiderOrdersScreenState();
}

class _RiderOrdersScreenState extends State<RiderOrdersScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _orders = const <Map<String, dynamic>>[];

  static const Map<String, String> _statusLabel = <String, String>{
    'pending_merchant': 'Awaiting merchant',
    'merchant_accepted': 'Accepted by merchant',
    'preparing': 'Being prepared',
    'ready_for_pickup': 'Ready for pickup',
    'dispatching': 'Driver assigned',
    'completed': 'Delivered',
    'cancelled': 'Cancelled',
    'merchant_rejected': 'Rejected',
  };

  static const Map<String, Color> _statusColor = <String, Color>{
    'pending_merchant': Color(0xFFB57A2A),
    'merchant_accepted': Color(0xFF2F6DA8),
    'preparing': Color(0xFF2F6DA8),
    'ready_for_pickup': Color(0xFF198754),
    'dispatching': Color(0xFF198754),
    'completed': Color(0xFF198754),
    'cancelled': Color(0xFFD64545),
    'merchant_rejected': Color(0xFFD64545),
  };

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await RiderRideCloudFunctionsService.instance.riderListMyOrders();
      if (r['success'] == true && r['orders'] is List) {
        final list = <Map<String, dynamic>>[];
        for (final o in r['orders'] as List<dynamic>) {
          if (o is Map) list.add(o.map((k, v) => MapEntry(k.toString(), v)));
        }
        if (mounted) setState(() { _orders = list; _loading = false; });
      } else {
        throw StateError(r['reason']?.toString() ?? 'load_failed');
      }
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My orders'),
        actions: <Widget>[
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(_error!, textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: _load, child: const Text('Retry')),
                ],
              ),
            )
          : _orders.isEmpty
          ? const Center(child: Text('No orders yet.'))
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: _orders.length,
                separatorBuilder: (context2, index2) => const SizedBox(height: 10),
                itemBuilder: (context, i) {
                  final o = _orders[i];
                  final status = o['order_status']?.toString() ?? '';
                  final label = _statusLabel[status] ?? status;
                  final color = _statusColor[status] ?? Colors.grey;
                  final total = o['total_ngn'];
                  final orderId = o['order_id']?.toString() ?? '';
                  final deliveryId = o['delivery_id']?.toString() ?? '';
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(children: <Widget>[
                            Expanded(
                              child: Text(
                                o['pickup_snapshot']?['business_name']?.toString() ??
                                    'Merchant order',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700, fontSize: 15,
                                ),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: color.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                label,
                                style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
                              ),
                            ),
                          ]),
                          const SizedBox(height: 6),
                          if (total != null)
                            Text('Total: ₦$total', style: const TextStyle(fontSize: 13)),
                          const SizedBox(height: 4),
                          Text(
                            'Order ID: ${orderId.length > 12 ? orderId.substring(0, 12) : orderId}',
                            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                          ),
                          if (deliveryId.isNotEmpty)
                            Text(
                              'Delivery ID: ${deliveryId.length > 12 ? deliveryId.substring(0, 12) : deliveryId}...',
                              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                            ),
                          if ((o['line_items'] as List?)?.isNotEmpty == true) ...[
                            const SizedBox(height: 6),
                            Text(
                              (o['line_items'] as List<dynamic>)
                                  .map((l) => '${l['qty']}× ${l['name_snapshot'] ?? l['item_id']}')
                                  .join(', '),
                              style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
    );
  }
}

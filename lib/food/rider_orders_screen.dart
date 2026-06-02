import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart' as rtdb;
import 'package:flutter/material.dart';

import '../services/rider_ride_cloud_functions_service.dart';
import '../support/startup_rtdb_support.dart';
import '../trip_detail_screen.dart';

/// Rider's own order history — delivery/food/mart orders only (not ride trips).
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

  static const Set<String> _terminalStatuses = <String>{
    'completed',
    'cancelled',
    'merchant_rejected',
  };

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Map<String, dynamic> _normalizeHistoryOrder(
    Map<String, dynamic> raw,
    String fallbackId,
  ) {
    final orderId = raw['orderId']?.toString() ??
        raw['order_id']?.toString() ??
        raw['trip_id']?.toString() ??
        fallbackId;
    final pickup = raw['pickup'];
    return <String, dynamic>{
      ...raw,
      'order_id': orderId,
      'order_status': raw['order_status']?.toString() ?? raw['status']?.toString() ?? '',
      'total_ngn': raw['total_ngn'] ?? raw['fare'],
      'pickup_snapshot': raw['pickup_snapshot'] ??
          (pickup is Map
              ? <String, dynamic>{
                  'business_name': pickup['address']?.toString(),
                  ...pickup.map((k, v) => MapEntry(k.toString(), v)),
                }
              : null),
      'delivery_id': raw['delivery_id'] ?? raw['deliveryId'],
      'type': 'order',
    };
  }

  Future<List<Map<String, dynamic>>> _loadOrderHistory(String userId) async {
    final snapshot = await runOptionalStartupRead<rtdb.DataSnapshot>(
      source: 'rider_orders.history',
      path: 'user_order_history/$userId',
      action: () => rtdb.FirebaseDatabase.instance.ref('user_order_history/$userId').get(),
    );
    if (snapshot == null || !snapshot.exists) {
      return const <Map<String, dynamic>>[];
    }
    final data = Map<Object?, Object?>.from(snapshot.value as Map);
    final out = <Map<String, dynamic>>[];
    data.forEach((key, value) {
      if (value is! Map) {
        return;
      }
      final row = value.map<String, dynamic>(
        (dynamic k, dynamic v) => MapEntry(k.toString(), v),
      );
      out.add(_normalizeHistoryOrder(row, key?.toString() ?? ''));
    });
    return out;
  }

  Future<List<Map<String, dynamic>>> _loadActiveOrders() async {
    final r = await RiderRideCloudFunctionsService.instance.riderListMyOrders();
    if (r['success'] != true || r['orders'] is! List) {
      return const <Map<String, dynamic>>[];
    }
    final list = <Map<String, dynamic>>[];
    for (final o in r['orders'] as List<dynamic>) {
      if (o is! Map) {
        continue;
      }
      final row = o.map((k, v) => MapEntry(k.toString(), v));
      final status = row['order_status']?.toString() ?? '';
      if (_terminalStatuses.contains(status)) {
        continue;
      }
      list.add(row);
    }
    return list;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final userId = FirebaseAuth.instance.currentUser?.uid ?? '';
      if (userId.isEmpty) {
        throw StateError('not_signed_in');
      }
      final history = await _loadOrderHistory(userId);
      final active = await _loadActiveOrders();
      final merged = <String, Map<String, dynamic>>{};
      for (final order in history) {
        final id = order['order_id']?.toString() ?? '';
        if (id.isNotEmpty) {
          merged[id] = order;
        }
      }
      for (final order in active) {
        final id = order['order_id']?.toString() ?? '';
        if (id.isNotEmpty) {
          merged[id] = order;
        }
      }
      final list = merged.values.toList()
        ..sort((a, b) => _orderTimestamp(b).compareTo(_orderTimestamp(a)));
      if (mounted) {
        setState(() {
          _orders = list;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  int _orderTimestamp(Map<String, dynamic> order) {
    for (final key in <String>[
      'completed_at',
      'completedAt',
      'cancelled_at',
      'cancelledAt',
      'updated_at',
      'created_at',
      'createdAt',
      'timestamp',
    ]) {
      final value = order[key];
      if (value is num) {
        return value.toInt();
      }
      final parsed = int.tryParse(value?.toString() ?? '');
      if (parsed != null) {
        return parsed;
      }
    }
    return 0;
  }

  Future<void> _openOrderDetail(Map<String, dynamic> order) async {
    final orderId = order['order_id']?.toString() ?? '';
    final userId = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (orderId.isEmpty || userId.isEmpty) {
      return;
    }
    final pickup = order['pickup'];
    final dropoff = order['dropoff'] ?? order['destination'];
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => TripDetailScreen(
          tripId: orderId,
          riderId: userId,
          tripData: <String, dynamic>{
            ...order,
            'type': 'order',
            'trip_id': orderId,
            'pickup_address': order['pickup_snapshot']?['business_name'] ??
                (pickup is Map ? pickup['address'] : null),
            'destination_address': dropoff is Map
                ? dropoff['address']?.toString()
                : order['destination_address']?.toString(),
            'fare': order['total_ngn'] ?? order['fare'],
            'status': order['order_status'] ?? order['status'],
          },
        ),
      ),
    );
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
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => _openOrderDetail(o),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Row(children: <Widget>[
                              Expanded(
                                child: Text(
                                  o['pickup_snapshot']?['business_name']?.toString() ??
                                      o['food_order_summary']?.toString() ??
                                      'Delivery order',
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
                    ),
                  );
                },
              ),
            ),
    );
  }
}

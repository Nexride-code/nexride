import 'dart:async';

import 'package:flutter/material.dart';

import '../../admin/admin_config.dart';
import '../merchant_portal_functions.dart';
import '../merchant_portal_utils.dart';

const Map<String, List<String>> _kNextStatuses = <String, List<String>>{
  'pending_merchant': <String>['merchant_accepted', 'merchant_rejected'],
  'merchant_accepted': <String>['preparing'],
  'preparing': <String>['ready_for_pickup'],
  'ready_for_pickup': <String>['dispatching'],
};

class MerchantOrdersScreen extends StatefulWidget {
  const MerchantOrdersScreen({super.key});

  @override
  State<MerchantOrdersScreen> createState() => _MerchantOrdersScreenState();
}

class _MerchantOrdersScreenState extends State<MerchantOrdersScreen> {
  bool _loading = true;
  String? _err;
  List<Map<String, dynamic>> _orders = const <Map<String, dynamic>>[];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _err = null;
    });
    try {
      final r = await MerchantPortalFunctions().merchantListMyOrders();
      if (!mpSuccess(r['success'])) {
        throw StateError(r['reason']?.toString() ?? 'load_failed');
      }
      final list = <Map<String, dynamic>>[];
      if (r['orders'] is List) {
        for (final o in r['orders'] as List<dynamic>) {
          if (o is Map) {
            list.add(o.map((k, v) => MapEntry(k.toString(), v)));
          }
        }
      }
      if (mounted) {
        setState(() {
          _orders = list;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _err = e.toString();
          _loading = false;
        });
      }
    }
  }

  Future<void> _setStatus(String orderId, String status) async {
    final r = await MerchantPortalFunctions().merchantUpdateOrderStatus(<String, dynamic>{
      'order_id': orderId,
      'status': status,
    });
    if (!mpSuccess(r['success'])) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(r['reason']?.toString() ?? 'update_failed')),
        );
      }
      return;
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AdminThemeTokens.canvas,
      appBar: AppBar(
        title: const Text('Orders'),
        actions: <Widget>[
          IconButton(onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _err != null
          ? Center(child: Text(_err!))
          : _orders.isEmpty
          ? const Center(child: Text('No orders yet.'))
          : ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: _orders.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, i) {
                final o = _orders[i];
                final id = o['order_id']?.toString() ?? '';
                final st = o['order_status']?.toString() ?? '';
                final total = o['total_ngn'];
                final next = _kNextStatuses[st] ?? const <String>[];
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          id,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        Text('Status: $st · Total: ₦$total'),
                        if ((o['delivery_id']?.toString() ?? '').isNotEmpty)
                          Text('Delivery: ${o['delivery_id']}'),
                        if (next.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: next
                                .map(
                                  (s) => ActionChip(
                                    label: Text(s.replaceAll('_', ' ')),
                                    onPressed: id.isEmpty ? null : () => _setStatus(id, s),
                                  ),
                                )
                                .toList(),
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}

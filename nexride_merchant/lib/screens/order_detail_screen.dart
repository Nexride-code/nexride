import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../domain/merchant_order_status.dart';
import '../state/merchant_app_state.dart';
import '../utils/nx_callable_messages.dart';

class OrderDetailScreen extends StatefulWidget {
  const OrderDetailScreen({super.key, required this.order});

  final Map<String, dynamic> order;

  @override
  State<OrderDetailScreen> createState() => _OrderDetailScreenState();
}

class _OrderDetailScreenState extends State<OrderDetailScreen> {
  bool _busy = false;
  late Map<String, dynamic> _order;

  @override
  void initState() {
    super.initState();
    _order = Map<String, dynamic>.from(widget.order);
  }

  Future<void> _setStatus(String next) async {
    setState(() => _busy = true);
    try {
      final gw = context.read<MerchantAppState>().gateway;
      final res = await gw.merchantUpdateOrderStatus(<String, dynamic>{
        'order_id': _order['order_id'],
        'status': next,
      });
      if (!mounted) return;
      if (!nxSuccess(res['success'])) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              nxMapFailureMessage(
                Map<String, dynamic>.from(res),
                'Order status could not be updated.',
              ),
            ),
          ),
        );
        return;
      }
      setState(() {
        _order['order_status'] = res['order_status'] ?? next;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Order updated')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(nxUserFacingMessage(e))),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final oid = '${widget.order['order_id'] ?? ''}'.trim();
    if (oid.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Order')),
        body: const Center(child: Text('Invalid order')),
      );
    }
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection('merchant_orders').doc(oid).snapshots(),
      builder: (context, snap) {
        Map<String, dynamic> row = Map<String, dynamic>.from(_order);
        if (snap.hasData && snap.data?.exists == true && snap.data!.data() != null) {
          row = <String, dynamic>{'order_id': oid, ...snap.data!.data()!};
        }
        final status = '${row['order_status'] ?? ''}';
        final actions = nextMerchantActions(status);
        return Scaffold(
          appBar: AppBar(title: Text('Order ${row['order_id']}')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: <Widget>[
              Text('Status: ${orderStatusLabel(status)}',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              Text('Payment: ${row['payment_status'] ?? '—'}'),
              Text('Total: ₦${row['total_ngn'] ?? row['total'] ?? '—'}'),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text('Preparation & SLA', style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: 8),
                      Text('Accepted at: ${_fmtTs(row['merchant_accepted_at'])}'),
                      Text('Preparing started: ${_fmtTs(row['preparing_started_at'])}'),
                      Text('Ready for pickup: ${_fmtTs(row['ready_for_pickup_at'])}'),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              if (actions.isNotEmpty)
                Text('Actions', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              for (final a in actions)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: FilledButton(
                    onPressed: _busy ? null : () => _setStatus(a),
                    child: Text(transitionCta(a)),
                  ),
                ),
              const Divider(height: 32),
              if (kDebugMode) ...<Widget>[
                Text('Debug snapshot', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 8),
                SelectableText(row.toString()),
              ],
            ],
          ),
        );
      },
    );
  }

  String _fmtTs(dynamic v) {
    if (v == null) return '—';
    if (v is Timestamp) {
      return v.toDate().toLocal().toString().split('.').first;
    }
    return '—';
  }
}

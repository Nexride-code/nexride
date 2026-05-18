import 'dart:async' show unawaited;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../domain/merchant_order_status.dart';
import '../state/merchant_app_state.dart';
import '../utils/nx_callable_messages.dart';
import '../services/merchant_delivery_call_service.dart';
import '../services/merchant_delivery_report_service.dart';
import '../widgets/merchant_delivery_chat_sheet.dart';
import '../widgets/merchant_delivery_live_panel.dart';

class OrderDetailScreen extends StatefulWidget {
  const OrderDetailScreen({super.key, required this.order});

  final Map<String, dynamic> order;

  @override
  State<OrderDetailScreen> createState() => _OrderDetailScreenState();
}

class _OrderDetailScreenState extends State<OrderDetailScreen> {
  bool _busy = false;
  bool _callBusy = false;
  late Map<String, dynamic> _order;
  final MerchantDeliveryCallService _deliveryCallService =
      MerchantDeliveryCallService();
  final MerchantDeliveryReportService _deliveryReportService =
      MerchantDeliveryReportService();

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
              if ('${row['delivery_id'] ?? ''}'.trim().isNotEmpty) ...<Widget>[
                const SizedBox(height: 16),
                MerchantDeliveryLivePanel(
                  deliveryId: '${row['delivery_id']}',
                  onOpenChat: () {
                    final deliveryId = '${row['delivery_id']}'.trim();
                    showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      builder: (_) => SizedBox(
                        height: MediaQuery.of(context).size.height * 0.7,
                        child: MerchantDeliveryChatSheet(deliveryId: deliveryId),
                      ),
                    );
                  },
                  onCall: () => unawaited(_startMerchantDeliveryCall(row)),
                  onReport: () => unawaited(_showMerchantDeliveryReport(row)),
                ),
              ],
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

  Future<void> _startMerchantDeliveryCall(Map<String, dynamic> row) async {
    if (_callBusy) {
      return;
    }
    final deliveryId = '${row['delivery_id'] ?? ''}'.trim();
    final authUid = FirebaseAuth.instance.currentUser?.uid;
    if (deliveryId.isEmpty || authUid == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Delivery or sign-in is not ready for calls.')),
        );
      }
      return;
    }
    setState(() => _callBusy = true);
    try {
      await _deliveryCallService.startMerchantToDriverCall(
        deliveryId: deliveryId,
        merchantUid: authUid,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Secure call channel is ready.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Call could not start: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _callBusy = false);
      }
    }
  }

  Future<void> _showMerchantDeliveryReport(Map<String, dynamic> row) async {
    final deliveryId = '${row['delivery_id'] ?? ''}'.trim();
    if (deliveryId.isEmpty) {
      return;
    }
    final reasonCtrl = TextEditingController();
    final messageCtrl = TextEditingController();
    final submitted = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Report delivery issue'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: reasonCtrl,
              decoration: const InputDecoration(labelText: 'Reason'),
            ),
            TextField(
              controller: messageCtrl,
              decoration: const InputDecoration(labelText: 'Details'),
              maxLines: 3,
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Submit')),
        ],
      ),
    );
    final reason = reasonCtrl.text.trim().isEmpty ? 'order_issue' : reasonCtrl.text.trim();
    final message = messageCtrl.text.trim().isEmpty
        ? 'Merchant reported an issue from order detail.'
        : messageCtrl.text.trim();
    reasonCtrl.dispose();
    messageCtrl.dispose();
    if (submitted != true || !mounted) {
      return;
    }
    try {
      await _deliveryReportService.submitReport(
        deliveryId: deliveryId,
        reason: reason,
        message: message,
        merchantId: '${row['merchant_id'] ?? ''}'.trim(),
        customerId: '${row['customer_id'] ?? ''}'.trim(),
        driverId: '${row['driver_id'] ?? row['matched_driver_id'] ?? ''}'.trim(),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Report submitted. Support will follow up.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not submit report: $e')),
        );
      }
    }
  }

  String _fmtTs(dynamic v) {
    if (v == null) return '—';
    if (v is Timestamp) {
      return v.toDate().toLocal().toString().split('.').first;
    }
    return '—';
  }
}

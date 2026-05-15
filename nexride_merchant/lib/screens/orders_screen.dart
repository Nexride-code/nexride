import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../domain/merchant_order_status.dart';
import '../state/merchant_app_state.dart';
import '../utils/nx_callable_messages.dart';
import '../widgets/nx_feedback.dart';
import '../widgets/nx_skeleton.dart';
import 'order_detail_screen.dart';

class OrdersScreen extends StatefulWidget {
  const OrdersScreen({super.key});

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  bool _loading = true;
  String? _loadError;
  String? _reasonCode;
  List<Map<String, dynamic>> _orders = const <Map<String, dynamic>>[];
  int _loadEpoch = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_loadOrders());
  }

  void _logOrders(String message, {String? reasonCode}) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final mid = context.read<MerchantAppState>().merchant?.merchantId ?? '';
    debugPrint(
      '[merchant_orders] callable=merchantListMyOrders merchantId=$mid uid=$uid '
      'reason_code=${reasonCode ?? _reasonCode ?? 'none'} $message',
    );
  }

  Future<void> _loadOrders() async {
    final epoch = ++_loadEpoch;
    final state = context.read<MerchantAppState>();
    final mid = state.merchant?.merchantId ?? '';

    if (mid.isEmpty) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = null;
          _reasonCode = 'no_merchant';
          _orders = const <Map<String, dynamic>>[];
        });
      }
      return;
    }

    if (!state.isApproved) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError =
              'Your store is not approved yet. Orders will appear after NexRide approves your business.';
          _reasonCode = 'merchant_not_approved';
          _orders = const <Map<String, dynamic>>[];
        });
      }
      _logOrders('blocked not approved', reasonCode: 'merchant_not_approved');
      return;
    }

    setState(() {
      _loading = true;
      _loadError = null;
      _reasonCode = null;
    });

    try {
      final res = await state.gateway.merchantListMyOrders();
      if (epoch != _loadEpoch || !mounted) {
        return;
      }
      if (res['success'] != true) {
        final reason = '${res['reason'] ?? res['reason_code'] ?? 'load_failed'}';
        _logOrders('callable failed', reasonCode: reason);
        setState(() {
          _loading = false;
          _loadError = nxMapFailureMessage(
            Map<String, dynamic>.from(res),
            'Could not load orders. Pull to retry.',
          );
          _reasonCode = reason;
          _orders = const <Map<String, dynamic>>[];
        });
        return;
      }
      final list = <Map<String, dynamic>>[];
      final raw = res['orders'];
      if (raw is List) {
        for (final o in raw) {
          if (o is Map) {
            list.add(Map<String, dynamic>.from(o));
          }
        }
      }
      _logOrders('loaded count=${list.length}');
      setState(() {
        _orders = list;
        _loading = false;
        _loadError = null;
        _reasonCode = null;
      });
    } catch (e) {
      if (epoch != _loadEpoch || !mounted) {
        return;
      }
      _logOrders('exception $e', reasonCode: 'exception');
      setState(() {
        _loading = false;
        _loadError = nxUserFacingMessage(e);
        _reasonCode = 'exception';
        _orders = const <Map<String, dynamic>>[];
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<MerchantAppState>(
      builder: (context, state, _) {
        final mid = state.merchant?.merchantId;
        if (mid == null || mid.isEmpty) {
          return const NxEmptyState(
            title: 'No merchant',
            subtitle: 'Sign in to view orders.',
          );
        }

        if (_loading) {
          return const NxSkeletonList();
        }

        if (_loadError != null) {
          return Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              NxInlineError(message: _loadError!),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => unawaited(_loadOrders()),
                child: const Text('Retry'),
              ),
            ],
          );
        }

        if (_orders.isEmpty) {
          return RefreshIndicator(
            onRefresh: _loadOrders,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: const <Widget>[
                SizedBox(height: 120),
                NxEmptyState(
                  title: 'No orders yet',
                  subtitle:
                      'New orders appear here when customers place them while your store is live.',
                  icon: Icons.receipt_long,
                ),
              ],
            ),
          );
        }

        return RefreshIndicator(
          onRefresh: _loadOrders,
          child: ListView.separated(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(12),
            itemCount: _orders.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final o = _orders[i];
              final id = '${o['order_id'] ?? ''}';
              final status = '${o['order_status'] ?? ''}';
              return Card(
                child: ListTile(
                  title: Text('Order $id'),
                  subtitle: Text(orderStatusLabel(status)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => OrderDetailScreen(order: o),
                      ),
                    );
                    if (mounted) {
                      await _loadOrders();
                    }
                  },
                ),
              );
            },
          ),
        );
      },
    );
  }
}

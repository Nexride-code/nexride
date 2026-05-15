import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  int _liveCount = 0;
  int _streamEpoch = 0;

  @override
  Widget build(BuildContext context) {
    return Consumer<MerchantAppState>(
      builder: (context, state, _) {
        final mid = state.merchant?.merchantId;
        if (mid == null || mid.isEmpty) {
          return const NxEmptyState(title: 'No merchant', subtitle: 'Sign in to view orders.');
        }
        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          key: ValueKey<String>('${mid}_$_streamEpoch'),
          stream: FirebaseFirestore.instance
              .collection('merchant_orders')
              .where('merchant_id', isEqualTo: mid)
              .orderBy('created_at', descending: true)
              .limit(50)
              .snapshots(),
          builder: (context, snap) {
            if (snap.hasError) {
              return Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  NxInlineError(message: nxUserFacingMessage(snap.error!)),
                  TextButton(
                    onPressed: () => setState(() => _streamEpoch++),
                    child: const Text('Retry'),
                  ),
                ],
              );
            }
            if (!snap.hasData) {
              return const NxSkeletonList();
            }
            final docs = snap.data!.docs;
            if (docs.length > _liveCount && _liveCount > 0) {
              WidgetsBinding.instance.addPostFrameCallback((_) async {
                try {
                  await SystemSound.play(SystemSoundType.alert);
                } catch (_) {}
              });
            }
            _liveCount = docs.length;

            final merged = docs.map((d) {
              final m = d.data();
              return <String, dynamic>{'order_id': d.id, ...m};
            }).toList(growable: false);

            if (merged.isEmpty) {
              return NxEmptyState(
                title: 'No orders yet',
                subtitle: 'New orders appear here instantly when your store is live.',
                icon: Icons.receipt_long,
              );
            }

            return RefreshIndicator(
              onRefresh: () async => setState(() {}),
              child: ListView.separated(
                padding: const EdgeInsets.all(12),
                itemCount: merged.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, i) {
                  final o = merged[i];
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
                      },
                    ),
                  );
                },
              ),
            );
          },
        );
      },
    );
  }
}

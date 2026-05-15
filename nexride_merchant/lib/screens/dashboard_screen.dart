import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../domain/merchant_portal_access.dart';
import '../models/merchant_profile.dart';
import '../services/merchant_connectivity.dart';
import '../state/merchant_app_state.dart';
import '../utils/nx_callable_messages.dart';
import 'merchant_availability_screen.dart';
import 'store_profile_screen.dart';
import 'verification_documents_screen.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  static String _availabilityLabel(MerchantProfile m) {
    final a = (m.availabilityStatus ?? '').toLowerCase();
    switch (a) {
      case 'open':
        return 'Open';
      case 'closed':
        return 'Closed';
      case 'paused':
        return 'Paused';
      default:
        if (m.isOpen && m.acceptingOrders) return 'Open';
        if (m.isOpen && !m.acceptingOrders) return 'Paused';
        return 'Closed';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<MerchantAppState>(
      builder: (context, state, _) {
        final m = state.merchant;
        if (m == null) {
          return ListView(
            padding: const EdgeInsets.all(16),
            children: const <Widget>[
              Center(child: Text('No merchant context')),
            ],
          );
        }
        final approved = state.isApproved;
        final live = m.isLiveForOrders;
        final statusLine = !approved
            ? 'Pending NexRide approval — you can prepare your menu, but live orders stay off.'
            : live
                ? 'Your store is open and accepting orders from riders.'
                : 'Your store is not accepting live orders right now.';

        return ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            if (!approved)
              MaterialBanner(
                content: const Text(
                  'Awaiting approval. NexRide will review your application before you can go fully live.',
                ),
                leading: const Icon(Icons.hourglass_top_outlined),
                actions: <Widget>[
                  TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const StoreProfileScreen(),
                      ),
                    ),
                    child: const Text('Store details'),
                  ),
                ],
              ),
            Text(
              m.businessName,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
            ),
            const SizedBox(height: 8),
            Text(statusLine),
            if (m.portalLastSeenMs != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                'Portal last active: ${DateTime.fromMillisecondsSinceEpoch(m.portalLastSeenMs!, isUtc: false).toLocal().toString().split('.').first}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (m.portalRole != null && m.portalRole!.trim().isNotEmpty) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                'Your role: ${m.portalRole}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (approved && MerchantPortalAccess.canViewInsights(m)) ...<Widget>[
              const SizedBox(height: 12),
              const _MerchantOperationsInsightsCard(),
            ],
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Storefront status',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 8),
                    Text('Account status: ${m.merchantStatus}'),
                    Text('Storefront mode: ${_availabilityLabel(m)}'),
                    Text('Open flag (server): ${m.isOpen ? 'Yes' : 'No'}'),
                    Text('Accepting orders: ${m.acceptingOrders ? 'Yes' : 'No'}'),
                    if (m.closedReason != null && m.closedReason!.trim().isNotEmpty)
                      Text('Note: ${m.closedReason}'),
                    if (m.businessType != null && m.businessType!.isNotEmpty)
                      Text('Business type: ${m.businessType}'),
                    Text('Category: ${m.category ?? '—'}'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            _DashboardAvailabilityQuickPanel(
              key: ValueKey<String>(
                '${m.merchantId}_${m.availabilityStatus}_${m.isOpen}_${m.acceptingOrders}_${m.closedReason ?? ''}',
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: <Widget>[
                if (MerchantPortalAccess.canChangeAvailability(m))
                  FilledButton.tonal(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const MerchantAvailabilityScreen(),
                      ),
                    ),
                    child: const Text('Availability details'),
                  ),
                if (MerchantPortalAccess.canEditStoreProfile(m))
                  FilledButton.tonal(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const StoreProfileScreen(),
                      ),
                    ),
                    child: const Text('Store profile'),
                  ),
                if (MerchantPortalAccess.canEditStoreProfile(m))
                  FilledButton.tonal(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const VerificationDocumentsScreen(),
                      ),
                    ),
                    child: const Text('Verification'),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _MerchantOperationsInsightsCard extends StatefulWidget {
  const _MerchantOperationsInsightsCard();

  @override
  State<_MerchantOperationsInsightsCard> createState() => _MerchantOperationsInsightsCardState();
}

class _MerchantOperationsInsightsCardState extends State<_MerchantOperationsInsightsCard> {
  Future<Map<String, dynamic>>? _future;

  void _reload(MerchantAppState state) {
    setState(() {
      _future = state.gateway.merchantGetOperationsInsights();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<MerchantAppState>();
    if (!state.isApproved) {
      return const SizedBox.shrink();
    }
    _future ??= state.gateway.merchantGetOperationsInsights();

    return FutureBuilder<Map<String, dynamic>>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Center(
                child: SizedBox(
                  height: 24,
                  width: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          );
        }
        if (snap.hasError) {
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    'Operations',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Text(nxUserFacingMessage(snap.error!)),
                  TextButton(
                    onPressed: () => _reload(context.read<MerchantAppState>()),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          );
        }
        final data = snap.data;
        if (data == null || data['success'] != true) {
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    'Operations',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  const Text('Could not load analytics right now.'),
                  TextButton(
                    onPressed: () => _reload(context.read<MerchantAppState>()),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          );
        }
        final topItems = (data['top_items'] as List?) ?? const <dynamic>[];
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        'Operations',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Refresh',
                      onPressed: () => _reload(state),
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text('Total orders (sample): ${data['total_orders'] ?? '—'}'),
                Text('Completed: ${data['completed_orders'] ?? '—'} · Cancelled: ${data['cancelled_orders'] ?? '—'}'),
                Text('Today revenue (₦): ${data['today_revenue_ngn'] ?? '—'}'),
                const SizedBox(height: 8),
                Text('Top-selling items', style: Theme.of(context).textTheme.titleSmall),
                ...topItems.take(8).map<Widget>((dynamic raw) {
                  if (raw is! Map) {
                    return Text('• $raw');
                  }
                  final row = Map<String, dynamic>.from(raw);
                  return Text('• ${row['name'] ?? row['item_id']}: ${row['units_sold']}');
                }),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _DashboardAvailabilityQuickPanel extends StatefulWidget {
  const _DashboardAvailabilityQuickPanel({super.key});

  @override
  State<_DashboardAvailabilityQuickPanel> createState() => _DashboardAvailabilityQuickPanelState();
}

class _DashboardAvailabilityQuickPanelState extends State<_DashboardAvailabilityQuickPanel> {
  late String _mode;
  final TextEditingController _reason = TextEditingController();
  bool _busy = false;

  static String _deriveMode(MerchantProfile? m) {
    if (m == null) return 'closed';
    final a = (m.availabilityStatus ?? '').toLowerCase();
    if (a == 'open' || a == 'closed' || a == 'paused') {
      return a;
    }
    if (m.isOpen && m.acceptingOrders) return 'open';
    if (m.isOpen && !m.acceptingOrders) return 'paused';
    return 'closed';
  }

  @override
  void initState() {
    super.initState();
    final m = context.read<MerchantAppState>().merchant;
    _mode = _deriveMode(m);
    _reason.text = m?.closedReason ?? '';
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<MerchantAppState>();
    final online = context.watch<MerchantConnectivity>().online;
    final approved = state.isApproved;
    final canAvail = MerchantPortalAccess.canChangeAvailability(state.merchant);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              'Quick storefront control',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              approved
                  ? 'Changes are saved to NexRide immediately and affect rider ordering.'
                  : 'After NexRide approves your store, you can open for riders from here.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: const <ButtonSegment<String>>[
                ButtonSegment<String>(value: 'open', label: Text('Open'), icon: Icon(Icons.storefront_outlined)),
                ButtonSegment<String>(value: 'paused', label: Text('Pause'), icon: Icon(Icons.pause_circle_outline)),
                ButtonSegment<String>(value: 'closed', label: Text('Closed'), icon: Icon(Icons.door_front_door_outlined)),
              ],
              selected: <String>{_mode},
              emptySelectionAllowed: false,
              onSelectionChanged: !approved || _busy || !online || !canAvail
                  ? null
                  : (Set<String> s) {
                      final v = s.first;
                      setState(() => _mode = v);
                    },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _reason,
              enabled: approved && !_busy && online && canAvail,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Optional note (e.g. why closed)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: !approved || _busy || !online || !canAvail
                  ? null
                  : () async {
                      setState(() => _busy = true);
                      try {
                        final res = await state.gateway.merchantUpdateAvailability(<String, dynamic>{
                          'availability_status': _mode,
                          if (_reason.text.trim().isNotEmpty) 'closed_reason': _reason.text.trim(),
                        });
                        if (!context.mounted) return;
                        if (res['success'] != true) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                nxMapFailureMessage(
                                  Map<String, dynamic>.from(res),
                                  'Availability could not be updated.',
                                ),
                              ),
                            ),
                          );
                          return;
                        }
                        await state.refreshMerchant();
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Storefront status saved')),
                          );
                        }
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(nxUserFacingMessage(e))),
                          );
                        }
                      } finally {
                        if (mounted) setState(() => _busy = false);
                      }
                    },
              child: _busy
                  ? const SizedBox(
                      height: 22,
                      width: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save storefront status'),
            ),
          ],
        ),
      ),
    );
  }
}

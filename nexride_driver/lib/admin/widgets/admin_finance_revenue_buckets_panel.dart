import 'package:flutter/material.dart';

import '../admin_config.dart';
import '../models/admin_models.dart';
import '../services/admin_data_service.dart';
import '../utils/admin_formatters.dart';
import 'admin_components.dart';

/// Production ledger buckets from `adminGetFinanceRevenueBuckets` (callable only).
class AdminFinanceRevenueBucketsPanel extends StatefulWidget {
  const AdminFinanceRevenueBucketsPanel({
    required this.dataService,
    required this.session,
    super.key,
  });

  final AdminDataService dataService;
  final AdminSession session;

  @override
  State<AdminFinanceRevenueBucketsPanel> createState() =>
      _AdminFinanceRevenueBucketsPanelState();
}

class _AdminFinanceRevenueBucketsPanelState
    extends State<AdminFinanceRevenueBucketsPanel> {
  bool _loading = false;
  String? _error;
  Map<String, dynamic> _buckets = <String, dynamic>{};
  bool _capped = false;
  int _scannedPlatform = 0;
  int _scannedDriverNet = 0;
  int _scannedPaymentTx = 0;

  @override
  void initState() {
    super.initState();
    if (widget.session.hasPermission('finance.read')) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final raw = await widget.dataService.adminGetFinanceRevenueBuckets();
      if (raw['success'] != true) {
        setState(() {
          _error = raw['reason']?.toString() ?? 'load_failed';
          _buckets = <String, dynamic>{};
        });
        return;
      }
      final b = raw['buckets'];
      setState(() {
        _buckets = b is Map ? Map<String, dynamic>.from(b) : <String, dynamic>{};
        _capped = raw['capped'] == true;
        _scannedPlatform = (raw['scanned_platform_rows'] is num)
            ? (raw['scanned_platform_rows'] as num).toInt()
            : 0;
        _scannedDriverNet = (raw['scanned_driver_net_rows'] is num)
            ? (raw['scanned_driver_net_rows'] as num).toInt()
            : 0;
        _scannedPaymentTx = (raw['scanned_payment_tx_rows'] is num)
            ? (raw['scanned_payment_tx_rows'] as num).toInt()
            : 0;
      });
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  double _amount(String key) {
    final v = _buckets[key];
    if (v is num) {
      return v.toDouble();
    }
    return double.tryParse(v?.toString() ?? '') ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.session.hasPermission('finance.read')) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                'Production revenue buckets',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
              ),
            ),
            FilledButton.icon(
              onPressed: _loading ? null : _load,
              icon: _loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh_rounded),
              label: const Text('Refresh buckets'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'From platform_ledger and driver_wallet_ledger (backend authoritative). '
          '₦30 booking fee is NexRide platform revenue — never driver trip earnings. '
          'Subscription drivers pay ₦0 commission on trips; subscription revenue is separate.',
          style: TextStyle(color: Colors.grey.shade800, height: 1.4, fontSize: 13),
        ),
        if (_error != null) ...<Widget>[
          const SizedBox(height: 12),
          MaterialBanner(
            backgroundColor: Colors.orange.shade50,
            content: Text(_error!),
            actions: <Widget>[
              TextButton(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        ],
        if (_capped) ...<Widget>[
          const SizedBox(height: 12),
          MaterialBanner(
            backgroundColor: Colors.amber.shade50,
            content: Text(
              'Scan capped (platform: $_scannedPlatform, driver net: $_scannedDriverNet, '
              'payment tx: $_scannedPaymentTx). Totals may be incomplete — narrow date range when available.',
            ),
            actions: const <Widget>[],
          ),
        ],
        const SizedBox(height: 16),
        if (_loading && _buckets.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final crossCount = constraints.maxWidth > 900 ? 3 : (constraints.maxWidth > 560 ? 2 : 1);
              return GridView.count(
                crossAxisCount: crossCount,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                childAspectRatio: crossCount == 1 ? 2.8 : 1.55,
                children: <Widget>[
                  _BucketCard(
                    title: 'Booking fees',
                    amount: formatAdminCurrency(_amount('booking_fee_revenue')),
                    caption: '₦30 per ride — platform only',
                    icon: Icons.receipt_long_outlined,
                  ),
                  _BucketCard(
                    title: 'Commission revenue',
                    amount: formatAdminCurrency(_amount('commission_revenue')),
                    caption: '10% of trip fare (commission drivers)',
                    icon: Icons.percent_rounded,
                  ),
                  _BucketCard(
                    title: 'Subscription revenue',
                    amount: formatAdminCurrency(_amount('subscription_revenue')),
                    caption: 'Driver plans — not trip wallet',
                    icon: Icons.workspace_premium_outlined,
                  ),
                  _BucketCard(
                    title: 'Driver net earnings',
                    amount: formatAdminCurrency(_amount('driver_net_earnings')),
                    caption: 'Credited to driver wallets (trip net)',
                    icon: Icons.account_balance_wallet_outlined,
                  ),
                  _BucketCard(
                    title: 'Payout liabilities',
                    amount: formatAdminCurrency(_amount('payout_liabilities')),
                    caption: 'Pending/processing withdrawal requests',
                    icon: Icons.payments_outlined,
                  ),
                  _BucketCard(
                    title: 'Refunds / voids',
                    amount: formatAdminCurrency(_amount('refunds_voids_ngn')),
                    caption: 'From payment_transactions status scan',
                    icon: Icons.undo_rounded,
                  ),
                ],
              );
            },
          ),
      ],
    );
  }
}

class _BucketCard extends StatelessWidget {
  const _BucketCard({
    required this.title,
    required this.amount,
    required this.caption,
    required this.icon,
  });

  final String title;
  final String amount;
  final String caption;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return AdminSurfaceCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, color: AdminThemeTokens.gold, size: 28),
          const SizedBox(height: 10),
          Text(
            title,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 14,
              color: AdminThemeTokens.ink,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            amount,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 22,
              color: AdminThemeTokens.ink,
            ),
          ),
          const Spacer(),
          Text(
            caption,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade700, height: 1.3),
          ),
        ],
      ),
    );
  }
}

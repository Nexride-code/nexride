import 'dart:async';

import 'package:firebase_database/firebase_database.dart' as rtdb;
import 'package:flutter/material.dart';

import '../config/driver_app_config.dart';
import '../support/driver_profile_support.dart';
import '../support/realtime_database_error_support.dart';
import 'driver_business_model_screen.dart';
import 'driver_subscription_payment_screen.dart';

/// Production subscription hub: shows current monetization, renewal state, and
/// links into the existing bank-transfer + proof payment flow and model switcher.
class DriverSubscriptionScreen extends StatefulWidget {
  const DriverSubscriptionScreen({super.key, required this.driverId});

  final String driverId;

  @override
  State<DriverSubscriptionScreen> createState() => _DriverSubscriptionScreenState();
}

class _DriverSubscriptionScreenState extends State<DriverSubscriptionScreen> {
  final rtdb.DatabaseReference _root = rtdb.FirebaseDatabase.instance.ref();

  bool _loading = true;
  String? _error;
  Map<String, dynamic> _businessModel = normalizedDriverBusinessModel(null);
  int _weeklyNgn = DriverBusinessConfig.weeklySubscriptionPriceNgn;
  int _monthlyNgn = DriverBusinessConfig.monthlySubscriptionPriceNgn;

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
      final profileSnap = await runOptionalRealtimeDatabaseRead<rtdb.DataSnapshot>(
        source: 'driver_subscription.load_profile',
        path: 'drivers/${widget.driverId}',
        action: () => _root.child('drivers/${widget.driverId}').get(),
      );
      final raw = profileSnap?.value is Map
          ? Map<String, dynamic>.from(profileSnap!.value as Map)
          : <String, dynamic>{};
      final bm = normalizedDriverBusinessModel(raw['businessModel']);
      final pricingSnap = await runOptionalRealtimeDatabaseRead<rtdb.DataSnapshot>(
        source: 'driver_subscription.load_pricing',
        path: 'app_config/pricing',
        action: () => _root.child('app_config/pricing').get(),
      );
      final p = pricingSnap?.value is Map
          ? Map<String, dynamic>.from(pricingSnap!.value as Map)
          : <String, dynamic>{};
      final w = _firstInt(p['weeklySubscriptionNgn'], p['weekly_subscription_ngn']);
      final m = _firstInt(p['monthlySubscriptionNgn'], p['monthly_subscription_ngn']);
      if (!mounted) return;
      setState(() {
        _businessModel = bm;
        if (w != null && w > 0) _weeklyNgn = w;
        if (m != null && m > 0) _monthlyNgn = m;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  int? _firstInt(dynamic a, dynamic b) {
    for (final v in <dynamic>[a, b]) {
      if (v is num && v.toInt() > 0) return v.toInt();
      final p = int.tryParse('$v'.trim());
      if (p != null && p > 0) return p;
    }
    return null;
  }

  Map<String, dynamic> _subscriptionMap() =>
      Map<String, dynamic>.from(_businessModel['subscription'] as Map? ?? const {});

  String _text(dynamic v) => v?.toString().trim() ?? '';

  Future<void> _openBusinessModel() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => DriverBusinessModelScreen(driverId: widget.driverId),
      ),
    );
    await _load();
  }

  Future<void> _openPayment(String planType, int amountNgn) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => DriverSubscriptionPaymentScreen(
          driverId: widget.driverId,
          planType: planType,
          amountNgn: amountNgn,
        ),
      ),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final sub = _subscriptionMap();
    final model = _text(_businessModel['selectedModel']).toLowerCase();
    final planType = _text(sub['planType']).toLowerCase();
    final subStatus = _text(sub['status']);
    final active = driverSubscriptionIsActive(_businessModel);
    final canGoOnline = driverCanGoOnlineFromBusinessModel(_businessModel);
    final validUntilMs = sub['validUntil'] ?? sub['valid_until'] ?? sub['expiresAt'];
    final validUntil = validUntilMs is num
        ? DateTime.fromMillisecondsSinceEpoch(validUntilMs.toInt())
        : null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Subscription & earnings'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 16),
                        FilledButton(onPressed: _load, child: const Text('Retry')),
                      ],
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(20),
                    children: <Widget>[
                      Text(
                        'You are on the ${model == 'subscription' ? 'subscription' : 'commission'} earnings model.',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        model == 'subscription'
                            ? 'Subscription drivers ride commission-free while their plan is active. '
                                'Use the official bank transfer + proof flow to activate or renew.'
                            : 'Commission drivers pay platform commission on completed trips. '
                                'No subscription payment is required to go online.',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 20),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Plan status'),
                        subtitle: Text(
                          active
                              ? 'Active · ${_text(sub['planType'])} · renew before expiry'
                              : 'Not active · $subStatus',
                        ),
                      ),
                      if (validUntil != null)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Current period ends'),
                          subtitle: Text(validUntil.toLocal().toString()),
                        ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Go online eligibility'),
                        subtitle: Text(
                          canGoOnline
                              ? 'You meet current subscription / commission rules.'
                              : 'Complete subscription payment (if on subscription) or resolve outstanding items.',
                        ),
                      ),
                      const Divider(height: 32),
                      const Text(
                        'Actions',
                        style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.tonal(
                        onPressed: _openBusinessModel,
                        child: const Text('Switch commission / subscription model'),
                      ),
                      if (model == 'subscription') ...<Widget>[
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: () => _openPayment('weekly', _weeklyNgn),
                          child: Text('Pay weekly plan (₦${_weeklyNgn.toString()})'),
                        ),
                        const SizedBox(height: 8),
                        FilledButton(
                          onPressed: () => _openPayment('monthly', _monthlyNgn),
                          child: Text('Pay monthly plan (₦${_monthlyNgn.toString()})'),
                        ),
                      ],
                      const SizedBox(height: 24),
                      Text(
                        'Transaction history: your subscription payments are recorded on your driver '
                        'profile (payment reference and proof). Admins reconcile in the NexRide console.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (planType.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 8),
                        Text('Selected billing cadence: $planType',
                            style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ],
                  ),
                ),
    );
  }
}

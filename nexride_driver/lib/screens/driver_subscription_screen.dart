import 'dart:async';

import 'package:firebase_database/firebase_database.dart' as rtdb;
import 'package:flutter/material.dart';

import '../config/driver_app_config.dart';
import '../services/ride_cloud_functions_service.dart';
import '../support/driver_profile_support.dart';
import '../support/friendly_firebase_errors.dart';
import '../support/realtime_database_error_support.dart';
import 'driver_business_model_screen.dart';
import 'driver_redeem_fleet_invite_screen.dart';
import 'driver_subscription_payment_screen.dart';
import 'driver_wallet_topup_screen.dart';

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
  final RideCloudFunctionsService _cloud = RideCloudFunctionsService();

  bool _loading = true;
  bool _walletPaying = false;
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
      var weeklyDisplay = DriverBusinessConfig.weeklySubscriptionPriceNgn;
      var monthlyDisplay = DriverBusinessConfig.monthlySubscriptionPriceNgn;
      Map<String, dynamic>? serverPricing;
      try {
        serverPricing = await _cloud.getDriverSubscriptionPricing(driverId: widget.driverId);
        if (serverPricing['success'] == true) {
          final ww = serverPricing['weekly_subscription_ngn'];
          final mm = serverPricing['monthly_subscription_ngn'];
          if (ww is num && ww.toInt() > 0) {
            weeklyDisplay = ww.toInt();
          }
          if (mm is num && mm.toInt() > 0) {
            monthlyDisplay = mm.toInt();
          }
        }
      } catch (_) {
        /* callable optional — fall through to RTDB / defaults */
      }

      final profileSnap = await runOptionalRealtimeDatabaseRead<rtdb.DataSnapshot>(
        source: 'driver_subscription.load_profile',
        path: 'drivers/${widget.driverId}',
        action: () => _root.child('drivers/${widget.driverId}').get(),
      );
      final raw = profileSnap?.value is Map
          ? Map<String, dynamic>.from(profileSnap!.value as Map)
          : <String, dynamic>{};
      final bm = normalizedDriverBusinessModel(raw['businessModel']);

      if (serverPricing?['success'] != true) {
        try {
          final appPricing = await _cloud.getAppPricingConfig();
          if (appPricing['success'] == true) {
            final p = appPricing['pricing'] is Map
                ? Map<String, dynamic>.from(appPricing['pricing'] as Map)
                : <String, dynamic>{};
            final w = _firstInt(p['weeklySubscriptionNgn'], p['weekly_subscription_ngn']);
            final m = _firstInt(p['monthlySubscriptionNgn'], p['monthly_subscription_ngn']);
            if (w != null && w > 0) {
              weeklyDisplay = w;
            }
            if (m != null && m > 0) {
              monthlyDisplay = m;
            }
          }
        } catch (_) {
          /* use embedded defaults */
        }
      }

      if (!mounted) {
        return;
      }
      setState(() {
        _businessModel = bm;
        _weeklyNgn = weeklyDisplay;
        _monthlyNgn = monthlyDisplay;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
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

  Future<void> _openRedeemFleetInvite() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => DriverRedeemFleetInviteScreen(
          driverId: widget.driverId,
        ),
      ),
    );
  }

  Future<double> _fetchWalletBalanceNgn() async {
    try {
      final walletSnap = await runOptionalRealtimeDatabaseRead<rtdb.DataSnapshot>(
        source: 'driver_subscription.wallet_balance',
        path: 'wallets/${widget.driverId}',
        action: () => _root.child('wallets/${widget.driverId}').get(),
      );
      final raw = walletSnap?.value;
      if (raw is Map) {
        final m = Map<String, dynamic>.from(raw);
        final balRaw = m['balance'] ?? m['currentBalance'];
        if (balRaw is num) {
          return balRaw.toDouble();
        }
        return double.tryParse(balRaw?.toString().trim() ?? '') ?? 0;
      }
    } catch (_) {
      /* optional read */
    }
    return 0;
  }

  Future<void> _pushFlutterwaveSubscriptionPayment(String planType, int amountNgn) async {
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

  Future<void> _showInsufficientWalletActions(String planType, int amountNgn) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) {
        return AlertDialog(
          title: const Text('Insufficient wallet balance'),
          content: Text(
            'This plan costs ${formatDriverNairaAmount(amountNgn)}. '
            'Top up your driver wallet, or pay directly with Flutterwave (card or virtual account).',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Not now'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                unawaited(
                  Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => DriverWalletTopUpScreen(driverId: widget.driverId),
                    ),
                  ),
                );
              },
              child: const Text('Top up wallet'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                unawaited(_pushFlutterwaveSubscriptionPayment(planType, amountNgn));
              },
              child: const Text('Pay with Flutterwave'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _paySubscriptionFromWallet(String planType, int amountNgn, double balanceSnapshot) async {
    if (balanceSnapshot + 0.5 < amountNgn) {
      await _showInsufficientWalletActions(planType, amountNgn);
      return;
    }
    setState(() {
      _walletPaying = true;
    });
    try {
      final res = await _cloud.driverPaySubscriptionFromWallet(
        driverId: widget.driverId,
        planType: planType,
      );
      if (!mounted) {
        return;
      }
      if (res['success'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Subscription paid from your wallet.')),
        );
        await _load();
        return;
      }
      final reason = (res['reason'] ?? '').toString().trim();
      if (reason == 'insufficient_balance') {
        await _showInsufficientWalletActions(planType, amountNgn);
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            reason.isEmpty
                ? 'Could not pay from wallet.'
                : 'Could not pay from wallet: $reason',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            friendlyFirebaseError(e, debugLabel: 'subscription.wallet_pay'),
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _walletPaying = false;
        });
      }
    }
  }

  Future<void> _openSubscriptionPaySheet(String planType, int amountNgn) async {
    final balance = await _fetchWalletBalanceNgn();
    if (!mounted) {
      return;
    }
    final planTitle = planType == 'weekly' ? 'Weekly' : 'Monthly';
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext sheetCtx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  '$planTitle plan · ${formatDriverNairaAmount(amountNgn)}',
                  style: Theme.of(sheetCtx).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Wallet balance: ${formatDriverNairaAmount(balance.round())}',
                  style: Theme.of(sheetCtx).textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.account_balance_wallet_outlined),
                  title: const Text('Pay from wallet balance'),
                  subtitle: Text(
                    balance >= amountNgn - 0.01
                        ? 'Debit is processed securely on our servers.'
                        : 'Balance is too low for this plan.',
                  ),
                  enabled: !_walletPaying,
                  onTap: () async {
                    Navigator.of(sheetCtx).pop();
                    await _paySubscriptionFromWallet(planType, amountNgn, balance);
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.credit_card),
                  title: const Text('Pay with Flutterwave card'),
                  onTap: () async {
                    Navigator.of(sheetCtx).pop();
                    await _pushFlutterwaveSubscriptionPayment(planType, amountNgn);
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.account_balance),
                  title: const Text('Pay with Flutterwave bank transfer / virtual account'),
                  onTap: () async {
                    Navigator.of(sheetCtx).pop();
                    await _pushFlutterwaveSubscriptionPayment(planType, amountNgn);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
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
                                'Pay securely with Flutterwave (card or bank transfer to a virtual account); '
                                'no proof upload — your plan activates automatically when payment is confirmed.'
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
                      const SizedBox(height: 12),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.link),
                        title: const Text('Redeem Fleet Invite'),
                        subtitle: const Text(
                          'Link to a Dispatch Fleet business with an invite code. '
                          'Also in Driver Hub or Business model.',
                        ),
                        onTap: _openRedeemFleetInvite,
                      ),
                      if (model == 'subscription') ...<Widget>[
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: _walletPaying || _loading
                              ? null
                              : () => _openSubscriptionPaySheet('weekly', _weeklyNgn),
                          child: Text('Pay weekly plan (₦${_weeklyNgn.toString()})'),
                        ),
                        const SizedBox(height: 8),
                        FilledButton(
                          onPressed: _walletPaying || _loading
                              ? null
                              : () => _openSubscriptionPaySheet('monthly', _monthlyNgn),
                          child: Text('Pay monthly plan (₦${_monthlyNgn.toString()})'),
                        ),
                      ],
                      const SizedBox(height: 24),
                      Text(
                        'Payments: choose wallet, Flutterwave card, or bank transfer to a virtual account. '
                        'Wallet top-up is available from the Wallet screen. Admins can review payment intents in the console.',
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

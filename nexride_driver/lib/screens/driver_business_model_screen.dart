import 'dart:async';

import 'package:firebase_database/firebase_database.dart' as rtdb;
import 'package:flutter/material.dart';

import '../config/driver_app_config.dart';
import 'driver_subscription_payment_screen.dart';
import '../support/driver_profile_support.dart';
import '../support/realtime_database_error_support.dart';

class DriverBusinessModelScreen extends StatefulWidget {
  const DriverBusinessModelScreen({
    super.key,
    required this.driverId,
  });

  final String driverId;

  @override
  State<DriverBusinessModelScreen> createState() =>
      _DriverBusinessModelScreenState();
}

class _DriverBusinessModelScreenState extends State<DriverBusinessModelScreen> {
  final rtdb.DatabaseReference _rootRef = rtdb.FirebaseDatabase.instance.ref();

  Map<String, dynamic> _driverProfile = <String, dynamic>{};
  Map<String, dynamic> _businessModel = normalizedDriverBusinessModel(null);
  bool _loading = true;
  bool _saving = false;

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    final profilePath = 'drivers/${widget.driverId}';
    debugPrint(
      '[DriverBusinessModel] load profile driverId=${widget.driverId}',
    );
    try {
      final snapshot = await runOptionalRealtimeDatabaseRead<rtdb.DataSnapshot>(
        source: 'driver_business_model.load_profile',
        path: profilePath,
        action: () => _rootRef.child(profilePath).get(),
      );
      final rawProfile = snapshot?.value is Map
          ? Map<String, dynamic>.from(snapshot!.value as Map)
          : <String, dynamic>{};
      final normalizedProfile = buildDriverProfileRecord(
        driverId: widget.driverId,
        existing: rawProfile,
      );

      try {
        await _rootRef.child(profilePath).update(<String, dynamic>{
          'businessModel': normalizedProfile['businessModel'],
          'verification': normalizedProfile['verification'],
          'updated_at': rtdb.ServerValue.timestamp,
        });
      } catch (error, stackTrace) {
        debugPrint(
          '[DriverBusinessModel] bootstrap repair skipped path=$profilePath error=$error',
        );
        debugPrintStack(
          label: '[DriverBusinessModel] bootstrap repair stack',
          stackTrace: stackTrace,
        );
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _driverProfile = normalizedProfile;
        _businessModel = normalizedDriverBusinessModel(
          normalizedProfile['businessModel'],
        );
        _loading = false;
      });
    } catch (error, stackTrace) {
      debugPrint('[DriverBusinessModel] load failed: $error');
      debugPrintStack(
        label: '[DriverBusinessModel] load stack',
        stackTrace: stackTrace,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _driverProfile = buildDriverProfileRecord(
          driverId: widget.driverId,
          existing: const <String, dynamic>{},
        );
        _businessModel = normalizedDriverBusinessModel(null);
        _loading = false;
      });
      _showMessage(
        'We opened your business model settings with safe defaults. Pull to refresh in a moment.',
      );
    }
  }

  Future<void> _selectModel(String selectedModel) async {
    if (_saving) {
      return;
    }

    setState(() {
      _saving = true;
    });

    final nextModel = normalizedDriverBusinessModel(_businessModel);
    nextModel['selectedModel'] = selectedModel;

    if (selectedModel == 'subscription') {
      final subscription = Map<String, dynamic>.from(
        nextModel['subscription'] as Map<String, dynamic>,
      );
      if ((subscription['status']?.toString().trim().isEmpty ?? true)) {
        subscription['status'] = 'setup_required';
      }
      subscription['updatedAt'] = rtdb.ServerValue.timestamp;
      nextModel['subscription'] = subscription;
    } else {
      final commission = Map<String, dynamic>.from(
        nextModel['commission'] as Map<String, dynamic>,
      );
      if ((commission['status']?.toString().trim().isEmpty ?? true)) {
        commission['status'] = 'eligible';
      }
      commission['updatedAt'] = rtdb.ServerValue.timestamp;
      nextModel['commission'] = commission;
    }

    nextModel['canGoOnline'] = driverCanGoOnlineFromBusinessModel(nextModel);
    nextModel['eligibilityStatus'] = driverBusinessEligibilityStatus(nextModel);
    nextModel['updatedAt'] = rtdb.ServerValue.timestamp;

    try {
      await _rootRef.update(<String, dynamic>{
        'drivers/${widget.driverId}/businessModel': nextModel,
        'drivers/${widget.driverId}/updated_at': rtdb.ServerValue.timestamp,
      });

      debugPrint(
        '[DriverBusinessModel] selection saved model=$selectedModel canGoOnline=${nextModel['canGoOnline']}',
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _businessModel = normalizedDriverBusinessModel(nextModel);
        _driverProfile = <String, dynamic>{
          ..._driverProfile,
          'businessModel': normalizedDriverBusinessModel(nextModel),
        };
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            selectedModel == 'subscription'
                ? 'Subscription selected. A valid weekly or monthly plan must be active before commission-free earnings apply.'
                : 'Commission model selected successfully.',
          ),
        ),
      );
    } catch (error, stackTrace) {
      debugPrint('[DriverBusinessModel] save failed: $error');
      debugPrintStack(
        label: '[DriverBusinessModel] save stack',
        stackTrace: stackTrace,
      );
      if (!mounted) {
        return;
      }
      _showMessage(
        'Unable to update your business model right now. Please try again.',
      );
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  Future<void> _startSubscriptionFlow() async {
    final subscription = Map<String, dynamic>.from(
      _businessModel['subscription'] as Map<String, dynamic>,
    );
    final weeklyPrice = subscription['weeklyPriceNgn'] is num
        ? (subscription['weeklyPriceNgn'] as num).toInt()
        : DriverBusinessConfig.weeklySubscriptionPriceNgn;
    final monthlyPrice = subscription['monthlyPriceNgn'] is num
        ? (subscription['monthlyPriceNgn'] as num).toInt()
        : DriverBusinessConfig.monthlySubscriptionPriceNgn;
    final selectedPlan = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(height: 10),
            const Text(
              'Choose subscription plan',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
            ),
            ListTile(
              title: Text('Weekly • ${formatDriverNairaAmount(weeklyPrice)}'),
              subtitle: const Text('Valid for 7 days'),
              onTap: () => Navigator.of(ctx).pop('weekly'),
            ),
            ListTile(
              title: Text('Monthly • ${formatDriverNairaAmount(monthlyPrice)}'),
              subtitle: const Text('Valid for 30 days'),
              onTap: () => Navigator.of(ctx).pop('monthly'),
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
    if (!mounted || selectedPlan == null) {
      return;
    }
    final amount = selectedPlan == 'weekly' ? weeklyPrice : monthlyPrice;
    final submitted = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => DriverSubscriptionPaymentScreen(
          driverId: widget.driverId,
          planType: selectedPlan,
          amountNgn: amount,
        ),
      ),
    );
    if (submitted == true) {
      await _loadProfile();
    }
  }

  Widget _buildModelCard({
    required String keyValue,
    required String title,
    required String subtitle,
    required List<String> highlights,
    required String statusLabel,
    required bool selected,
    required bool canGoOnline,
  }) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(
          color: selected ? kDriverGold : Colors.black.withValues(alpha: 0.06),
          width: selected ? 1.4 : 1,
        ),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 18,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: Colors.black87,
                  ),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: selected
                      ? kDriverGold.withValues(alpha: 0.18)
                      : Colors.black.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  selected ? 'Selected' : statusLabel,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: selected ? const Color(0xFF8A6424) : Colors.black54,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: 14,
              color: Colors.black.withValues(alpha: 0.68),
              height: 1.5,
            ),
          ),
          const SizedBox(height: 16),
          ...highlights.map(
            (highlight) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(
                    Icons.check_circle_outline,
                    size: 18,
                    color: canGoOnline ? const Color(0xFF198754) : kDriverGold,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      highlight,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        height: 1.45,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: selected ? Colors.black87 : kDriverGold,
                foregroundColor: selected ? Colors.white : Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 15),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
              ),
              onPressed: _saving
                  ? null
                  : () {
                      if (keyValue == 'subscription') {
                        unawaited(_startSubscriptionFlow());
                        return;
                      }
                      unawaited(_selectModel(keyValue));
                    },
              child: Text(
                keyValue == 'subscription'
                    ? 'Select plan and pay'
                    : selected
                        ? 'Currently selected'
                        : 'Choose this option',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selectedModel =
        _businessModel['selectedModel']?.toString() ?? 'commission';
    final selectedModelLabel = driverSelectedMonetizationModeLabel(
      _businessModel,
    );
    final commission = Map<String, dynamic>.from(
      _businessModel['commission'] as Map<String, dynamic>,
    );
    final subscription = Map<String, dynamic>.from(
      _businessModel['subscription'] as Map<String, dynamic>,
    );
    final weeklyPlanPrice = subscription['weeklyPriceNgn'] is num
        ? subscription['weeklyPriceNgn'] as num
        : 0;
    final monthlyPlanPrice = subscription['monthlyPriceNgn'] is num
        ? subscription['monthlyPriceNgn'] as num
        : 0;
    final commissionRateLabel = formatDriverCommissionRatePercent(
      commission['ratePercent'],
    );

    return Scaffold(
      backgroundColor: kDriverCream,
      appBar: AppBar(
        backgroundColor: kDriverGold,
        foregroundColor: Colors.black,
        centerTitle: true,
        title: const Text('Business Model'),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(20),
                children: <Widget>[
                  Container(
                    padding: const EdgeInsets.all(22),
                    decoration: BoxDecoration(
                      color: kDriverDark,
                      borderRadius: BorderRadius.circular(28),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          'Current model: $selectedModelLabel',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          driverBusinessEligibilityMessage(_businessModel),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 14,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  _buildModelCard(
                    keyValue: 'commission',
                    title: 'Commission model',
                    subtitle:
                        'Drive now and pay a clear $commissionRateLabel% commission on each completed trip.',
                    highlights: <String>[
                      '$commissionRateLabel% commission is charged on every completed ride and delivery trip.',
                      'Wallet credits and statements show your payout after the $commissionRateLabel% deduction.',
                      'No subscription payment is required before you start driving.',
                    ],
                    statusLabel: formatDriverBusinessStatusLabel(
                      commission['status']?.toString() ?? 'eligible',
                    ),
                    selected: selectedModel == 'commission',
                    canGoOnline: driverCanGoOnlineFromBusinessModel(
                      <String, dynamic>{
                        ..._businessModel,
                        'selectedModel': 'commission',
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                  _buildModelCard(
                    keyValue: 'subscription',
                    title: 'Subscription model',
                    subtitle:
                        'Choose a weekly or monthly plan and keep 100% of trip earnings while your subscription remains valid.',
                    highlights: <String>[
                      'Weekly plan: ${formatDriverNairaAmount(weeklyPlanPrice)}.',
                      'Monthly plan: ${formatDriverNairaAmount(monthlyPlanPrice)}.',
                      'Active subscribers keep 100% of trip earnings with no per-trip commission.',
                      'If your subscription is inactive, invalid, or expired, the standard $commissionRateLabel% commission rule applies.',
                    ],
                    statusLabel: formatDriverBusinessStatusLabel(
                      subscription['status']?.toString() ?? 'setup_required',
                    ),
                    selected: selectedModel == 'subscription',
                    canGoOnline: driverCanGoOnlineFromBusinessModel(
                      <String, dynamic>{
                        ..._businessModel,
                        'selectedModel': 'subscription',
                      },
                    ),
                  ),
                  const SizedBox(height: 18),
                  Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Text(
                      'Your selected business model and subscription status are saved in your driver profile. Commission-free payouts apply only while a valid weekly or monthly subscription is active.',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.black.withValues(alpha: 0.68),
                        height: 1.5,
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

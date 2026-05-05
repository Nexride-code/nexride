import 'dart:async';

import 'package:flutter/material.dart';

import 'config/rider_app_config.dart';
import 'map_screen.dart';
import 'payment_method_entry_screen.dart';
import 'services/rider_active_trip_session_service.dart';
import 'services/payment_methods_service.dart';
import 'support/payment_method_support.dart';

class PaymentMethodsScreen extends StatefulWidget {
  const PaymentMethodsScreen({super.key, required this.riderId});

  final String riderId;

  @override
  State<PaymentMethodsScreen> createState() => _PaymentMethodsScreenState();
}

class _PaymentMethodsScreenState extends State<PaymentMethodsScreen> {
  static const Color _gold = Color(0xFFB57A2A);
  static const Color _cream = Color(0xFFF7F2EA);

  final PaymentMethodsService _service = const PaymentMethodsService();
  final RiderActiveTripSessionService _activeTripSessionService =
      RiderActiveTripSessionService.instance;
  List<PaymentMethodRecord> _methods = <PaymentMethodRecord>[];
  bool _loading = true;
  String? _busyMethodId;

  PaymentMethodRecord? get _defaultMethod {
    for (final method in _methods) {
      if (method.isDefault) {
        return method;
      }
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadMethods());
    unawaited(
      _activeTripSessionService.restoreActiveTripForCurrentUser(
        source: 'payment_methods.init',
      ),
    );
  }

  Future<void> _loadMethods() async {
    try {
      final methods = await _service.fetchPaymentMethods(widget.riderId);
      if (!mounted) {
        return;
      }
      setState(() {
        _methods = methods;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not load payment methods: $error')),
      );
    }
  }

  Future<void> _openLinkFlow(PaymentMethodType type) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) =>
            PaymentMethodEntryScreen(riderId: widget.riderId, type: type),
      ),
    );

    if (saved == true) {
      await _loadMethods();
    }
  }

  Future<void> _setDefault(PaymentMethodRecord method) async {
    setState(() {
      _busyMethodId = method.id;
    });

    try {
      await _service.setDefaultPaymentMethod(
        riderId: widget.riderId,
        methodId: method.id,
      );
      await _loadMethods();
    } finally {
      if (mounted) {
        setState(() {
          _busyMethodId = null;
        });
      }
    }
  }

  Future<void> _delete(PaymentMethodRecord method) async {
    setState(() {
      _busyMethodId = method.id;
    });
    try {
      await _service.deletePaymentMethod(
        riderId: widget.riderId,
        methodId: method.id,
      );
      await _loadMethods();
    } finally {
      if (mounted) {
        setState(() {
          _busyMethodId = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _cream,
      appBar: AppBar(
        backgroundColor: _gold,
        foregroundColor: Colors.black,
        title: const Text('Payment Methods'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: RefreshIndicator(
          color: _gold,
          onRefresh: _loadMethods,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
            children: <Widget>[
              ValueListenableBuilder<RiderActiveTripSession?>(
                valueListenable: _activeTripSessionService.sessionNotifier,
                builder: (
                  BuildContext context,
                  RiderActiveTripSession? session,
                  Widget? _,
                ) {
                  if (session == null || !_activeTripSessionService.hasActiveTrip) {
                    return const SizedBox.shrink();
                  }
                  debugPrint(
                    '[RIDER_ACTIVE_TRIP_BANNER] source=payment_methods status=${session.status} rideId=${session.rideId}',
                  );
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _PaymentTripBanner(
                      status: session.status,
                      onTap: () {
                        debugPrint(
                          '[RIDER_NAV_RETURN_TO_TRIP] source=payment_methods rideId=${session.rideId}',
                        );
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const MapScreen(),
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: const <BoxShadow>[
                    BoxShadow(
                      color: Color(0x14000000),
                      blurRadius: 20,
                      offset: Offset(0, 12),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Text(
                      'Online Payment',
                      style: TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w900,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _defaultMethod == null
                          ? 'Link a card or bank account to prepare your online payment flow.'
                          : 'Default method: ${_defaultMethod!.displayTitle} • ${_defaultMethod!.maskedDetails}',
                      style: TextStyle(
                        color: Colors.black.withValues(alpha: 0.68),
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: _cream,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Row(
                        children: <Widget>[
                          Icon(Icons.online_prediction_outlined, color: _gold),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              RiderFeatureFlags.enableOnlinePaymentMethods
                                  ? 'Saved records are PSP-ready, but live charges are still disabled.'
                                  : 'Online payment setup is hidden right now.',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.black87,
                    side: BorderSide(color: _gold),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                  onPressed: () =>
                      unawaited(_openLinkFlow(PaymentMethodType.card)),
                  icon: const Icon(Icons.credit_card_rounded),
                  label: const Text('Link Card'),
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                'Saved payment methods',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 12),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.only(top: 24),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_methods.isEmpty)
                Container(
                  padding: const EdgeInsets.all(22),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Column(
                    children: <Widget>[
                      Icon(Icons.wallet_outlined, color: _gold, size: 36),
                      const SizedBox(height: 10),
                      const Text(
                        'No payment methods linked yet',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                          color: Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Link a card to prepare Flutterwave checkout for trips.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.black.withValues(alpha: 0.66),
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                )
              else
                ..._methods.map(
                  (method) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Container(
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(22),
                        boxShadow: const <BoxShadow>[
                          BoxShadow(
                            color: Color(0x12000000),
                            blurRadius: 16,
                            offset: Offset(0, 10),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              Container(
                                width: 46,
                                height: 46,
                                decoration: BoxDecoration(
                                  color: _gold.withValues(alpha: 0.14),
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Icon(
                                  method.type == PaymentMethodType.card
                                      ? Icons.credit_card_rounded
                                      : Icons.account_balance_outlined,
                                  color: _gold,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Text(
                                      method.displayTitle,
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w900,
                                        color: Colors.black87,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      method.detailLabel,
                                      style: TextStyle(
                                        color: Colors.black.withValues(
                                          alpha: 0.62,
                                        ),
                                        height: 1.45,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: <Widget>[
                              _MethodChip(
                                label: method.isDefault ? 'Default' : 'Saved',
                                color: method.isDefault
                                    ? const Color(0xFF198754)
                                    : _gold,
                              ),
                              _MethodChip(
                                label: method.status,
                                color: const Color(0xFF1E3A5F),
                              ),
                              _MethodChip(
                                label: method.provider.replaceAll('_', ' '),
                                color: const Color(0xFF5A4A2A),
                              ),
                            ],
                          ),
                          if (!method.isDefault) ...<Widget>[
                            const SizedBox(height: 14),
                            Row(
                              children: <Widget>[
                                TextButton(
                                  onPressed: _busyMethodId == method.id
                                      ? null
                                      : () => unawaited(_setDefault(method)),
                                  child: Text(
                                    _busyMethodId == method.id
                                        ? 'Updating...'
                                        : 'Set as default',
                                  ),
                                ),
                                TextButton(
                                  onPressed: _busyMethodId == method.id
                                      ? null
                                      : () => unawaited(_delete(method)),
                                  child: const Text('Delete'),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PaymentTripBanner extends StatelessWidget {
  const _PaymentTripBanner({required this.status, required this.onTap});

  final String status;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: const Color(0xFFB57A2A)),
          ),
          child: Row(
            children: <Widget>[
              const Icon(Icons.alt_route_rounded, color: Color(0xFFB57A2A)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Trip active • ${status.replaceAll('_', ' ')}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: Colors.white70),
            ],
          ),
        ),
      ),
    );
  }
}

class _MethodChip extends StatelessWidget {
  const _MethodChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontWeight: FontWeight.w800),
      ),
    );
  }
}

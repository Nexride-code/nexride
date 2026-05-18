import 'dart:async';
import 'dart:developer' as developer;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart' as rtdb;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/ride_cloud_functions_service.dart';
import '../support/driver_profile_support.dart';
import '../support/friendly_firebase_errors.dart';

/// Flutterwave card + dynamic VA. Driver can leave anytime; settlement is server-driven (webhook).
class DriverSubscriptionPaymentScreen extends StatefulWidget {
  const DriverSubscriptionPaymentScreen({
    super.key,
    required this.driverId,
    required this.planType,
    required this.amountNgn,
  });

  final String driverId;
  final String planType;
  final int amountNgn;

  @override
  State<DriverSubscriptionPaymentScreen> createState() =>
      _DriverSubscriptionPaymentScreenState();
}

class _DriverSubscriptionPaymentScreenState
    extends State<DriverSubscriptionPaymentScreen> {
  final RideCloudFunctionsService _cloud = RideCloudFunctionsService();
  static const String _payLogName = 'NexRidePaymentDriverSub';

  void _payLog(String message, {Object? error}) {
    developer.log(message, name: _payLogName, error: error);
  }

  bool _cardLoading = false;
  bool _vaLoading = false;
  String? _error;
  Map<String, dynamic>? _vaBank;
  int? _vaExpiresMs;
  String? _activeTxRef;

  StreamSubscription<rtdb.DatabaseEvent>? _subListen;
  bool _subInitialEvent = true;
  String? _lastSubscriptionStatus;
  bool _celebratedActivation = false;

  @override
  void initState() {
    super.initState();
    _subListen = rtdb.FirebaseDatabase.instance
        .ref('drivers/${widget.driverId}/businessModel/subscription')
        .onValue
        .listen((rtdb.DatabaseEvent ev) {
      if (!mounted) {
        return;
      }
      final raw = ev.snapshot.value;
      if (raw is! Map) {
        return;
      }
      final m = Map<String, dynamic>.from(raw);
      final st = (m['status'] ?? '').toString().trim().toLowerCase();
      if (_subInitialEvent) {
        _subInitialEvent = false;
        _lastSubscriptionStatus = st;
        return;
      }
      final prev = (_lastSubscriptionStatus ?? '').trim().toLowerCase();
      _lastSubscriptionStatus = st;
      if (_celebratedActivation) {
        return;
      }
      if (st == 'active' && prev != 'active') {
        _celebratedActivation = true;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Subscription payment confirmed.')),
        );
        Navigator.of(context).pop(true);
      }
    });
  }

  @override
  void dispose() {
    unawaited(_subListen?.cancel() ?? Future<void>.value());
    super.dispose();
  }

  void _debugLogCallable(String tag, Map<String, dynamic> res) {
    if (kDebugMode) {
      debugPrint('[$tag] driver_subscription_payment res=$res');
    }
  }

  String _subscriptionPaymentUserMessage(
    Map<String, dynamic> res, {
    required String fallback,
  }) {
    final m =
        res['message']?.toString().trim() ?? res['user_message']?.toString().trim() ?? '';
    if (m.isNotEmpty) {
      return m;
    }
    final code =
        (res['reason_code'] ?? res['reason'] ?? '').toString().trim().toLowerCase();
    switch (code) {
      case 'flutterwave_secret_not_in_runtime':
      case 'flutterwave_secret_missing':
        return 'Payment provider is temporarily unavailable. Try again later or use another method.';
      case 'flutterwave_network_error':
        return 'Could not reach the payment provider. Check your connection and try again.';
      case 'flutterwave_http_error':
      case 'flutterwave_card_init_failed':
      case 'flutterwave_checkout_link_missing':
        return 'Card checkout could not be started. Please try again.';
      case 'payment_init_failed':
        return 'Card checkout could not be started. Please try again.';
      case 'unauthorized':
      case 'forbidden':
        return 'You do not have permission to start this payment. Please sign in again.';
      case 'invalid_plan':
      case 'invalid_amount':
        return 'That subscription option is not available right now. Please go back and pick again.';
      case 'payment_provider_unavailable':
      case 'flutterwave_va_failed':
        return 'Bank transfer could not be set up. Try again or use card payment.';
      default:
        return fallback;
    }
  }

  Map<String, dynamic> _pendingMap(Map<String, dynamic> sub) {
    final pay = (sub['paymentStatus'] ?? sub['payment_status'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    if (pay != 'pending_gateway') {
      return const <String, dynamic>{};
    }
    return sub;
  }

  Future<void> _startCard() async {
    setState(() {
      _cardLoading = true;
      _error = null;
    });
    try {
      final res = await _cloud.driverStartSubscriptionFlutterwaveCard(
        driverId: widget.driverId,
        planType: widget.planType,
      );
      final resMap = Map<String, dynamic>.from(res);
      if (res['success'] != true) {
        _debugLogCallable('DriverSubCard', resMap);
        _payLog(
          'driver_sub_card_init_failed '
          'tx_ref=${res['tx_ref']} reason=${res['reason']} reason_code=${res['reason_code']}',
        );
        if (!mounted) {
          return;
        }
        setState(() {
          _error = _subscriptionPaymentUserMessage(
            resMap,
            fallback: 'Card checkout could not be started.',
          );
        });
        return;
      }
      final url = (res['authorization_url'] ??
              res['authorizationUrl'] ??
              res['payment_link'] ??
              '')
          .toString()
          .trim();
      if (url.isEmpty) {
        _debugLogCallable('DriverSubCard_missing_url', resMap);
        _payLog(
          'driver_sub_card_missing_checkout_url '
          'tx_ref=${resMap['tx_ref']} keys=${resMap.keys.toList()}',
        );
        if (!mounted) {
          return;
        }
        setState(() {
          _error = _subscriptionPaymentUserMessage(
            resMap,
            fallback: 'Card checkout link was missing. Please try again.',
          );
        });
        return;
      }
      final uri = Uri.parse(url);
      final txRef = (res['tx_ref'] ?? '').toString();
      _payLog(
        'driver_sub_card_launch '
        'tx_ref=$txRef url_len=${url.length} url_prefix=${url.length > 72 ? url.substring(0, 72) : url}',
      );
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        _payLog('driver_sub_card_launch_failed tx_ref=$txRef', error: 'launchUrl returned false');
        throw StateError('cannot_open_checkout');
      }
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Checkout opened. You can return here anytime — we update status automatically.',
          ),
        ),
      );
      setState(() {
        _activeTxRef = (res['tx_ref'] ?? '').toString();
      });
    } catch (e, st) {
      _payLog('driver_sub_card_exception', error: e);
      developer.log('$st', name: _payLogName);
      if (!mounted) {
        return;
      }
      setState(() {
        _error = friendlyFirebaseError(e, debugLabel: 'subscription.fw_card');
      });
    } finally {
      if (mounted) {
        setState(() {
          _cardLoading = false;
        });
      }
    }
  }

  Future<void> _createVa() async {
    setState(() {
      _vaLoading = true;
      _error = null;
    });
    try {
      final res = await _cloud.driverCreateSubscriptionFlutterwaveVa(
        driverId: widget.driverId,
        planType: widget.planType,
      );
      final resMap = Map<String, dynamic>.from(res);
      if (res['success'] != true) {
        _debugLogCallable('DriverSubVa', resMap);
        if (!mounted) {
          return;
        }
        setState(() {
          _error = _subscriptionPaymentUserMessage(
            resMap,
            fallback: 'Virtual account could not be created.',
          );
        });
        return;
      }
      final bank = res['bank'];
      if (bank is! Map) {
        throw StateError('invalid_bank_payload');
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _vaBank = Map<String, dynamic>.from(bank);
        _vaExpiresMs = int.tryParse('${res['expires_at_ms'] ?? ''}');
        _activeTxRef = (res['tx_ref'] ?? '').toString();
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = friendlyFirebaseError(e, debugLabel: 'subscription.fw_va');
      });
    } finally {
      if (mounted) {
        setState(() {
          _vaLoading = false;
        });
      }
    }
  }

  Future<void> _verifyIfPossible() async {
    final ref = _activeTxRef?.trim() ?? '';
    if (ref.isEmpty) {
      return;
    }
    try {
      final res = await _cloud.verifyPayment(reference: ref);
      if (res['success'] == true && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              (res['reason'] ?? 'verified').toString(),
            ),
          ),
        );
      }
    } catch (_) {
      /* ignore */
    }
  }

  @override
  Widget build(BuildContext context) {
    final planLabel = widget.planType == 'weekly' ? 'Weekly' : 'Monthly';
    final amountLabel = formatDriverNairaAmount(widget.amountNgn);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pay subscription'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: <Widget>[
            Text(
              '$planLabel plan · $amountLabel',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Pay with card or transfer to your one-time virtual account. '
              'No proof upload — status updates automatically. You can go back to the map anytime.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 20),
            StreamBuilder<rtdb.DatabaseEvent>(
              stream: rtdb.FirebaseDatabase.instance
                  .ref('drivers/${widget.driverId}/businessModel/subscription')
                  .onValue,
              builder: (context, snap) {
                if (!snap.hasData) {
                  return const SizedBox.shrink();
                }
                final v = snap.data!.snapshot.value;
                if (v is! Map) {
                  return const SizedBox.shrink();
                }
                final sub = Map<String, dynamic>.from(v);
                final pend = _pendingMap(sub);
                if (pend.isEmpty) {
                  return const SizedBox.shrink();
                }
                final exp = int.tryParse(
                      '${pend['pendingExpiresAtMs'] ?? pend['pending_expires_at_ms'] ?? ''}',
                    ) ??
                    0;
                final tx = (pend['pendingTxRef'] ?? pend['pending_tx_ref'] ?? '')
                    .toString();
                final mode =
                    (pend['pendingMode'] ?? pend['pending_mode'] ?? '').toString();
                final expired = exp > 0 && DateTime.now().millisecondsSinceEpoch > exp;
                return Card(
                  color: const Color(0xFFE8F5E9),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const Text(
                          'Payment pending',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 6),
                        Text('Reference: $tx'),
                        if (exp > 0)
                          Text(
                            expired
                                ? 'Virtual account expired — generate a new one below.'
                                : 'VA expires: ${DateTime.fromMillisecondsSinceEpoch(exp).toLocal()}',
                          ),
                        if (mode.isNotEmpty) Text('Method: $mode'),
                        const SizedBox(height: 8),
                        OutlinedButton(
                          onPressed: _verifyIfPossible,
                          child: const Text('Check payment status'),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
            if (_error != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: Colors.red.shade800)),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _cardLoading ? null : _startCard,
              child: _cardLoading
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Pay with card (Flutterwave)'),
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: _vaLoading ? null : _createVa,
              child: _vaLoading
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Get bank transfer (virtual account)'),
            ),
            if (_vaBank != null) ...<Widget>[
              const SizedBox(height: 20),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Text(
                        'Transfer to this account',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 8),
                      Text('Bank: ${_vaBank!['bank_name'] ?? ''}'),
                      Text('Account name: ${_vaBank!['account_name'] ?? ''}'),
                      SelectableText(
                        'Account number: ${_vaBank!['account_number'] ?? ''}',
                      ),
                      if (_vaExpiresMs != null && _vaExpiresMs! > 0)
                        Text(
                          'Expires: ${DateTime.fromMillisecondsSinceEpoch(_vaExpiresMs!).toLocal()}',
                        ),
                      const SizedBox(height: 8),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () async {
                                final n =
                                    '${_vaBank!['account_number'] ?? ''}'.trim();
                                if (n.isEmpty) return;
                                await Clipboard.setData(ClipboardData(text: n));
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('Account number copied'),
                                    ),
                                  );
                                }
                              },
                              child: const Text('Copy account'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () async {
                                final ref = (_activeTxRef ?? '').trim();
                                if (ref.isEmpty) return;
                                await Clipboard.setData(
                                  ClipboardData(text: ref),
                                );
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('Reference copied'),
                                    ),
                                  );
                                }
                              },
                              child: const Text('Copy reference'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Transfer exactly $amountLabel. '
                        'If this VA expired, tap “Get bank transfer” again.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 24),
            Text(
              'Signed in as ${FirebaseAuth.instance.currentUser?.uid ?? widget.driverId}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

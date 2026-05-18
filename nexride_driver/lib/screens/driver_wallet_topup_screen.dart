import 'dart:async';
import 'dart:developer' as developer;

import 'package:firebase_database/firebase_database.dart' as rtdb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/ride_cloud_functions_service.dart';
import '../support/friendly_firebase_errors.dart';

/// Flutterwave card + dynamic VA wallet top-up (server credits on webhook).
class DriverWalletTopUpScreen extends StatefulWidget {
  const DriverWalletTopUpScreen({super.key, required this.driverId});

  final String driverId;

  @override
  State<DriverWalletTopUpScreen> createState() => _DriverWalletTopUpScreenState();
}

class _DriverWalletTopUpScreenState extends State<DriverWalletTopUpScreen> {
  final RideCloudFunctionsService _cloud = RideCloudFunctionsService();
  static const String _payLogName = 'NexRidePaymentDriverWallet';

  void _payLog(String message, {Object? error}) {
    developer.log(message, name: _payLogName, error: error);
  }

  final TextEditingController _amountController = TextEditingController();
  bool _cardLoading = false;
  bool _vaLoading = false;
  String? _error;
  Map<String, dynamic>? _vaBank;
  int? _vaExpiresMs;
  String? _activeTxRef;
  double? _lastBalance;

  StreamSubscription<rtdb.DatabaseEvent>? _walletListen;
  bool _clearingExpiredPending = false;

  Future<void> _clearExpiredWalletPending() async {
    if (_clearingExpiredPending) {
      return;
    }
    _clearingExpiredPending = true;
    try {
      await rtdb.FirebaseDatabase.instance.ref('drivers/${widget.driverId}').update(
        <String, Object?>{
          'wallet_flutterwave_pending_tx_ref': null,
          'wallet_flutterwave_pending_expires_at_ms': null,
          'wallet_flutterwave_pending_mode': null,
          'updated_at': rtdb.ServerValue.timestamp,
        },
      );
    } catch (e) {
      _payLog('clear expired wallet pending failed', error: e);
    } finally {
      _clearingExpiredPending = false;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _vaBank = null;
      _vaExpiresMs = null;
      _activeTxRef = null;
    });
  }

  @override
  void initState() {
    super.initState();
    _walletListen = rtdb.FirebaseDatabase.instance
        .ref('wallets/${widget.driverId}')
        .onValue
        .listen((rtdb.DatabaseEvent ev) {
      final v = ev.snapshot.value;
      if (v is Map) {
        final map = Map<String, dynamic>.from(v);
        final balRaw = map['balance'] ?? map['currentBalance'];
        final bal = balRaw is num ? balRaw.toDouble() : double.tryParse('$balRaw') ?? 0.0;
        if (!mounted) {
          return;
        }
        if (_lastBalance != null && bal > _lastBalance! + 0.5) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Wallet balance updated.')),
          );
        }
        _lastBalance = bal;
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _amountController.dispose();
    unawaited(_walletListen?.cancel() ?? Future<void>.value());
    super.dispose();
  }

  int? _parseAmount() {
    final raw = _amountController.text.replaceAll(',', '').trim();
    return int.tryParse(raw);
  }

  Future<void> _startCard() async {
    final amt = _parseAmount();
    if (amt == null || amt < 100) {
      setState(() {
        _error = 'Enter amount (minimum ₦100).';
      });
      return;
    }
    setState(() {
      _cardLoading = true;
      _error = null;
    });
    try {
      final res = await _cloud.driverStartWalletTopUpFlutterwaveCard(
        driverId: widget.driverId,
        amountNgn: amt,
      );
      final resMap = Map<String, dynamic>.from(res);
      if (res['success'] != true) {
        _payLog(
          'driver_wallet_card_init_failed '
          'tx_ref=${res['tx_ref']} reason=${res['reason']} reason_code=${res['reason_code']}',
        );
        if (!mounted) {
          return;
        }
        setState(() {
          _error = (res['message']?.toString().trim().isNotEmpty == true)
              ? res['message'].toString().trim()
              : 'Card checkout could not be started. Please try again.';
        });
        return;
      }
      final url = (res['authorization_url'] ??
              res['authorizationUrl'] ??
              res['payment_link'] ??
              '')
          .toString()
          .trim();
      final txRef = (res['tx_ref'] ?? '').toString();
      if (url.isEmpty) {
        _payLog(
          'driver_wallet_card_missing_checkout_url tx_ref=$txRef keys=${resMap.keys.toList()}',
        );
        if (!mounted) {
          return;
        }
        setState(() {
          _error = 'Card checkout link was missing. Please try again.';
        });
        return;
      }
      _payLog(
        'driver_wallet_card_launch '
        'tx_ref=$txRef url_len=${url.length} url_prefix=${url.length > 72 ? url.substring(0, 72) : url}',
      );
      final uri = Uri.parse(url);
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        _payLog('driver_wallet_card_launch_failed tx_ref=$txRef', error: 'launchUrl returned false');
        throw StateError('cannot_open_checkout');
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _activeTxRef = txRef;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Checkout opened. You can leave this screen — we credit your wallet when payment completes.',
          ),
        ),
      );
    } catch (e, st) {
      _payLog('driver_wallet_card_exception', error: e);
      developer.log('$st', name: _payLogName);
      if (mounted) {
        setState(() {
          _error = friendlyFirebaseError(e, debugLabel: 'wallet.fw_card');
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _cardLoading = false;
        });
      }
    }
  }

  Future<void> _createVa() async {
    final amt = _parseAmount();
    if (amt == null || amt < 100) {
      setState(() {
        _error = 'Enter amount (minimum ₦100).';
      });
      return;
    }
    setState(() {
      _vaLoading = true;
      _error = null;
    });
    try {
      final res = await _cloud.driverCreateWalletTopUpFlutterwaveVa(
        driverId: widget.driverId,
        amountNgn: amt,
      );
      if (res['success'] != true) {
        throw StateError((res['reason'] ?? 'va_failed').toString());
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
      if (mounted) {
        setState(() {
          _error = friendlyFirebaseError(e, debugLabel: 'wallet.fw_va');
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _vaLoading = false;
        });
      }
    }
  }

  Future<void> _verify() async {
    final ref = _activeTxRef?.trim() ?? '';
    if (ref.isEmpty) {
      return;
    }
    try {
      await _cloud.verifyPayment(reference: ref);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Verification requested.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(friendlyFirebaseError(e, debugLabel: 'wallet.verify'))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Top up wallet')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: <Widget>[
            TextField(
              controller: _amountController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Amount (NGN)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            StreamBuilder<rtdb.DatabaseEvent>(
              stream: rtdb.FirebaseDatabase.instance
                  .ref('drivers/${widget.driverId}')
                  .onValue,
              builder: (context, snap) {
                if (!snap.hasData) {
                  return const SizedBox.shrink();
                }
                final row = snap.data!.snapshot.value;
                if (row is! Map) {
                  return const SizedBox.shrink();
                }
                final m = Map<String, dynamic>.from(row);
                final tx =
                    (m['wallet_flutterwave_pending_tx_ref'] ?? '').toString().trim();
                if (tx.isEmpty) {
                  return const SizedBox.shrink();
                }
                final exp = int.tryParse(
                      '${m['wallet_flutterwave_pending_expires_at_ms'] ?? ''}',
                    ) ??
                    0;
                final mode = (m['wallet_flutterwave_pending_mode'] ?? '').toString();
                final expired =
                    exp > 0 && DateTime.now().millisecondsSinceEpoch > exp;
                if (expired) {
                  unawaited(_clearExpiredWalletPending());
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      'Previous bank transfer expired — generate a new virtual account.',
                      style: TextStyle(color: Colors.orange.shade900, fontSize: 13),
                    ),
                  );
                }
                return Card(
                  color: const Color(0xFFE3F2FD),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const Text(
                          'Top-up pending',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                        Text('Reference: $tx'),
                        if (mode.isNotEmpty) Text('Method: $mode'),
                        if (exp > 0)
                          Text(
                            'VA expires: ${DateTime.fromMillisecondsSinceEpoch(exp).toLocal()}',
                          ),
                        OutlinedButton(
                          onPressed: _verify,
                          child: const Text('Check payment status'),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error!, style: TextStyle(color: Colors.red.shade800)),
              ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _cardLoading ? null : _startCard,
              child: _cardLoading
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Pay with card'),
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
                  : const Text('Get virtual account (bank transfer)'),
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
                      Text('Bank: ${_vaBank!['bank_name'] ?? ''}'),
                      Text('Account name: ${_vaBank!['account_name'] ?? ''}'),
                      SelectableText(
                        'Account number: ${_vaBank!['account_number'] ?? ''}',
                      ),
                      if (_vaExpiresMs != null && _vaExpiresMs! > 0)
                        Text(
                          'Expires: ${DateTime.fromMillisecondsSinceEpoch(_vaExpiresMs!).toLocal()}',
                        ),
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
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

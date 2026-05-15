import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Virtual-account merchant wallet top-up (Flutterwave) — listens on
/// `payment_transactions/{tx_ref}` for `verified` / wallet credit via webhook.
class MerchantVaTopUpSheet extends StatefulWidget {
  const MerchantVaTopUpSheet({
    super.key,
    required this.paymentTransactionsRef,
    required this.registration,
    required this.onRegenerateWithSameAmount,
  });

  /// `FirebaseDatabase.instance.ref('payment_transactions/$txRef')`
  final DatabaseReference paymentTransactionsRef;
  final Map<String, dynamic> registration;
  final Future<Map<String, dynamic>> Function() onRegenerateWithSameAmount;

  @override
  State<MerchantVaTopUpSheet> createState() => _MerchantVaTopUpSheetState();
}

class _MerchantVaTopUpSheetState extends State<MerchantVaTopUpSheet> {
  late Map<String, dynamic> _reg;
  StreamSubscription<DatabaseEvent>? _ptSub;
  Timer? _tick;
  int _nowMs = DateTime.now().millisecondsSinceEpoch;
  bool _regenerateBusy = false;

  @override
  void initState() {
    super.initState();
    _reg = Map<String, dynamic>.from(widget.registration);
    _ptSub = widget.paymentTransactionsRef.onValue.listen(_onPt);
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _nowMs = DateTime.now().millisecondsSinceEpoch;
      });
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _ptSub?.cancel();
    super.dispose();
  }

  void _onPt(DatabaseEvent event) {
    final raw = event.snapshot.value;
    if (raw is! Map) {
      return;
    }
    final row = raw.map((k, v) => MapEntry(k.toString(), v));
    if (row['verified'] == true) {
      if (mounted) {
        Navigator.of(context).pop('credited');
      }
    }
  }

  int get _expiresAtMs {
    final v = _reg['expires_at_ms'];
    final n = v is num ? v.toInt() : int.tryParse(v?.toString() ?? '') ?? 0;
    return n;
  }

  bool get _intentExpired {
    final exp = _expiresAtMs;
    if (exp <= 0) {
      return false;
    }
    return _nowMs > exp;
  }

  Future<void> _copy(String text, String label) async {
    await Clipboard.setData(ClipboardData(text: text.trim()));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text('$label copied')),
    );
  }

  Future<void> _handleRegenerate() async {
    if (_regenerateBusy) {
      return;
    }
    setState(() => _regenerateBusy = true);
    try {
      final res = await widget.onRegenerateWithSameAmount();
      if (!mounted) {
        return;
      }
      if (res['success'] == true && res['expires_at_ms'] != null) {
        setState(() {
          _reg = Map<String, dynamic>.from(res);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('New virtual account issued. Transfer the exact amount shown.'),
          ),
        );
      } else {
        final reason =
            (res['reason']?.toString() ?? 'unknown').replaceAll('_', ' ');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not renew ($reason)')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _regenerateBusy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bank = _reg['bank'];
    Map<String, dynamic>? bankMap;
    if (bank is Map) {
      bankMap = bank.map((k, v) => MapEntry(k.toString(), v));
    }
    final bankName = (bankMap?['bank_name'] ?? _reg['bank_name'] ?? '')
        .toString();
    final acctNum = (bankMap?['account_number'] ?? _reg['account_number'] ?? '')
        .toString();
    final acctName =
        (bankMap?['account_name'] ?? _reg['account_name'] ?? '').toString();
    final txRef =
        (_reg['tx_ref'] ?? _reg['reference'] ?? '').toString().trim();
    final rawAmt = _reg['amount_ngn'] ?? _reg['amount'];
    final amt =
        rawAmt is num
            ? rawAmt.toInt()
            : int.tryParse(rawAmt?.toString() ?? '') ?? 0;

    final exp = _expiresAtMs;
    final remainingMs = exp > 0 ? (exp - _nowMs).clamp(0, 864000000) : null;
    String countdownLabel;
    if (remainingMs == null) {
      countdownLabel = '';
    } else if (remainingMs <= 0) {
      countdownLabel = 'Expired';
    } else {
      final secs = (remainingMs / 1000).floor();
      final m = secs ~/ 60;
      final s = secs % 60;
      countdownLabel = '${m}m ${s.toString().padLeft(2, '0')}s';
    }

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 12,
          bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              'Wallet top-up',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _intentExpired
                  ? 'This payment link expired. Generate a new account if you still want to top up.'
                  : 'Waiting for your transfer. Your wallet credits automatically when payment is confirmed — no receipt upload.',
              style: TextStyle(
                color:
                    _intentExpired
                        ? Theme.of(context).colorScheme.error
                        : Theme.of(context).colorScheme.primary,
              ),
            ),
            if (countdownLabel.isNotEmpty) ...<Widget>[
              const SizedBox(height: 4),
              Text('Time left: $countdownLabel'),
            ],
            const SizedBox(height: 16),
            Text(
              'Transfer exactly ₦$amt',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            if (bankName.isNotEmpty) Text('Bank: $bankName'),
            if (acctNum.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  Expanded(child: SelectableText('Account: $acctNum')),
                  IconButton(
                    tooltip: 'Copy account number',
                    onPressed: () => _copy(acctNum, 'Account number'),
                    icon: const Icon(Icons.copy_rounded),
                  ),
                ],
              ),
            ],
            if (acctName.isNotEmpty) Text('Account name: $acctName'),
            if (txRef.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  Expanded(child: SelectableText('Reference: $txRef')),
                  IconButton(
                    tooltip: 'Copy reference',
                    onPressed: () => _copy(txRef, 'Reference'),
                    icon: const Icon(Icons.copy_rounded),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            Text(
              'If you send the wrong amount or pay after expiry, an operator may need to review the transfer.',
              style: TextStyle(
                fontSize: 12,
                height: 1.35,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            if (_intentExpired)
              FilledButton(
                onPressed: _regenerateBusy ? null : _handleRegenerate,
                child:
                    _regenerateBusy
                        ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                        : const Text('Generate new account'),
              )
            else
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Done'),
              ),
          ],
        ),
      ),
    );
  }
}

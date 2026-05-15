import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Bottom sheet for Flutterwave dynamic virtual-account (VA) transfers on ride/dispatch flows.
///
/// Rider can copy bank details/reference, monitor expiry, regenerate after expiry,
/// or continue matching while awaiting webhook confirmation.
class RiderFlutterwaveVaPaymentSheet extends StatefulWidget {
  const RiderFlutterwaveVaPaymentSheet({
    super.key,
    required this.databaseRef,
    required this.initialRegistration,
    required this.onRegenerate,
    this.currencyLabel = '₦',
    this.sheetTitle = 'Pay with bank transfer',
  });

  final DatabaseReference databaseRef;
  final Map<String, dynamic> initialRegistration;

  /// Callable when the VA intent expired — backend issues a fresh virtual account.
  final Future<Map<String, dynamic>> Function() onRegenerate;

  final String currencyLabel;
  final String sheetTitle;

  @override
  State<RiderFlutterwaveVaPaymentSheet> createState() =>
      _RiderFlutterwaveVaPaymentSheetState();
}

class _RiderFlutterwaveVaPaymentSheetState
    extends State<RiderFlutterwaveVaPaymentSheet> {
  late Map<String, dynamic> _reg;
  StreamSubscription<DatabaseEvent>? _entitySub;
  Timer? _tick;
  int _nowMs = DateTime.now().millisecondsSinceEpoch;
  bool _regenerateBusy = false;

  @override
  void initState() {
    super.initState();
    _reg = Map<String, dynamic>.from(widget.initialRegistration);
    _entitySub = widget.databaseRef.onValue.listen(_onEntity);
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
    _entitySub?.cancel();
    super.dispose();
  }

  void _onEntity(DatabaseEvent event) {
    final raw = event.snapshot.value;
    if (raw is! Map) {
      return;
    }
    final row = raw.map((k, v) => MapEntry(k.toString(), v));
    final ps = (row['payment_status']?.toString() ?? '').trim().toLowerCase();
    final tid = (row['payment_transaction_id']?.toString() ?? '').trim();
    if ((ps == 'verified' || ps == 'paid') && tid.isNotEmpty) {
      if (mounted) {
        Navigator.of(context).pop(true);
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

  Widget _labeledRow(String label, String value, {VoidCallback? onCopy}) {
    final v = value.trim();
    if (v.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(child: SelectableText(v, style: const TextStyle(fontSize: 17))),
              if (onCopy != null)
                IconButton(
                  tooltip: 'Copy',
                  onPressed: onCopy,
                  icon: const Icon(Icons.copy_rounded),
                ),
            ],
          ),
        ],
      ),
    );
  }

  String _moneyLabel() {
    final raw = _reg['amount'] ?? _reg['total_ngn'];
    final n =
        raw is num
            ? raw.toDouble()
            : double.tryParse(raw?.toString() ?? '') ?? 0;
    final asInt = n.round();
    return '${widget.currencyLabel}${asInt.toString()}';
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
      final res = await widget.onRegenerate();
      if (!mounted) {
        return;
      }
      if (res['success'] == true && res['expires_at_ms'] != null) {
        setState(() {
          _reg = Map<String, dynamic>.from(res);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('New payment account ready. Transfer the shown amount.'),
          ),
        );
      } else {
        final reason =
            (res['reason']?.toString() ?? 'unknown').replaceAll('_', ' ');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not renew bank details ($reason)')),
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
        (_reg['tx_ref'] ?? _reg['reference'] ?? _reg['txRef'] ?? '')
            .toString()
            .trim();

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

    final instruction =
        (_reg['instructions']?.toString() ?? '').trim().isEmpty
            ? 'Transfer exactly ${_moneyLabel()} — payment confirms automatically. No receipt upload required.'
            : _reg['instructions'].toString().trim();

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
              widget.sheetTitle,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Status: ${_intentExpired ? 'Expired — generate a fresh account below' : 'Waiting for transfer'}',
              style: TextStyle(
                color:
                    _intentExpired
                        ? Theme.of(context).colorScheme.error
                        : Theme.of(context).colorScheme.primary,
              ),
            ),
            if (countdownLabel.isNotEmpty) ...<Widget>[
              const SizedBox(height: 4),
              Text('Time left on this payment link: $countdownLabel'),
            ],
            const SizedBox(height: 16),
            Text(
              'Transfer exactly ${_moneyLabel()}',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            _labeledRow('Bank', bankName),
            _labeledRow(
              'Account number',
              acctNum,
              onCopy: () => _copy(acctNum, 'Account number'),
            ),
            _labeledRow('Account name', acctName),
            _labeledRow(
              'Reference / tx_ref',
              txRef,
              onCopy: () => _copy(txRef, 'Reference'),
            ),
            const SizedBox(height: 6),
            Text(
              instruction,
              style: TextStyle(
                fontSize: 13,
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
                        : const Text('Generate new payment details'),
              )
            else
              FilledButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Continue — find a driver'),
              ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }
}

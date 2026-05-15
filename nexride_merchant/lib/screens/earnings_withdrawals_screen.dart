import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/merchant_app_state.dart';
import '../utils/nx_callable_messages.dart';
import '../widgets/nx_feedback.dart';

class EarningsWithdrawalsScreen extends StatefulWidget {
  const EarningsWithdrawalsScreen({super.key});

  @override
  State<EarningsWithdrawalsScreen> createState() => _EarningsWithdrawalsScreenState();
}

class _EarningsWithdrawalsScreenState extends State<EarningsWithdrawalsScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _entries = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _pendingTopups = <Map<String, dynamic>>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final state = context.read<MerchantAppState>();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await state.gateway.merchantListWalletLedger();
      if (res['success'] != true) {
        setState(() {
          _error = nxMapFailureMessage(
            Map<String, dynamic>.from(res),
            'Wallet activity could not be loaded.',
          );
          _entries = <Map<String, dynamic>>[];
          _pendingTopups = <Map<String, dynamic>>[];
        });
        return;
      }
      final rawE = res['entries'];
      final rawP = res['pending_bank_topups'];
      setState(() {
        _entries = rawE is List
            ? rawE.map((e) => Map<String, dynamic>.from(e as Map)).toList()
            : <Map<String, dynamic>>[];
        _pendingTopups = rawP is List
            ? rawP.map((e) => Map<String, dynamic>.from(e as Map)).toList()
            : <Map<String, dynamic>>[];
        _error = null;
      });
    } catch (e) {
      setState(() {
        _error = nxUserFacingMessage(e);
        _entries = <Map<String, dynamic>>[];
        _pendingTopups = <Map<String, dynamic>>[];
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _requestWithdrawal() async {
    final state = context.read<MerchantAppState>();
    final amountCtl = TextEditingController();
    final bankCtl = TextEditingController();
    final nameCtl = TextEditingController();
    final acctCtl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Request withdrawal'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                controller: amountCtl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Amount (NGN)'),
              ),
              TextField(
                controller: bankCtl,
                decoration: const InputDecoration(labelText: 'Bank name'),
              ),
              TextField(
                controller: nameCtl,
                decoration: const InputDecoration(labelText: 'Account name'),
              ),
              TextField(
                controller: acctCtl,
                decoration: const InputDecoration(labelText: 'Account number'),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Submit')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final amount = int.tryParse(amountCtl.text.trim().replaceAll(',', ''));
    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invalid amount')),
      );
      return;
    }
    try {
      final res = await state.gateway.merchantRequestWithdrawal(<String, dynamic>{
        'amount': amount,
        'bankName': bankCtl.text.trim(),
        'accountName': nameCtl.text.trim(),
        'accountNumber': acctCtl.text.trim(),
      });
      if (!mounted) return;
      if (res['success'] != true) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              nxMapFailureMessage(
                Map<String, dynamic>.from(res),
                'Withdrawal request could not be sent.',
              ),
            ),
          ),
        );
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Withdrawal queued for admin review. Funds are debited only when an admin marks it paid.',
          ),
        ),
      );
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(nxUserFacingMessage(e))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Earnings & withdrawals'),
        actions: <Widget>[
          IconButton(
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: Provider.of<MerchantAppState>(context, listen: false).isApproved
            ? _requestWithdrawal
            : null,
        icon: const Icon(Icons.outbound),
        label: const Text('Withdraw'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? NxEmptyState(
                  title: 'Could not load ledger',
                  subtitle: _error!,
                  icon: Icons.error_outline,
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: <Widget>[
                      if (_pendingTopups.isNotEmpty) ...<Widget>[
                        Text(
                          'Pending bank top-ups',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                        const SizedBox(height: 8),
                        ..._pendingTopups.map(
                          (p) => Card(
                            child: ListTile(
                              title: Text('₦${p['amount_ngn'] ?? ''}'),
                              subtitle: Text(
                                'Ref: ${p['narration_reference'] ?? ''}\n'
                                'Proof uploaded: ${p['proof_uploaded'] == true ? 'yes' : 'no'}',
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                      ],
                      Text(
                        'Wallet ledger',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      const SizedBox(height: 8),
                      if (_entries.isEmpty)
                        const NxEmptyState(
                          title: 'No ledger entries yet',
                          subtitle:
                              'Top-ups and withdrawals appear here after server-side money movement.',
                          icon: Icons.receipt_long_outlined,
                        )
                      else
                        ..._entries.map(
                          (e) => Card(
                            child: ListTile(
                              title: Text('${e['type'] ?? e['direction'] ?? 'entry'}'),
                              subtitle: Text(
                                'Amount: ₦${e['amount_ngn'] ?? ''} · '
                                'Balance after: ₦${e['balance_after_ngn'] ?? e['wallet_balance_after_ngn'] ?? '—'} · '
                                'When: ${e['created_at'] ?? ''}',
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
    );
  }
}

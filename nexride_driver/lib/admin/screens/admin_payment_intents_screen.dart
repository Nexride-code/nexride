import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/admin_models.dart';
import '../services/admin_data_service.dart';
import '../utils/admin_formatters.dart';
import '../widgets/admin_components.dart';

/// VA + bank transfer intents from Firestore [`payment_intents`].
class AdminPaymentIntentsScreen extends StatefulWidget {
  const AdminPaymentIntentsScreen({
    required this.dataService,
    required this.session,
    super.key,
  });

  final AdminDataService dataService;
  final AdminSession session;

  @override
  State<AdminPaymentIntentsScreen> createState() =>
      _AdminPaymentIntentsScreenState();
}

class _AdminPaymentIntentsScreenState extends State<AdminPaymentIntentsScreen> {
  bool _loading = true;
  bool _expiring = false;
  String? _fatal;
  String _statusFilter = 'pending_transfer';
  final List<Map<String, dynamic>> _rows = <Map<String, dynamic>>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _fatal = null;
    });
    try {
      final raw = await widget.dataService.adminListPaymentIntents(
        status: _statusFilter,
      );
      final ok = raw['success'] == true;
      if (!ok) {
        setState(() {
          _fatal = raw['reason']?.toString() ?? 'load_failed';
          _rows.clear();
        });
        return;
      }
      final list = raw['intents'];
      final next = <Map<String, dynamic>>[];
      if (list is List<dynamic>) {
        for (final item in list) {
          if (item is Map) {
            next.add(item.map((k, v) => MapEntry(k.toString(), v)));
          }
        }
      }
      setState(() {
        _rows
          ..clear()
          ..addAll(next);
      });
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _runExpireSweep() async {
    setState(() => _expiring = true);
    try {
      final r = await widget.dataService.adminExpireStaleVaPaymentIntents();
      final ok = r['success'] == true;
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ok
                ? 'Sweep complete: expired ${r['expired'] ?? 0} intent(s).'
                : 'Expire sweep failed: ${r['reason'] ?? 'unknown'}',
          ),
        ),
      );
      await _load();
    } finally {
      if (mounted) {
        setState(() => _expiring = false);
      }
    }
  }

  static String _fmtTime(int? ms) {
    if (ms == null || ms <= 0) {
      return '—';
    }
    return formatAdminDateTime(DateTime.fromMillisecondsSinceEpoch(ms));
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.session.hasPermission('dashboard.read')) {
      return const AdminFullscreenState(
        title: 'Payment intents',
        message: 'You need dashboard.read to view payment intents.',
        icon: Icons.lock_outline,
      );
    }
    return Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              'Payment intents (Flutterwave VA)',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Operational list of virtual-account bank transfer flows. Legacy manual rows '
              'stay visible when flagged (`legacy_manual_bank`).',
              style: TextStyle(color: Colors.grey.shade800, height: 1.4),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                SizedBox(
                  width: 260,
                  child: DropdownButtonFormField<String>(
                    value: _statusFilter,
                    decoration: const InputDecoration(
                      labelText: 'Filter by status',
                      border: OutlineInputBorder(),
                    ),
                    items: const <DropdownMenuItem<String>>[
                      DropdownMenuItem(value: 'all', child: Text('all')),
                      DropdownMenuItem(
                        value: 'pending_transfer',
                        child: Text('pending_transfer'),
                      ),
                      DropdownMenuItem(value: 'paid', child: Text('paid')),
                      DropdownMenuItem(value: 'expired', child: Text('expired')),
                      DropdownMenuItem(
                        value: 'pending_review',
                        child: Text('pending_review'),
                      ),
                      DropdownMenuItem(value: 'failed', child: Text('failed')),
                      DropdownMenuItem(
                        value: 'suspicious',
                        child: Text('suspicious'),
                      ),
                    ],
                    onChanged: _loading
                        ? null
                        : (String? v) async {
                            if (v == null) return;
                            setState(() => _statusFilter = v);
                            await _load();
                          },
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
                  label: const Text('Refresh'),
                ),
                OutlinedButton.icon(
                  onPressed: (_loading || _expiring) ? null : _runExpireSweep,
                  icon: _expiring
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.hourglass_bottom_rounded),
                  label: const Text('Run expire sweep'),
                ),
              ],
            ),
            if (_fatal != null) ...<Widget>[
              const SizedBox(height: 14),
              MaterialBanner(
                backgroundColor: Colors.orange.shade50,
                content: Text(_fatal!),
                actions: <Widget>[
                  TextButton(onPressed: _load, child: const Text('Retry')),
                ],
              ),
            ],
            const SizedBox(height: 16),
            if (_loading && _rows.isEmpty)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_rows.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'No rows for “$_statusFilter”.',
                  style: TextStyle(color: Colors.grey.shade700),
                ),
              )
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _rows.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (BuildContext context, int i) {
                  final r = _rows[i];
                  final tx = (r['tx_ref'] ?? '').toString();
                  final legacy = r['legacy_manual_bank'] == true;
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    title: Text(tx, style: const TextStyle(fontSize: 13)),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          '${r['status'] ?? '—'} • settlement: ${r['settlement_state'] ?? '—'}',
                        ),
                        Text(
                          'owner: ${r['owner_uid'] ?? '—'} • context: ${r['app_context'] ?? '—'} • flow: ${r['flow'] ?? '—'}',
                        ),
                        Text(
                          'amount: ${r['amount_ngn'] ?? r['total_ngn'] ?? '—'} ${r['currency'] ?? 'NGN'}',
                        ),
                        Text(
                          'ride: ${r['ride_id'] ?? '—'} • delivery: ${r['delivery_id'] ?? '—'} • merchant: ${r['merchant_id'] ?? '—'} '
                          '• topup doc: ${r['merchant_bank_topup_id'] ?? '—'}',
                        ),
                        Text(
                          'created: ${_fmtTime(_asInt(r['created_at_ms']))} • expires: ${_fmtTime(_asInt(r['expires_at_ms']))} • updated: ${_fmtTime(_asInt(r['updated_at_ms']))}',
                        ),
                        if (legacy)
                          Text(
                            'legacy manual (audit only)',
                            style: TextStyle(
                              color: Colors.brown.shade800,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                      ],
                    ),
                    trailing: IconButton(
                      tooltip: 'Copy tx_ref',
                      icon: const Icon(Icons.copy_rounded),
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: tx));
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('tx_ref copied')),
                          );
                        }
                      },
                    ),
                  );
                },
              ),
          ],
        ),
    );
  }

  static int? _asInt(dynamic v) {
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '');
  }
}

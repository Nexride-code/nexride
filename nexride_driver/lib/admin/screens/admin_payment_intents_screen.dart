import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/admin_models.dart';
import '../services/admin_data_service.dart';
import '../utils/admin_formatters.dart';
import '../widgets/admin_components.dart';

/// Payments admin: RTDB transactions ledger + Firestore VA bank-transfer intents.
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

class _AdminPaymentIntentsScreenState extends State<AdminPaymentIntentsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.session.hasPermission('finance.read')) {
      return const AdminFullscreenState(
        title: 'Payments',
        message: 'You need finance.read to view payments.',
        icon: Icons.lock_outline,
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            'Payments',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
          ),
          const SizedBox(height: 6),
          Text(
            'Audit money movement via safe Flutterwave refs only (no card PAN/CVV).',
            style: TextStyle(color: Colors.grey.shade800, height: 1.4),
          ),
          const SizedBox(height: 12),
          TabBar(
            controller: _tabs,
            tabs: const <Tab>[
              Tab(text: 'All transactions'),
              Tab(text: 'Bank transfer intents'),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: MediaQuery.of(context).size.height * 0.72,
            child: TabBarView(
              controller: _tabs,
              children: <Widget>[
                _AdminPaymentTransactionsTab(dataService: widget.dataService),
                _AdminBankTransferIntentsTab(
                  dataService: widget.dataService,
                  session: widget.session,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AdminPaymentTransactionsTab extends StatefulWidget {
  const _AdminPaymentTransactionsTab({required this.dataService});

  final AdminDataService dataService;

  @override
  State<_AdminPaymentTransactionsTab> createState() =>
      _AdminPaymentTransactionsTabState();
}

class _AdminPaymentTransactionsTabState
    extends State<_AdminPaymentTransactionsTab> {
  bool _loading = false;
  String? _fatal;
  String _methodFilter = 'all';
  String _statusFilter = 'all';
  final TextEditingController _rideIdController = TextEditingController();
  final TextEditingController _riderIdController = TextEditingController();
  final TextEditingController _driverIdController = TextEditingController();
  final List<Map<String, dynamic>> _rows = <Map<String, dynamic>>[];
  String? _nextCursor;
  bool _hasMore = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(reset: true));
  }

  @override
  void dispose() {
    _rideIdController.dispose();
    _riderIdController.dispose();
    _driverIdController.dispose();
    super.dispose();
  }

  Future<void> _load({required bool reset}) async {
    setState(() {
      _loading = true;
      _fatal = null;
    });
    try {
      final raw = await widget.dataService.adminListPaymentTransactionsPage(
        method: _methodFilter,
        status: _statusFilter,
        rideId: _rideIdController.text,
        riderId: _riderIdController.text,
        driverId: _driverIdController.text,
        cursor: reset ? '' : (_nextCursor ?? ''),
        limit: 50,
      );
      if (raw['success'] != true) {
        setState(() {
          _fatal = raw['reason']?.toString() ?? 'load_failed';
          if (reset) _rows.clear();
        });
        return;
      }
      final txMap = raw['transactions'];
      final next = <Map<String, dynamic>>[];
      if (txMap is Map) {
        for (final entry in txMap.entries) {
          if (entry.value is Map) {
            final row = Map<String, dynamic>.from(entry.value as Map);
            row['tx_ref'] ??= entry.key.toString();
            next.add(row);
          }
        }
      }
      next.sort(
        (Map<String, dynamic> a, Map<String, dynamic> b) =>
            (_asInt(b['updated_at']) ?? 0).compareTo(_asInt(a['updated_at']) ?? 0),
      );
      setState(() {
        if (reset) {
          _rows
            ..clear()
            ..addAll(next);
        } else {
          _rows.addAll(next);
        }
        _nextCursor = raw['nextCursor']?.toString();
        _hasMore = raw['hasMore'] == true;
      });
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  static int? _asInt(dynamic v) {
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '');
  }

  static String _fmtTime(int? ms) {
    if (ms == null || ms <= 0) return '—';
    return formatAdminDateTime(DateTime.fromMillisecondsSinceEpoch(ms));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            SizedBox(
              width: 160,
              child: DropdownButtonFormField<String>(
                value: _methodFilter,
                decoration: const InputDecoration(
                  labelText: 'Method',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: const <DropdownMenuItem<String>>[
                  DropdownMenuItem(value: 'all', child: Text('all')),
                  DropdownMenuItem(value: 'card', child: Text('card')),
                  DropdownMenuItem(
                    value: 'bank_transfer',
                    child: Text('bank_transfer'),
                  ),
                  DropdownMenuItem(
                    value: 'wallet_topup',
                    child: Text('wallet_topup'),
                  ),
                ],
                onChanged: _loading
                    ? null
                    : (String? v) async {
                        if (v == null) return;
                        setState(() => _methodFilter = v);
                        await _load(reset: true);
                      },
              ),
            ),
            SizedBox(
              width: 160,
              child: DropdownButtonFormField<String>(
                value: _statusFilter,
                decoration: const InputDecoration(
                  labelText: 'Status',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: const <DropdownMenuItem<String>>[
                  DropdownMenuItem(value: 'all', child: Text('all')),
                  DropdownMenuItem(value: 'authorized', child: Text('authorized')),
                  DropdownMenuItem(value: 'captured', child: Text('captured')),
                  DropdownMenuItem(value: 'pending', child: Text('pending')),
                  DropdownMenuItem(value: 'failed', child: Text('failed')),
                  DropdownMenuItem(value: 'voided', child: Text('voided')),
                  DropdownMenuItem(value: 'refunded', child: Text('refunded')),
                ],
                onChanged: _loading
                    ? null
                    : (String? v) async {
                        if (v == null) return;
                        setState(() => _statusFilter = v);
                        await _load(reset: true);
                      },
              ),
            ),
            SizedBox(
              width: 140,
              child: TextField(
                controller: _rideIdController,
                decoration: const InputDecoration(
                  labelText: 'rideId',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            SizedBox(
              width: 140,
              child: TextField(
                controller: _riderIdController,
                decoration: const InputDecoration(
                  labelText: 'riderId',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            SizedBox(
              width: 140,
              child: TextField(
                controller: _driverIdController,
                decoration: const InputDecoration(
                  labelText: 'driverId',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            FilledButton.icon(
              onPressed: _loading ? null : () => _load(reset: true),
              icon: _loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.search_rounded),
              label: const Text('Apply filters'),
            ),
          ],
        ),
        if (_fatal != null) ...<Widget>[
          const SizedBox(height: 12),
          MaterialBanner(
            backgroundColor: Colors.orange.shade50,
            content: Text(_fatal!),
            actions: <Widget>[
              TextButton(
                onPressed: () => _load(reset: true),
                child: const Text('Retry'),
              ),
            ],
          ),
        ],
        const SizedBox(height: 12),
        Expanded(
          child: _loading && _rows.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : _rows.isEmpty
                  ? Center(
                      child: Text(
                        'No transactions for current filters.',
                        style: TextStyle(color: Colors.grey.shade700),
                      ),
                    )
                  : ListView.separated(
                      itemCount: _rows.length + (_hasMore ? 1 : 0),
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (BuildContext context, int i) {
                        if (i >= _rows.length) {
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Center(
                              child: OutlinedButton(
                                onPressed: _loading
                                    ? null
                                    : () => _load(reset: false),
                                child: const Text('Load more'),
                              ),
                            ),
                          );
                        }
                        final r = _rows[i];
                        final tx = (r['tx_ref'] ?? '').toString();
                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(vertical: 6),
                          title: Text(
                            '${r['payment_method'] ?? '—'} • ${r['payment_status'] ?? '—'} • '
                            '${r['amount'] ?? '—'} ${r['currency'] ?? 'NGN'}',
                            style: const TextStyle(fontSize: 13),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                'purpose: ${r['purpose'] ?? '—'} • flow: ${r['flow'] ?? '—'}',
                              ),
                              Text('tx_ref: $tx'),
                              Text(
                                'ride: ${r['rideId'] ?? '—'} • rider: ${r['riderId'] ?? '—'} • '
                                'driver: ${r['driverId'] ?? '—'}',
                              ),
                              Text(
                                'flw_ref: ${r['flw_ref'] ?? '—'} • auth: ${r['authorization_ref'] ?? '—'}',
                              ),
                              Text('updated: ${_fmtTime(_asInt(r['updated_at']))}'),
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
        ),
      ],
    );
  }
}

class _AdminBankTransferIntentsTab extends StatefulWidget {
  const _AdminBankTransferIntentsTab({
    required this.dataService,
    required this.session,
  });

  final AdminDataService dataService;
  final AdminSession session;

  @override
  State<_AdminBankTransferIntentsTab> createState() =>
      _AdminBankTransferIntentsTabState();
}

class _AdminBankTransferIntentsTabState extends State<_AdminBankTransferIntentsTab> {
  bool _loading = true;
  bool _expiring = false;
  String? _fatal;
  String _statusFilter = 'all';
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

  static int? _asInt(dynamic v) {
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '');
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          'Flutterwave VA bank-transfer intents (Firestore)',
          style: TextStyle(color: Colors.grey.shade800, height: 1.35),
        ),
        const SizedBox(height: 12),
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
                  DropdownMenuItem(value: 'pending', child: Text('pending')),
                  DropdownMenuItem(
                    value: 'pending_gateway',
                    child: Text('pending_gateway'),
                  ),
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
        const SizedBox(height: 12),
        Expanded(
          child: _loading && _rows.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : _rows.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'No rows for “$_statusFilter”.',
                        style: TextStyle(color: Colors.grey.shade700),
                      ),
                    )
                  : ListView.separated(
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
                                '${r['status'] ?? '—'} • settlement: ${r['settlement_state'] ?? '—'} • provider: ${r['provider'] ?? '—'}',
                              ),
                              Text(
                                'owner: ${r['owner_uid'] ?? '—'} • driver: ${r['driver_id'] ?? '—'} • context: ${r['app_context'] ?? '—'} • flow: ${r['flow'] ?? '—'}',
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
        ),
      ],
    );
  }
}

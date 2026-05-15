import 'dart:async' show Timer, unawaited;

import 'package:flutter/material.dart';

import '../admin_config.dart';
import '../services/admin_data_service.dart';
import '../utils/admin_formatters.dart';
import '../widgets/admin_components.dart';

/// Production system health (`adminGetProductionHealthSnapshot`).
///
/// Hosted inside [AdminPanelScreen]'s vertical [SingleChildScrollView] — use
/// [MainAxisSize.min] on all [Column]s (no nested vertical scroll).
class AdminSystemHealthScreen extends StatefulWidget {
  const AdminSystemHealthScreen({super.key, required this.dataService});

  final AdminDataService dataService;

  @override
  State<AdminSystemHealthScreen> createState() => _AdminSystemHealthScreenState();
}

class _AdminSystemHealthScreenState extends State<AdminSystemHealthScreen> {
  static const Duration _pollInterval = Duration(seconds: 30);

  bool _loading = true;
  String? _fatalError;
  Map<String, dynamic> _snapshot = const <String, dynamic>{};
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _timer = Timer.periodic(_pollInterval, (_) {
      if (mounted) {
        unawaited(_load(silent: true));
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Map<String, dynamic> _mapOf(Object? raw) {
    if (raw == null) {
      return <String, dynamic>{};
    }
    if (raw is Map<String, dynamic>) {
      return raw;
    }
    if (raw is Map) {
      return Map<String, dynamic>.from(raw);
    }
    return <String, dynamic>{};
  }

  List<Map<String, dynamic>> _listOfMaps(Object? raw) {
    if (raw is! List) {
      return <Map<String, dynamic>>[];
    }
    final out = <Map<String, dynamic>>[];
    for (final dynamic e in raw) {
      final m = _mapOf(e);
      if (m.isNotEmpty) {
        out.add(m);
      }
    }
    return out;
  }

  int _asInt(Object? v) {
    if (v is int) {
      return v;
    }
    if (v is num) {
      return v.toInt();
    }
    return int.tryParse('$v') ?? 0;
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _fatalError = null;
      });
    }
    try {
      final raw = await widget.dataService.adminGetProductionHealthSnapshot();
      if (!mounted) {
        return;
      }
      if (raw['success'] != true) {
        final String msg = raw['message']?.toString().trim().isNotEmpty == true
            ? raw['message'].toString()
            : (raw['reason']?.toString() ?? 'Health snapshot failed');
        setState(() {
          _fatalError = msg;
          _loading = false;
        });
        return;
      }
      setState(() {
        _snapshot = _mapOf(raw['snapshot']);
        _fatalError = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _fatalError = e.toString();
        _loading = false;
      });
    }
  }

  Color _statusColor(String? status) {
    return switch (status) {
      'green' => AdminThemeTokens.success,
      'yellow' => AdminThemeTokens.warning,
      'red' => AdminThemeTokens.danger,
      _ => AdminThemeTokens.slate,
    };
  }

  Widget _healthCard({
    required String title,
    required String status,
    required String summary,
    String? detail,
  }) {
    final Color c = _statusColor(status);
    return AdminSurfaceCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: c, shape: BoxShape.circle),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: AdminThemeTokens.ink,
                  ),
                ),
              ),
              Text(
                status.toUpperCase(),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: c,
                  letterSpacing: 0.6,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            summary,
            style: const TextStyle(
              fontSize: 13,
              height: 1.35,
              color: AdminThemeTokens.slate,
            ),
          ),
          if (detail != null && detail.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              detail,
              style: const TextStyle(fontSize: 12, color: Color(0xFF736C61)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _metricRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 200,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 13,
                color: AdminThemeTokens.slate,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 13, color: AdminThemeTokens.ink),
            ),
          ),
        ],
      ),
    );
  }

  String _subsystemUiStatus(Map<String, dynamic> row) {
    final String st = row['status']?.toString() ?? '';
    if (st == 'ok') {
      return 'green';
    }
    if (st == 'degraded') {
      return 'yellow';
    }
    return 'red';
  }

  Widget _buildInfrastructureCard(Map<String, dynamic> infra) {
    final Map<String, dynamic> subsystems = _mapOf(infra['subsystems']);
    final String rollup = infra['status']?.toString() ?? 'unknown';
    final List<MapEntry<String, dynamic>> rows = subsystems.entries.toList()
      ..sort((MapEntry<String, dynamic> a, MapEntry<String, dynamic> b) =>
          a.key.compareTo(b.key));

    return AdminSurfaceCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Infrastructure ($rollup)',
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: AdminThemeTokens.ink,
            ),
          ),
          const SizedBox(height: 10),
          if (rows.isEmpty)
            const Text(
              'No subsystem diagnostics returned.',
              style: TextStyle(fontSize: 13, color: AdminThemeTokens.slate),
            )
          else
            ...rows.map((MapEntry<String, dynamic> e) {
              final Map<String, dynamic> row = _mapOf(e.value);
              final String label = e.key.toUpperCase();
              final String uiStatus = _subsystemUiStatus(row);
              final String latency = '${row['latency_ms'] ?? '—'} ms';
              final String reachable =
                  row['reachable'] == true ? 'reachable' : 'unreachable';
              final String? reason = row['failure_reason']?.toString();
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _healthCard(
                  title: label,
                  status: uiStatus,
                  summary: '$reachable · $latency',
                  detail: reason != null && reason.isNotEmpty
                      ? 'retryable=${row['retryable'] == true} · $reason'
                      : null,
                ),
              );
            }),
        ],
      ),
    );
  }

  String _formatTs(Object? ms) {
    final int v = _asInt(ms);
    if (v <= 0) {
      return '—';
    }
    return formatAdminDateTime(DateTime.fromMillisecondsSinceEpoch(v));
  }

  Widget _buildErrorCard(String message) {
    return AdminSurfaceCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Row(
            children: <Widget>[
              Icon(Icons.error_outline_rounded, color: AdminThemeTokens.danger),
              SizedBox(width: 10),
              Text(
                'Could not load system health',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: AdminThemeTokens.ink,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SelectableText(
            message,
            style: const TextStyle(fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _loading ? null : () => unawaited(_load()),
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    final String overall = _snapshot['overall_status']?.toString() ?? 'unknown';
    final Map<String, dynamic> infra = _mapOf(
      _snapshot['infrastructure'] is Map
          ? _snapshot['infrastructure']
          : _mapOf(_snapshot['infrastructure']),
    );
    final Map<String, dynamic> drivers = _mapOf(_snapshot['drivers']);
    final Map<String, dynamic> merchants = _mapOf(_snapshot['merchants']);
    final Map<String, dynamic> withdrawals = _mapOf(_snapshot['withdrawals']);
    final Map<String, dynamic> riderPay = _mapOf(_snapshot['rider_payment_issues']);
    final Map<String, dynamic> svc = _mapOf(_snapshot['service_area_warnings']);
    final Map<String, dynamic> payout = _mapOf(_snapshot['payout_warnings']);
    final Map<String, dynamic> ver = _mapOf(_snapshot['verifications']);
    final Map<String, dynamic> support = _mapOf(_snapshot['support']);
    final List<Map<String, dynamic>> cards = _listOfMaps(_snapshot['cards']);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                'Production system health',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: AdminThemeTokens.ink,
                    ),
              ),
            ),
            FilledButton.icon(
              onPressed: _loading ? null : () => unawaited(_load()),
              icon: _loading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Refresh'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Store-readiness snapshot · overall $overall · updated ${_formatTs(_snapshot['generated_at'])}',
          style: const TextStyle(fontSize: 13, color: AdminThemeTokens.slate),
        ),
        const SizedBox(height: 16),
        if (cards.isNotEmpty)
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: cards
                .map(
                  (Map<String, dynamic> c) => SizedBox(
                    width: 280,
                    child: _healthCard(
                      title: c['title']?.toString() ?? 'Check',
                      status: c['status']?.toString() ?? 'yellow',
                      summary: c['summary']?.toString() ?? '',
                    ),
                  ),
                )
                .toList(),
          )
        else
          _healthCard(
            title: 'Overall',
            status: overall,
            summary: 'Health cards unavailable — see metrics below.',
          ),
        const SizedBox(height: 20),
        _buildInfrastructureCard(infra),
        const SizedBox(height: 12),
        AdminSurfaceCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                'Heartbeats & freshness',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: AdminThemeTokens.ink,
                ),
              ),
              const SizedBox(height: 10),
              _metricRow('Drivers online', '${_asInt(drivers['online'])}'),
              _metricRow('Stale driver heartbeats', '${_asInt(drivers['stale_heartbeat'])}'),
              _metricRow(
                'Latest driver heartbeat',
                _formatTs(drivers['latest_heartbeat_ms']),
              ),
              _metricRow('Merchants open', '${_asInt(merchants['open'])}'),
              _metricRow('Stale merchant portal', '${_asInt(merchants['stale_portal'])}'),
              _metricRow(
                'Latest merchant portal seen',
                _formatTs(merchants['latest_portal_last_seen_ms']),
              ),
              _metricRow(
                'Latest merchant order activity',
                _formatTs(merchants['latest_order_updated_ms']),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        AdminSurfaceCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                'Queues & rider payments',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: AdminThemeTokens.ink,
                ),
              ),
              const SizedBox(height: 10),
              _metricRow(
                'Pending driver withdrawals',
                '${_asInt(withdrawals['pending_driver'])}',
              ),
              _metricRow(
                'Pending merchant withdrawals',
                '${_asInt(withdrawals['pending_merchant'])}',
              ),
              _metricRow(
                'Failed card payments',
                '${_asInt(riderPay['failed_card_payments'])}',
              ),
              _metricRow(
                'Pending bank transfer confirmations',
                '${_asInt(riderPay['pending_bank_transfer_confirmations'])}',
              ),
              _metricRow(
                'Unpaid rider trips/orders',
                '${_asInt(riderPay['unpaid_rider_trips_orders'])}',
              ),
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  'Riders pay by linked card or bank transfer only — no rider wallets or withdrawals.',
                  style: TextStyle(fontSize: 12, color: Color(0xFF736C61)),
                ),
              ),
              _metricRow('Pending verifications', '${_asInt(ver['pending'])}'),
              _metricRow('Open support tickets', '${_asInt(support['open'])}'),
              _metricRow(
                'Service area warnings',
                '${_asInt(svc['missing_geo']) + _asInt(svc['missing_dispatch_market_id']) + _asInt(svc['disabled_active_area'])}',
              ),
              _metricRow(
                'Payout destination warnings',
                '${_asInt(payout['driver_withdrawal_missing_destination']) + _asInt(payout['merchant_withdrawal_missing_destination'])}',
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_fatalError != null) {
      return _buildErrorCard(_fatalError!);
    }
    if (_loading && _snapshot.isEmpty) {
      return const AdminSurfaceCard(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2.6),
              ),
              SizedBox(width: 16),
              Text(
                'Loading system health…',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AdminThemeTokens.ink,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return _buildContent();
  }
}

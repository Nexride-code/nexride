import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../admin_config.dart';
import '../services/admin_data_service.dart';
import '../utils/admin_formatters.dart';
import 'admin_components.dart';

/// Detail table for a System Health card (`adminGetHealthDrilldown`).
class AdminHealthDrilldownPanel extends StatefulWidget {
  const AdminHealthDrilldownPanel({
    super.key,
    required this.dataService,
    required this.cardId,
    required this.cardTitle,
    this.statusFilter = 'all',
    this.infrastructureSubsystems,
    this.onNavigate,
    this.onSnapshotRefresh,
  });

  final AdminDataService dataService;
  final String cardId;
  final String cardTitle;
  final String statusFilter;
  final Map<String, dynamic>? infrastructureSubsystems;
  final Future<void> Function(String action, Map<String, dynamic> row)? onNavigate;
  final VoidCallback? onSnapshotRefresh;

  @override
  State<AdminHealthDrilldownPanel> createState() =>
      _AdminHealthDrilldownPanelState();
}

class _AdminHealthDrilldownPanelState extends State<AdminHealthDrilldownPanel> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _rows = <Map<String, dynamic>>[];
  String _filter = 'all';
  int _offset = 0;
  bool _hasMore = false;
  int _totalScanned = 0;
  int _rowsReturned = 0;
  final Set<String> _busyActions = <String>{};

  @override
  void initState() {
    super.initState();
    _filter = widget.statusFilter;
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant AdminHealthDrilldownPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cardId != widget.cardId ||
        oldWidget.statusFilter != widget.statusFilter) {
      _filter = widget.statusFilter;
      unawaited(_load());
    }
  }

  Map<String, dynamic> _mapOf(Object? raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return <String, dynamic>{};
  }

  List<Map<String, dynamic>> _listOfMaps(Object? raw) {
    if (raw is! List) return <Map<String, dynamic>>[];
    return raw
        .map((dynamic e) => _mapOf(e))
        .where((Map<String, dynamic> m) => m.isNotEmpty)
        .toList();
  }

  Future<void> _load({bool loadMore = false}) async {
    final int nextOffset = loadMore ? _offset : 0;
    if (!loadMore) {
      setState(() {
        _loading = true;
        _error = null;
        _offset = 0;
      });
    }
    try {
      final raw = await widget.dataService.adminGetHealthDrilldown(
        card: widget.cardId,
        statusFilter: _filter,
        limit: widget.cardId == 'matching' ? 50 : 40,
        offset: widget.cardId == 'matching' ? nextOffset : 0,
        infrastructureSubsystems: widget.infrastructureSubsystems,
      );
      if (!mounted) return;
      if (raw['success'] != true) {
        setState(() {
          _error = raw['reason']?.toString() ?? 'load_failed';
          _rows = <Map<String, dynamic>>[];
          _loading = false;
        });
        return;
      }
      var rows = _listOfMaps(raw['rows']);
      if (widget.cardId == 'matching') {
        rows.sort((Map<String, dynamic> a, Map<String, dynamic> b) {
          final Map<String, dynamic> fa = _mapOf(a['fields']);
          final Map<String, dynamic> fb = _mapOf(b['fields']);
          final bool sa = fa['is_stale_search'] == true;
          final bool sb = fb['is_stale_search'] == true;
          if (sa != sb) {
            return sa ? 1 : -1;
          }
          final int ca = int.tryParse('${fa['created_at_ms'] ?? 0}') ?? 0;
          final int cb = int.tryParse('${fb['created_at_ms'] ?? 0}') ?? 0;
          return cb.compareTo(ca);
        });
      }
      setState(() {
        if (loadMore && widget.cardId == 'matching') {
          _rows = <Map<String, dynamic>>[..._rows, ...rows];
        } else {
          _rows = rows;
        }
        _offset = int.tryParse('${raw['next_offset'] ?? nextOffset}') ?? nextOffset;
        _hasMore = raw['has_more'] == true;
        _totalScanned = int.tryParse('${raw['total_scanned'] ?? 0}') ?? 0;
        _rowsReturned = int.tryParse('${raw['rows_returned'] ?? rows.length}') ??
            rows.length;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
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

  String _explainRow(Map<String, dynamic> row) {
    final String reason = row['reason']?.toString() ?? '';
    final String action = row['action_needed']?.toString() ?? '';
    final String rec = row['recommended_action']?.toString() ?? '';
    final Map<String, dynamic> fields = _mapOf(row['fields']);
    final String entity = '${row['entity_type'] ?? ''} ${row['entity_id'] ?? ''}'
        .trim();
    return [
      if (entity.isNotEmpty) 'Affected: $entity.',
      if (reason.isNotEmpty) 'Issue: $reason.',
      if (action.isNotEmpty) 'Action needed: $action.',
      if (rec.isNotEmpty) 'Recommended: $rec.',
      if (fields.isNotEmpty) 'Fields: ${fields.entries.take(6).map((e) => '${e.key}=${e.value}').join(', ')}.',
    ].join(' ');
  }

  Future<void> _copy(String? text) async {
    final String v = text?.trim() ?? '';
    if (v.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: v));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Copied: $v')),
    );
  }

  Future<void> _runAction(Map<String, dynamic> row, String action) async {
    final String key = '${row['row_id']}_$action';
    if (_busyActions.contains(key)) return;
    setState(() => _busyActions.add(key));
    try {
      final Map<String, dynamic> fields = _mapOf(row['fields']);
      Map<String, dynamic> res = <String, dynamic>{};
      switch (action) {
        case 'retry_verify':
          res = await widget.dataService.adminRetryPaymentVerify(
            txRef: fields['tx_ref']?.toString(),
          );
        case 'expire_payment_intent':
          res = await widget.dataService.adminExpirePaymentIntent(
            txRef: fields['tx_ref']?.toString(),
          );
        case 'repair_dispatch_blockers':
          final String? repairRideId =
              fields['ride_id']?.toString() ?? row['entity_id']?.toString();
          res = await widget.dataService.adminRepairDispatchBlockers(
            rideId: repairRideId,
          );
        case 'expire_leases':
          final String? expireRideId =
              fields['ride_id']?.toString() ?? row['entity_id']?.toString();
          res = await widget.dataService.adminExpireRideLeases(
            rideId: expireRideId,
          );
        case 'kill_orchestration_lease':
        case 'invalidate_dispatch_generation':
        case 'replay_fanout':
        case 'rebuild_dispatch_metrics':
        case 'rebuild_dispatch_snapshot':
        case 'requeue_dispatch_work':
        case 'view_dead_letters':
          final String? orchRideId =
              fields['ride_id']?.toString() ?? row['entity_id']?.toString();
          final String orchAction = switch (action) {
            'invalidate_dispatch_generation' => 'invalidate_generation',
            'rebuild_dispatch_metrics' => 'rebuild_metrics',
            'rebuild_dispatch_snapshot' => 'rebuild_snapshot',
            'requeue_dispatch_work' => 'requeue_work',
            'view_dead_letters' => 'list_dead_letters',
            'kill_orchestration_lease' => 'kill_orchestration_lease',
            _ => 'replay_fanout',
          };
          res = await widget.dataService.adminOrchestratorAction(
            action: orchAction,
            rideId: orchRideId,
            queue: action == 'requeue_dispatch_work' ? 'matching' : null,
          );
        case 'rerun_matching':
          final String? rideId =
              fields['ride_id']?.toString() ?? row['entity_id']?.toString();
          res = await widget.dataService.adminRerunRideMatching(rideId: rideId);
        case 'rerun_delivery_matching':
          res = await widget.dataService.adminRerunDeliveryMatching(
            deliveryId:
                fields['delivery_id']?.toString() ?? row['entity_id']?.toString(),
          );
        case 'cancel_stale_search':
          res = await widget.dataService.adminCancelStaleRideSearch(
            rideId: fields['ride_id']?.toString() ?? row['entity_id']?.toString(),
          );
        case 'clear_stale_active_ride':
          res = await widget.dataService.adminClearDriverStaleActiveRide(
            driverId:
                fields['driver_id']?.toString() ?? row['entity_id']?.toString(),
          );
        case 'mark_offline':
          res = await widget.dataService.adminForceDriverOffline(
            driverId:
                fields['driver_id']?.toString() ?? row['entity_id']?.toString(),
            reason: 'admin_health_drilldown',
          );
        case 'copy_tx_ref':
          await _copy(fields['tx_ref']?.toString());
          return;
        case 'copy_ride_id':
          await _copy(
            fields['ride_id']?.toString() ?? row['entity_id']?.toString(),
          );
          return;
        case 'copy_webhook_url':
          await _copy(fields['webhook_url']?.toString());
          return;
        case 'open_trip':
        case 'open_delivery_chat':
        case 'open_payment_intent':
        case 'open_driver_profile':
        case 'open_rider_profile':
        case 'open_withdrawals':
        case 'open_support':
        case 'open_verification':
        case 'open_merchant_profile':
        case 'open_payment_diagnostics':
        case 'seed_rollout_regions':
        case 'enable_disable_city':
        case 'edit_dispatch_market':
        case 'cancel_stale_delivery':
        case 'view_location_mode':
        case 'inspect_driver_offer_queue':
          if (widget.onNavigate != null) {
            await widget.onNavigate!(action, row);
            return;
          }
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Navigate: $action (wire onNavigate)')),
          );
          return;
        default:
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Action not wired: $action')),
          );
          return;
      }
      if (!mounted) return;
      final bool ok = res['success'] == true;
      String message;
      if (action == 'repair_dispatch_blockers' && ok) {
        message =
            'Repaired ${res['cleared_total'] ?? 0} driver(s); '
            'offers_written=${res['offers_written'] ?? 0}; '
            'eligible=${res['eligible_driver_count'] ?? 0}';
      } else {
        message = ok
            ? 'Done: ${res['reason'] ?? action}'
            : 'Failed: ${res['reason'] ?? 'unknown'}';
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
      if (ok) {
        if (widget.cardId == 'matching' &&
            (action == 'repair_dispatch_blockers' ||
                action == 'expire_leases' ||
                action == 'kill_orchestration_lease' ||
                action == 'invalidate_dispatch_generation' ||
                action == 'replay_fanout' ||
                action == 'rebuild_dispatch_metrics' ||
                action == 'rerun_matching' ||
                action == 'cancel_stale_search' ||
                action == 'rerun_delivery_matching' ||
                action == 'cancel_stale_delivery')) {
          widget.onSnapshotRefresh?.call();
        }
        await _load();
      }
    } finally {
      if (mounted) setState(() => _busyActions.remove(key));
    }
  }

  Widget _chip(String label, String status) {
    final Color c = _statusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.withValues(alpha: 0.35)),
      ),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w800,
          color: c,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AdminSurfaceCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '${widget.cardTitle} — detail',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: AdminThemeTokens.ink,
                  ),
                ),
              ),
              DropdownButton<String>(
                value: _filter,
                items: <DropdownMenuItem<String>>[
                  const DropdownMenuItem(value: 'all', child: Text('All')),
                  const DropdownMenuItem(value: 'red', child: Text('Red')),
                  const DropdownMenuItem(value: 'yellow', child: Text('Yellow')),
                  const DropdownMenuItem(value: 'green', child: Text('Green')),
                  if (widget.cardId == 'matching')
                    const DropdownMenuItem(
                      value: 'stale',
                      child: Text('Stale searches'),
                    ),
                ],
                onChanged: _loading
                    ? null
                    : (String? v) {
                        if (v == null) return;
                        setState(() => _filter = v);
                        unawaited(_load());
                      },
              ),
              IconButton(
                onPressed: _loading ? null : () => unawaited(_load()),
                icon: const Icon(Icons.refresh_rounded),
                tooltip: 'Refresh drill-down',
              ),
            ],
          ),
          if (widget.cardId == 'matching' && !_loading && _error == null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Showing ${_rows.length} row(s) · scanned $_totalScanned · '
                'page returned $_rowsReturned',
                style: const TextStyle(
                  fontSize: 11,
                  color: AdminThemeTokens.slate,
                ),
              ),
            ),
          const SizedBox(height: 8),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else if (_error != null)
            SelectableText(_error!, style: const TextStyle(color: AdminThemeTokens.danger))
          else if (_rows.isEmpty)
            const Text(
              'No rows for this filter.',
              style: TextStyle(color: AdminThemeTokens.slate),
            )
          else
            ..._rows.asMap().entries.expand((MapEntry<int, Map<String, dynamic>> entry) {
              final Map<String, dynamic> row = entry.value;
              final Map<String, dynamic> fields = _mapOf(row['fields']);
              final bool isStale = fields['is_stale_search'] == true;
              final bool prevStale = entry.key > 0 &&
                  _mapOf(_rows[entry.key - 1]['fields'])['is_stale_search'] == true;
              final List<Widget> out = <Widget>[];
              if (widget.cardId == 'matching' &&
                  isStale &&
                  !prevStale &&
                  _filter == 'all') {
                out.add(
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8, top: 4),
                    child: Text(
                      'Stale searches (>45 min)',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: AdminThemeTokens.slate,
                      ),
                    ),
                  ),
                );
              }
              final String status = row['status']?.toString() ?? 'yellow';
              final List<String> actions = (row['actions'] is List)
                  ? (row['actions'] as List).map((dynamic e) => '$e').toList()
                  : <String>[];
              out.add(Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.all(color: const Color(0xFFE8E2D8)),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        _chip(status, status),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            row['reason']?.toString() ?? '—',
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      row['action_needed']?.toString() ?? '',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AdminThemeTokens.slate,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${row['entity_type'] ?? ''} · ${row['entity_id'] ?? '—'}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    const SizedBox(height: 8),
                    ...fields.entries.take(22).map(
                          (MapEntry<String, dynamic> e) => Padding(
                            padding: const EdgeInsets.only(bottom: 2),
                            child: Text(
                              '${e.key}: ${e.value}',
                              style: const TextStyle(fontSize: 11, height: 1.3),
                            ),
                          ),
                        ),
                    if (fields['expires_at_ms'] != null)
                      Text(
                        'expires: ${formatAdminDateTime(DateTime.fromMillisecondsSinceEpoch(int.tryParse('${fields['expires_at_ms']}') ?? 0))}',
                        style: const TextStyle(fontSize: 11),
                      ),
                    const SizedBox(height: 8),
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: const Text(
                        'Explain issue (preview)',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                      children: <Widget>[
                        SelectableText(
                          _explainRow(row),
                          style: const TextStyle(fontSize: 12, height: 1.4),
                        ),
                      ],
                    ),
                    if (actions.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: actions.map((String action) {
                          final String key = '${row['row_id']}_$action';
                          final bool busy = _busyActions.contains(key);
                          return OutlinedButton(
                            onPressed: busy
                                ? null
                                : () => unawaited(_runAction(row, action)),
                            child: busy
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : Text(
                                    action.replaceAll('_', ' '),
                                    style: const TextStyle(fontSize: 11),
                                  ),
                          );
                        }).toList(),
                      ),
                    ],
                  ],
                ),
              ));
              return out;
            }),
          if (widget.cardId == 'matching' && _hasMore && !_loading)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: OutlinedButton(
                onPressed: () => unawaited(_load(loadMore: true)),
                child: const Text('Show more'),
              ),
            ),
        ],
      ),
    );
  }
}

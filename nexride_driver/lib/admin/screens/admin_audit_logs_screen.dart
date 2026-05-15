import 'dart:async' show unawaited;

import 'package:flutter/material.dart';

import '../admin_config.dart';
import '../services/admin_data_service.dart';
import '../utils/admin_callable_feedback.dart';
import '../utils/admin_formatters.dart';
import '../widgets/admin_components.dart';

/// Server-backed audit log viewer (`adminListAuditLogs`).
///
/// Laid out for hosting inside [AdminPanelScreen]'s vertical [SingleChildScrollView]:
/// use [MainAxisSize.min] on [Column]s, no [Center] / [Expanded] / nested vertical scroll,
/// and [ListView] with [shrinkWrap] + [NeverScrollableScrollPhysics].
class AdminAuditLogsScreen extends StatefulWidget {
  const AdminAuditLogsScreen({
    required this.dataService,
    super.key,
  });

  final AdminDataService dataService;

  @override
  State<AdminAuditLogsScreen> createState() => _AdminAuditLogsScreenState();
}

class _AdminAuditLogsScreenState extends State<AdminAuditLogsScreen> {
  final TextEditingController _actionCtrl = TextEditingController();
  final TextEditingController _entityTypeCtrl = TextEditingController();
  final TextEditingController _actorEmailCtrl = TextEditingController();
  DateTimeRange? _range;

  bool _loading = true;
  String? _fatalError;
  List<Map<String, dynamic>> _logs = const <Map<String, dynamic>>[];

  Map<String, dynamic> _mapOf(dynamic raw) {
    try {
      if (raw == null) {
        return const <String, dynamic>{};
      }
      if (raw is Map<String, dynamic>) {
        return raw;
      }
      if (raw is Map) {
        return Map<String, dynamic>.from(raw);
      }
    } catch (e, st) {
      debugPrint('[AUDIT_LOGS][SCREEN] _mapOf failed: $e\n$st');
    }
    return const <String, dynamic>{};
  }

  List<Map<String, dynamic>> _listOfMaps(dynamic raw) {
    try {
      if (raw == null) {
        return const <Map<String, dynamic>>[];
      }
      if (raw is! List) {
        return const <Map<String, dynamic>>[];
      }
      final out = <Map<String, dynamic>>[];
      for (final dynamic e in raw) {
        final m = _mapOf(e);
        if (m.isNotEmpty) {
          out.add(m);
        }
      }
      return out;
    } catch (e, st) {
      debugPrint('[AUDIT_LOGS][SCREEN] _listOfMaps failed: $e\n$st');
      return const <Map<String, dynamic>>[];
    }
  }

  String _text(dynamic v) {
    if (v == null) {
      return '';
    }
    return v.toString();
  }

  int _intMs(dynamic v) {
    if (v is int) {
      return v;
    }
    if (v is num) {
      return v.toInt();
    }
    return int.tryParse(_text(v)) ?? 0;
  }

  Future<void> _load() async {
    debugPrint('[AUDIT_LOGS][SCREEN] load start');
    if (!mounted) {
      return;
    }
    setState(() {
      _loading = true;
      _fatalError = null;
    });
    try {
      final Map<String, dynamic> data = _mapOf(
        await widget.dataService.adminListAuditLogs(
          limit: 250,
          action:
              _actionCtrl.text.trim().isEmpty ? null : _actionCtrl.text.trim(),
          entityType: _entityTypeCtrl.text.trim().isEmpty
              ? null
              : _entityTypeCtrl.text.trim(),
          actorEmail: _actorEmailCtrl.text.trim().isEmpty
              ? null
              : _actorEmailCtrl.text.trim(),
          fromMs: _range?.start.millisecondsSinceEpoch,
          toMs: _range?.end.millisecondsSinceEpoch,
        ),
      );

      if (data['success'] != true) {
        throw StateError(adminCallableFailureMessage(data));
      }

      final list = _listOfMaps(data['logs']);
      if (!mounted) {
        return;
      }
      setState(() {
        _logs = list;
        _loading = false;
        _fatalError = null;
      });
      debugPrint('[AUDIT_LOGS][SCREEN] success count=${list.length}');
    } catch (e, st) {
      debugPrint('[AUDIT_LOGS][SCREEN] error $e\n$st');
      if (!mounted) {
        return;
      }
      setState(() {
        _fatalError = e.toString();
        _loading = false;
      });
    }
  }

  String _preview(dynamic v) {
    if (v == null) {
      return '—';
    }
    final s = v.toString();
    return s.length > 120 ? '${s.substring(0, 117)}…' : s;
  }

  @override
  void initState() {
    super.initState();
    debugPrint('[AUDIT_LOGS][SCREEN] init/load');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_load());
    });
  }

  @override
  void dispose() {
    debugPrint('[AUDIT_LOGS][SCREEN] dispose');
    _actionCtrl.dispose();
    _entityTypeCtrl.dispose();
    _actorEmailCtrl.dispose();
    super.dispose();
  }

  Widget _buildLoading() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const <Widget>[
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2.6),
              ),
              SizedBox(width: 16),
              Text(
                'Loading audit logs…',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AdminThemeTokens.ink,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildErrorCard(String message) {
    return AdminSurfaceCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.error_outline_rounded, color: AdminThemeTokens.danger),
              SizedBox(width: 10),
              Text(
                'Could not load audit logs',
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
            onPressed: _loading
                ? null
                : () {
                    debugPrint('[AUDIT_LOGS][SCREEN] retry');
                    unawaited(_load());
                  },
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    return AdminSurfaceCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const <Widget>[
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.inbox_outlined, color: AdminThemeTokens.gold),
              SizedBox(width: 12),
              Text(
                'No rows',
                style: TextStyle(
                  color: AdminThemeTokens.ink,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          SizedBox(height: 10),
          Text(
            'Try widening filters or clearing the date range.',
            style: TextStyle(
              color: Color(0xFF736C61),
              fontSize: 14,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBodyContent() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            'Immutable record of privileged admin actions (warns, suspensions, '
            'withdrawals, verification, service areas, merchants).',
            style: TextStyle(
              color: AdminThemeTokens.slate,
              fontSize: 13,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              SizedBox(
                width: 200,
                child: TextField(
                  controller: _actionCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Action contains',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              SizedBox(
                width: 180,
                child: TextField(
                  controller: _entityTypeCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Entity type',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              SizedBox(
                width: 220,
                child: TextField(
                  controller: _actorEmailCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Admin email contains',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              OutlinedButton.icon(
                onPressed: () async {
                  final DateTimeRange? picked = await showDateRangePicker(
                    context: context,
                    firstDate: DateTime(2023),
                    lastDate: DateTime.now().add(const Duration(days: 1)),
                    initialDateRange: _range,
                  );
                  if (picked != null && mounted) {
                    setState(() => _range = picked);
                  }
                },
                icon: const Icon(Icons.date_range_outlined),
                label: Text(
                  _range == null
                      ? 'Date range'
                      : '${_range!.start.toLocal().toIso8601String().split('T').first} '
                          '→ ${_range!.end.toLocal().toIso8601String().split('T').first}',
                ),
              ),
              if (_range != null)
                TextButton(
                  onPressed: () => setState(() => _range = null),
                  child: const Text('Clear range'),
                ),
              FilledButton.icon(
                onPressed: _loading ? null : () => unawaited(_load()),
                icon: _loading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.search_rounded),
                label: const Text('Apply filters'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          if (_fatalError != null)
            _buildErrorCard(_fatalError!)
          else if (_loading)
            _buildLoading()
          else if (_logs.isEmpty)
            _buildEmpty()
          else
            AdminSurfaceCard(
              padding: const EdgeInsets.all(12),
              child: ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _logs.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (BuildContext context, int i) {
                  try {
                    final Map<String, dynamic> r = _mapOf(_logs[i]);
                    final int ts = _intMs(r['created_at']);
                    final DateTime? dt =
                        ts > 0 ? DateTime.fromMillisecondsSinceEpoch(ts) : null;
                    return ExpansionTile(
                      tilePadding: const EdgeInsets.symmetric(horizontal: 8),
                      title: Text(
                        '${r['action'] ?? r['type'] ?? 'event'} · '
                        '${r['entity_type'] ?? '—'} · ${r['entity_id'] ?? '—'}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                      subtitle: Text(
                        '${r['actor_email'] ?? r['actor_uid'] ?? '—'} · '
                        '${dt != null ? formatAdminDateTime(dt) : '—'}',
                        style: const TextStyle(fontSize: 12),
                      ),
                      children: <Widget>[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              _kv('Source', r['source']),
                              _kv('Reason', r['reason']),
                              _kv('Before', _preview(r['before'])),
                              _kv('After', _preview(r['after'])),
                            ],
                          ),
                        ),
                      ],
                    );
                  } catch (e, st) {
                    debugPrint('[AUDIT_LOGS][SCREEN] row $i failed: $e\n$st');
                    return ListTile(
                      dense: true,
                      title: Text(
                        'Row $i (unreadable)',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                      subtitle: Text('$e', style: const TextStyle(fontSize: 11)),
                    );
                  }
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _kv(String k, dynamic v) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: SelectableText(
        '$k: ${_preview(v)}',
        style: const TextStyle(fontSize: 12, height: 1.35),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    debugPrint(
      '[AUDIT_LOGS][SCREEN] build loading=$_loading fatal=${_fatalError != null}',
    );

    if (_loading && _fatalError == null) {
      return Align(alignment: Alignment.topLeft, child: _buildLoading());
    }

    try {
      return Align(
        alignment: Alignment.topLeft,
        child: _buildBodyContent(),
      );
    } catch (e, st) {
      debugPrint('[AUDIT_LOGS][SCREEN] build error $e\n$st');
      return Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: SelectableText(
                'Layout error: $e',
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ),
        ),
      );
    }
  }
}

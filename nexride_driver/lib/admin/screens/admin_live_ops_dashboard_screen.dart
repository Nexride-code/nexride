import 'dart:async' show Timer, unawaited;

import 'package:flutter/material.dart';

import '../admin_config.dart';
import '../models/admin_models.dart';
import '../services/admin_data_service.dart';
import '../widgets/admin_components.dart';

/// Single-callable live operations overview (`adminGetLiveOperationsDashboard`).
///
/// **Layout:** This widget is hosted inside [AdminPanelScreen]'s vertical
/// [SingleChildScrollView], so every [Column] must use [MainAxisSize.min] to
/// avoid "unbounded height" [RenderFlex] assertions (blank white page on web).
class AdminLiveOpsDashboardScreen extends StatefulWidget {
  const AdminLiveOpsDashboardScreen({super.key, required this.dataService});

  final AdminDataService dataService;

  @override
  State<AdminLiveOpsDashboardScreen> createState() =>
      _AdminLiveOpsDashboardScreenState();
}

class _ParsedLiveOpsSection {
  const _ParsedLiveOpsSection({
    required this.map,
    required this.sample,
    this.parseNote,
  });

  final Map<String, dynamic> map;
  final List<Map<String, dynamic>> sample;
  final String? parseNote;
}

class _AdminLiveOpsDashboardScreenState extends State<AdminLiveOpsDashboardScreen> {
  static const Duration _pollInterval = Duration(seconds: 15);

  bool _loading = true;
  String? _fatalError;
  String? _parseWarning;
  Map<String, dynamic> _payload = const <String, dynamic>{};
  Timer? _timer;
  int _fetchGeneration = 0;

  @override
  void initState() {
    super.initState();
    debugPrint('[LIVE_OPS] initState mounted=$mounted');
    unawaited(_load(trigger: 'initState'));
    _timer = Timer.periodic(_pollInterval, (_) {
      if (!mounted) {
        debugPrint('[LIVE_OPS] timer tick skipped (disposed)');
        return;
      }
      debugPrint('[LIVE_OPS] timer refresh');
      unawaited(_load(trigger: 'timer'));
    });
  }

  @override
  void dispose() {
    debugPrint('[LIVE_OPS] dispose cancel timer');
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  Map<String, dynamic> _mapOf(Object? raw) {
    try {
      if (raw == null) {
        return <String, dynamic>{};
      }
      if (raw is Map<String, dynamic>) {
        return raw;
      }
      if (raw is Map) {
        return Map<String, dynamic>.from(raw);
      }
    } catch (e, st) {
      debugPrint('[LIVE_OPS] _mapOf failed: $e\n$st');
    }
    return <String, dynamic>{};
  }

  List<Map<String, dynamic>> _listOfMaps(Object? raw) {
    try {
      if (raw == null) {
        return <Map<String, dynamic>>[];
      }
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
    } catch (e, st) {
      debugPrint('[LIVE_OPS] _listOfMaps failed: $e\n$st');
      return <Map<String, dynamic>>[];
    }
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

  String _asString(Object? v) {
    if (v == null) {
      return '';
    }
    return v.toString();
  }

  _ParsedLiveOpsSection _parseSection(String name, Object? raw) {
    try {
      final map = _mapOf(raw);
      final sample = _listOfMaps(map['sample']);
      return _ParsedLiveOpsSection(map: map, sample: sample);
    } catch (e, st) {
      debugPrint('[LIVE_OPS] parse section $name failed: $e\n$st');
      return _ParsedLiveOpsSection(
        map: <String, dynamic>{},
        sample: <Map<String, dynamic>>[],
        parseNote: '$name: $e',
      );
    }
  }

  List<Map<String, dynamic>> _parseAlerts(Object? raw) {
    try {
      return _listOfMaps(raw);
    } catch (e, st) {
      debugPrint('[LIVE_OPS] parse alerts failed: $e\n$st');
      return <Map<String, dynamic>>[];
    }
  }

  Future<void> _load({required String trigger}) async {
    final int gen = ++_fetchGeneration;
    debugPrint('[LIVE_OPS] _load start trigger=$trigger gen=$gen mounted=$mounted');

    if (!mounted) {
      return;
    }

    if (_loading) {
      if (!mounted) {
        return;
      }
      setState(() {
        _fatalError = null;
        _parseWarning = null;
      });
    }

    try {
      debugPrint('[LIVE_OPS] calling adminGetLiveOperationsDashboard…');
      final Map<String, dynamic> raw =
          await widget.dataService.adminGetLiveOperationsDashboard();
      debugPrint('[LIVE_OPS] raw result type=${raw.runtimeType} gen=$gen');

      if (!mounted || gen != _fetchGeneration) {
        debugPrint('[LIVE_OPS] stale response ignored gen=$gen current=$_fetchGeneration');
        return;
      }

      Map<String, dynamic> data;
      try {
        data = _mapOf(raw);
      } catch (e, st) {
        debugPrint('[LIVE_OPS] envelope map cast failed: $e\n$st');
        throw StateError('Invalid response shape (not a map).');
      }

      if (data['success'] != true) {
        final reason = _asString(data['reason']).trim().isEmpty
            ? 'live_ops_failed'
            : _asString(data['reason']);
        throw StateError(reason);
      }

      if (!mounted || gen != _fetchGeneration) {
        return;
      }

      setState(() {
        _payload = data;
        _loading = false;
        _fatalError = null;
        _parseWarning = null;
      });
      debugPrint('[LIVE_OPS] _load success gen=$gen keys=${data.keys.toList()}');
    } catch (e, st) {
      debugPrint('[LIVE_OPS] _load FAILED: $e\n$st');
      if (!mounted || gen != _fetchGeneration) {
        return;
      }
      setState(() {
        _loading = false;
        _fatalError = e.toString();
      });
    }
  }

  Widget _buildLoading() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
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
                'Loading live operations…',
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

  Widget _buildFatalError() {
    final String msg = _fatalError ?? 'Unknown error';
    return Padding(
      padding: const EdgeInsets.all(24),
      child: AdminSurfaceCard(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Row(
              children: <Widget>[
                Icon(Icons.error_outline_rounded, color: AdminThemeTokens.danger),
                SizedBox(width: 10),
                Text(
                  'Live operations failed to load',
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
              msg,
              style: const TextStyle(fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () {
                if (!mounted) {
                  return;
                }
                debugPrint('[LIVE_OPS] retry pressed');
                setState(() {
                  _loading = true;
                  _fatalError = null;
                });
                unawaited(_load(trigger: 'retry'));
              },
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    debugPrint(
      '[LIVE_OPS] build loading=$_loading fatal=${_fatalError != null} mounted=$mounted',
    );

    if (_loading) {
      return Align(alignment: Alignment.topLeft, child: _buildLoading());
    }
    if (_fatalError != null) {
      return Align(alignment: Alignment.topLeft, child: _buildFatalError());
    }

    Widget body;
    try {
      body = _buildDashboardContent(context);
    } catch (e, st) {
      debugPrint('[LIVE_OPS] build dashboard content crashed: $e\n$st');
      body = Padding(
        padding: const EdgeInsets.all(16),
        child: AdminSurfaceCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                'Dashboard layout error',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
              ),
              const SizedBox(height: 8),
              SelectableText('$e'),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () {
                  if (!mounted) {
                    return;
                  }
                  setState(() {
                    _loading = true;
                    _fatalError = null;
                  });
                  unawaited(_load(trigger: 'retry_after_build_crash'));
                },
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    return Align(
      alignment: Alignment.topLeft,
      child: body,
    );
  }

  Widget _buildDashboardContent(BuildContext context) {
    _ParsedLiveOpsSection driversSec;
    _ParsedLiveOpsSection ridesSec;
    _ParsedLiveOpsSection merchantsSec;
    _ParsedLiveOpsSection moSec;
    List<Map<String, dynamic>> alerts;

    try {
      driversSec = _parseSection('drivers', _payload['drivers']);
      ridesSec = _parseSection('rides', _payload['rides']);
      merchantsSec = _parseSection('merchants', _payload['merchants']);
      moSec = _parseSection('merchant_orders', _payload['merchant_orders']);
      alerts = _parseAlerts(_payload['alerts']);
    } catch (e, st) {
      debugPrint('[LIVE_OPS] parse all sections failed: $e\n$st');
      driversSec = const _ParsedLiveOpsSection(map: {}, sample: []);
      ridesSec = const _ParsedLiveOpsSection(map: {}, sample: []);
      merchantsSec = const _ParsedLiveOpsSection(map: {}, sample: []);
      moSec = const _ParsedLiveOpsSection(map: {}, sample: []);
      alerts = <Map<String, dynamic>>[];
    }

    final notes = <String>[
      if (_parseWarning != null) _parseWarning!,
      if (driversSec.parseNote != null) driversSec.parseNote!,
      if (ridesSec.parseNote != null) ridesSec.parseNote!,
      if (merchantsSec.parseNote != null) merchantsSec.parseNote!,
      if (moSec.parseNote != null) moSec.parseNote!,
    ];

    final drivers = driversSec.map;
    final rides = ridesSec.map;
    final merchants = merchantsSec.map;
    final mo = moSec.map;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        Widget sectionOrPlaceholder(String title, Widget Function() fn) {
          try {
            return fn();
          } catch (e, st) {
            debugPrint('[LIVE_OPS] section "$title" failed: $e\n$st');
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                '$title: section error — $e',
                style: const TextStyle(color: AdminThemeTokens.danger, fontSize: 13),
              ),
            );
          }
        }

        return Padding(
          padding: const EdgeInsets.only(bottom: 32),
          child: Align(
            alignment: Alignment.topLeft,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: c.maxWidth < 900 ? double.infinity : 1200,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    if (notes.isNotEmpty) ...<Widget>[
                      ...notes.map(
                        (String n) => Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            n,
                            style: const TextStyle(
                              color: AdminThemeTokens.warning,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                    ],
                    sectionOrPlaceholder(
                      'header',
                      () => AdminSectionHeader(
                        title: 'Live operations',
                        description:
                            'Unified view of drivers, rides, merchants, and alerts '
                            '(auto-refresh every ${_pollInterval.inSeconds}s).',
                        trailing: FilledButton.icon(
                          onPressed: () {
                            if (!mounted) {
                              return;
                            }
                            debugPrint('[LIVE_OPS] manual refresh');
                            setState(() {
                              _loading = true;
                              _fatalError = null;
                            });
                            unawaited(_load(trigger: 'refresh_button'));
                          },
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text('Refresh'),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    sectionOrPlaceholder(
                      'metrics',
                      () => Wrap(
                        spacing: 16,
                        runSpacing: 16,
                        children: <Widget>[
                          _metric(
                            'Drivers online',
                            _asInt(drivers['online']),
                            'Idle: ${_asInt(drivers['idle_online'])} · busy trip: ${_asInt(drivers['active_trip'])}',
                            Icons.badge_outlined,
                          ),
                          _metric(
                            'Stale heartbeats',
                            _asInt(drivers['stale_heartbeat']),
                            'Online but RTDB / mirror heartbeat old',
                            Icons.signal_wifi_off_outlined,
                          ),
                          _metric(
                            'Active rides',
                            _asInt(rides['active']),
                            'In-flight ride + delivery rows',
                            Icons.route_outlined,
                          ),
                          _metric(
                            'Unmatched >60s',
                            _asInt(rides['unmatched_over_60s']),
                            'Searching pool · ${_asInt(rides['no_driver_recent'])} fresh',
                            Icons.hourglass_top_outlined,
                          ),
                          _metric(
                            'Open merchants',
                            _asInt(merchants['open']),
                            'Of ${_asInt(merchants['total'])} total (recent scan)',
                            Icons.storefront_outlined,
                          ),
                          _metric(
                            'Live merchant orders',
                            _asInt(mo['active']),
                            'Non-terminal in capped query',
                            Icons.receipt_long_outlined,
                          ),
                          _metric(
                            'Alerts',
                            alerts.length,
                            'Computed server-side',
                            Icons.notifications_active_outlined,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 28),
                    sectionOrPlaceholder(
                      'stale_drivers',
                      () => _sectionTitle('Stale driver heartbeats'),
                    ),
                    sectionOrPlaceholder(
                      'stale_drivers_table',
                      () => _tableOrEmpty(
                        driversSec.sample,
                        <String>['driver_id', 'name', 'age_s', 'market'],
                        (Map<String, dynamic> r) => <String>[
                          _asString(r['driver_id']).isEmpty ? '—' : _asString(r['driver_id']),
                          _asString(r['name']).isEmpty ? '—' : _asString(r['name']),
                          _asString(r['age_seconds']).isEmpty ? '—' : _asString(r['age_seconds']),
                          _asString(r['market']).isEmpty ? '—' : _asString(r['market']),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    sectionOrPlaceholder('unmatched_title', () => _sectionTitle('Unmatched / searching rides')),
                    sectionOrPlaceholder(
                      'unmatched_table',
                      () => _tableOrEmpty(
                        ridesSec.sample,
                        <String>['id', 'kind', 'bucket', 'region'],
                        (Map<String, dynamic> r) => <String>[
                          _asString(r['trip_id']).isEmpty ? '—' : _asString(r['trip_id']),
                          _asString(r['trip_kind']).isEmpty ? '—' : _asString(r['trip_kind']),
                          _asString(r['ui_bucket']).isEmpty ? '—' : _asString(r['ui_bucket']),
                          _asString(r['region']).isEmpty ? '—' : _asString(r['region']),
                        ],
                        filter: (Map<String, dynamic> r) => _asString(r['ui_bucket']) == 'searching',
                      ),
                    ),
                    const SizedBox(height: 24),
                    sectionOrPlaceholder('active_title', () => _sectionTitle('Active rides & deliveries (sample)')),
                    sectionOrPlaceholder(
                      'active_table',
                      () => _tableOrEmpty(
                        ridesSec.sample,
                        <String>['id', 'kind', 'bucket', 'driver', 'updated'],
                        (Map<String, dynamic> r) => <String>[
                          _asString(r['trip_id']).isEmpty ? '—' : _asString(r['trip_id']),
                          _asString(r['trip_kind']).isEmpty ? '—' : _asString(r['trip_kind']),
                          _asString(r['ui_bucket']).isEmpty ? '—' : _asString(r['ui_bucket']),
                          _asString(r['driver_id']).isEmpty ? '—' : _asString(r['driver_id']),
                          _asString(r['updated_at']).isEmpty ? '—' : _asString(r['updated_at']),
                        ],
                        filter: (Map<String, dynamic> r) => _asString(r['ui_bucket']) != 'searching',
                      ),
                    ),
                    const SizedBox(height: 24),
                    sectionOrPlaceholder('mo_title', () => _sectionTitle('Merchant orders needing attention')),
                    sectionOrPlaceholder(
                      'mo_table',
                      () => _tableOrEmpty(
                        moSec.sample,
                        <String>['order', 'merchant', 'status', 'age_s'],
                        (Map<String, dynamic> r) => <String>[
                          _asString(r['order_id']).isEmpty ? '—' : _asString(r['order_id']),
                          _asString(r['merchant_id']).isEmpty ? '—' : _asString(r['merchant_id']),
                          _asString(r['order_status']).isEmpty ? '—' : _asString(r['order_status']),
                          _asString(r['age_seconds']).isEmpty ? '—' : _asString(r['age_seconds']),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    sectionOrPlaceholder('portal_title', () => _sectionTitle('Merchant portal last seen')),
                    sectionOrPlaceholder(
                      'portal_table',
                      () => _tableOrEmpty(
                        merchantsSec.sample,
                        <String>['merchant', 'portal_ms', 'orders_live', 'open'],
                        (Map<String, dynamic> r) => <String>[
                          _asString(r['merchant_id']).isEmpty ? '—' : _asString(r['merchant_id']),
                          _asString(r['portal_last_seen_ms']).isEmpty
                              ? '—'
                              : _asString(r['portal_last_seen_ms']),
                          _asString(r['orders_live']).isEmpty ? '—' : _asString(r['orders_live']),
                          _asString(r['is_open']).isEmpty ? '—' : _asString(r['is_open']),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    sectionOrPlaceholder('alerts_title', () => _sectionTitle('Alerts')),
                    sectionOrPlaceholder('alerts_body', () => _buildAlertsBody(alerts)),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildAlertsBody(List<Map<String, dynamic>> alerts) {
    if (alerts.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Text(
          'No active alerts.',
          style: TextStyle(color: Color(0xFF6E675C)),
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final Map<String, dynamic> a in alerts)
          Builder(
            builder: (BuildContext context) {
              try {
                final sev = _asString(a['severity']);
                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: Icon(
                      _iconForSeverity(sev),
                      color: _colorForSeverity(sev),
                    ),
                    title: Text(
                      _asString(a['title']).isEmpty
                          ? (_asString(a['type']).isEmpty ? 'Alert' : _asString(a['type']))
                          : _asString(a['title']),
                    ),
                    subtitle: Text(_asString(a['message']).isEmpty ? '—' : _asString(a['message'])),
                    trailing: Text(
                      '${_asString(a['age_seconds']).isEmpty ? '—' : _asString(a['age_seconds'])}s',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  ),
                );
              } catch (e, st) {
                debugPrint('[LIVE_OPS] alert row failed: $e\n$st');
                return const SizedBox.shrink();
              }
            },
          ),
      ],
    );
  }

  Widget _metric(String label, int value, String caption, IconData icon) {
    return SizedBox(
      width: 220,
      child: AdminStatCard(
        metric: AdminMetricCardData(
          label: label,
          value: '$value',
          caption: caption,
        ),
        icon: icon,
      ),
    );
  }

  Widget _sectionTitle(String t) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        t,
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w800,
          color: AdminThemeTokens.ink,
        ),
      ),
    );
  }

  Widget _tableOrEmpty(
    Object? rawRows,
    List<String> headers,
    List<String> Function(Map<String, dynamic> r) rowBuilder, {
    bool Function(Map<String, dynamic> r)? filter,
  }) {
    List<Map<String, dynamic>> rows;
    try {
      rows = _listOfMaps(rawRows);
      if (filter != null) {
        rows = rows.where(filter).toList();
      }
    } catch (e, st) {
      debugPrint('[LIVE_OPS] _tableOrEmpty parse failed: $e\n$st');
      rows = <Map<String, dynamic>>[];
    }
    if (rows.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'Nothing to show right now.',
          style: TextStyle(color: Color(0xFF8D8578)),
        ),
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columns: <DataColumn>[
          for (final String h in headers) DataColumn(label: Text(h)),
        ],
        rows: <DataRow>[
          for (final Map<String, dynamic> r in rows)
            DataRow(
              cells: <DataCell>[
                for (final String cell in _safeRowCells(r, rowBuilder)) DataCell(Text(cell)),
              ],
            ),
        ],
      ),
    );
  }

  List<String> _safeRowCells(
    Map<String, dynamic> r,
    List<String> Function(Map<String, dynamic> r) rowBuilder,
  ) {
    try {
      return rowBuilder(r);
    } catch (e, st) {
      debugPrint('[LIVE_OPS] rowBuilder failed: $e\n$st');
      return <String>['—', '—', '—', '—'];
    }
  }

  IconData _iconForSeverity(String s) {
    switch (s) {
      case 'critical':
        return Icons.error_outline_rounded;
      case 'warning':
        return Icons.warning_amber_rounded;
      default:
        return Icons.info_outline_rounded;
    }
  }

  Color _colorForSeverity(String s) {
    switch (s) {
      case 'critical':
        return AdminThemeTokens.danger;
      case 'warning':
        return AdminThemeTokens.warning;
      default:
        return AdminThemeTokens.info;
    }
  }
}

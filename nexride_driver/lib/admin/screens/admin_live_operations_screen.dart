import 'dart:async' show Timer, unawaited;

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import '../admin_config.dart';
import '../admin_rbac.dart';
import '../models/admin_models.dart';
import '../services/admin_data_service.dart';
import '../utils/admin_formatters.dart';
import '../widgets/admin_components.dart';
import '../widgets/admin_sensitive_action_dialog.dart';

/// Phase 3A — live rides/deliveries + driver presence + dispatch actions (callable-backed).
class AdminLiveOperationsScreen extends StatefulWidget {
  const AdminLiveOperationsScreen({
    super.key,
    required this.dataService,
    required this.session,
  });

  final AdminDataService dataService;
  final AdminSession session;

  @override
  State<AdminLiveOperationsScreen> createState() =>
      _AdminLiveOperationsScreenState();
}

class _AdminLiveOperationsScreenState extends State<AdminLiveOperationsScreen> {
  FirebaseFunctions get _fn =>
      FirebaseFunctions.instanceFor(region: 'us-central1');

  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _trips = const [];
  List<Map<String, dynamic>> _recentCompleted = const [];
  List<Map<String, dynamic>> _recentCancelled = const [];
  List<Map<String, dynamic>> _drivers = const [];

  int _opsTab = 0;
  List<AdminTripRecord> _browseTrips = const <AdminTripRecord>[];
  bool _browseLoading = false;
  String? _browseError;
  final List<String?> _browseCursorStack = <String?>[null];
  String? _browseNextCursor;
  bool _browseHasMore = false;
  String _browseStatusFilter = 'All';
  final TextEditingController _browseTripSearch = TextEditingController();
  Timer? _browseSearchDebounce;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _browseSearchDebounce?.cancel();
    _browseTripSearch.dispose();
    super.dispose();
  }

  Map<String, dynamic> _mapOf(Object? raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return <String, dynamic>{};
  }

  List<Map<String, dynamic>> _listOfMaps(Object? raw) {
    if (raw is! List) return const [];
    return raw
        .map((dynamic e) => _mapOf(e))
        .where((Map<String, dynamic> m) => m.isNotEmpty)
        .toList();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final live = await _fn.httpsCallable('adminListLiveTrips').call();
      final drv = await _fn.httpsCallable('adminListOnlineDrivers').call();
      final liveData = _mapOf(live.data);
      final drvData = _mapOf(drv.data);
      if (liveData['success'] != true) {
        throw StateError(liveData['reason']?.toString() ?? 'live_trips_failed');
      }
      if (drvData['success'] != true) {
        throw StateError(drvData['reason']?.toString() ?? 'drivers_failed');
      }
      if (!mounted) return;
      setState(() {
        _trips = _listOfMaps(liveData['trips']);
        _recentCompleted = _listOfMaps(liveData['recent_completed']);
        _recentCancelled = _listOfMaps(liveData['recent_cancelled']);
        _drivers = _listOfMaps(drvData['drivers']);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  void _onOpsTabChanged(int tab) {
    setState(() {
      _opsTab = tab;
    });
    if (tab == 1) {
      unawaited(_loadBrowseTrips(resetCursors: true));
    }
  }

  void _scheduleBrowseTripSearchReload() {
    _browseSearchDebounce?.cancel();
    _browseSearchDebounce = Timer(const Duration(milliseconds: 450), () {
      if (!mounted || _opsTab != 1) {
        return;
      }
      unawaited(_loadBrowseTrips(resetCursors: true));
    });
  }

  Future<void> _loadBrowseTrips({bool resetCursors = true}) async {
    if (resetCursors) {
      _browseCursorStack
        ..clear()
        ..add(null);
    }
    setState(() {
      _browseLoading = true;
      _browseError = null;
    });
    try {
      final cursor =
          _browseCursorStack.isEmpty ? null : _browseCursorStack.last;
      final query = AdminListQuery(
        search: _browseTripSearch.text.trim(),
        city: 'All',
        stateOrRegion: 'All',
        status: _browseStatusFilter,
        verificationStatus: 'All',
      );
      final page = await widget.dataService.fetchTripsPageForAdmin(
        cursor: cursor,
        limit: 50,
        query: query,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _browseTrips = page.trips;
        _browseNextCursor = page.nextCursor;
        _browseHasMore = page.hasMore;
        _browseLoading = false;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _browseLoading = false;
        _browseError = e.toString();
      });
    }
  }

  void _onBrowseServerNextPage() {
    final c = _browseNextCursor;
    if (c == null || !_browseHasMore || _browseLoading) {
      return;
    }
    setState(() {
      _browseCursorStack.add(c);
    });
    unawaited(_loadBrowseTrips(resetCursors: false));
  }

  void _onBrowseServerPrevPage() {
    if (_browseCursorStack.length <= 1 || _browseLoading) {
      return;
    }
    setState(() {
      _browseCursorStack.removeLast();
    });
    unawaited(_loadBrowseTrips(resetCursors: false));
  }

  Future<String?> _promptNote(String title) async {
    final controller = TextEditingController();
    final note = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) {
        return AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
              hintText: 'Required note (at least 8 characters)',
              border: OutlineInputBorder(),
            ),
            minLines: 2,
            maxLines: 5,
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Confirm'),
            ),
          ],
        );
      },
    );
    if (note == null || note.length < 8) {
      if (note != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Note must be at least 8 characters.')),
        );
      }
      return null;
    }
    return note;
  }

  Future<void> _openDetail(String tripId) async {
    try {
      final res = await _fn.httpsCallable('adminGetTripDetail').call(
        <String, dynamic>{'tripId': tripId},
      );
      final data = _mapOf(res.data);
      if (data['success'] != true) {
        throw StateError(data['reason']?.toString() ?? 'detail_failed');
      }
      if (!mounted) return;
      final tripKind = data['trip_kind']?.toString() ?? '';
      final record = _mapOf(data['ride']).isNotEmpty
          ? _mapOf(data['ride'])
          : _mapOf(data['delivery']);
      final payments = _listOfMaps(data['payments']);
      final auditTimeline = _listOfMaps(data['audit_timeline']);
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (BuildContext ctx) {
          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.88,
            minChildSize: 0.45,
            maxChildSize: 0.95,
            builder: (_, ScrollController sc) {
              return _TripDetailSheet(
                tripId: tripId,
                tripKind: tripKind,
                record: record,
                payments: payments,
                auditTimeline: auditTimeline,
                scrollController: sc,
                onAction: _runTripAction,
                onClose: () => Navigator.pop(ctx),
                session: widget.session,
              );
            },
          );
        },
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not load trip: $e')),
      );
    }
  }

  Future<void> _runTripAction(String name, Map<String, dynamic> payload) async {
    try {
      final res = await _fn.httpsCallable(name).call(payload);
      final data = _mapOf(res.data);
      if (data['success'] != true) {
        throw StateError(data['reason']?.toString() ?? 'action_failed');
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$name: ${data['reason'] ?? 'ok'}')),
      );
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$name failed: $e')),
      );
    }
  }

  Iterable<Map<String, dynamic>> _byBucket(String bucket) =>
      _trips.where((Map<String, dynamic> t) => t['ui_bucket'] == bucket);

  String _elapsedLabel(Map<String, dynamic> t) {
    final ms = (t['elapsed_ms'] is num) ? (t['elapsed_ms'] as num).toInt() : 0;
    if (ms <= 0) return '—';
    final d = Duration(milliseconds: ms);
    if (d.inHours >= 1) return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
    if (d.inMinutes >= 1) return '${d.inMinutes}m';
    return '${d.inSeconds}s';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: CircularProgressIndicator(),
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              AdminEmptyState(
                title: 'Live operations unavailable',
                message: _error!,
                icon: Icons.error_outline,
              ),
              const SizedBox(height: 12),
              FilledButton(onPressed: _refresh, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1400),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: AdminSectionHeader(
                      title: 'Live operations',
                      description:
                          'Callable-backed view of active ride and delivery requests, '
                          'recent terminal trips, and online drivers. Actions write '
                          'admin audit logs.',
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: _refresh,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Refresh'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              SegmentedButton<int>(
                segments: const <ButtonSegment<int>>[
                  ButtonSegment<int>(
                    value: 0,
                    label: Text('Live'),
                    icon: Icon(Icons.dashboard_outlined),
                  ),
                  ButtonSegment<int>(
                    value: 1,
                    label: Text('Browse trips'),
                    icon: Icon(Icons.list_alt_outlined),
                  ),
                ],
                selected: <int>{_opsTab},
                onSelectionChanged: (Set<int> selection) {
                  final int v = selection.first;
                  _onOpsTabChanged(v);
                },
              ),
              const SizedBox(height: 16),
              if (_opsTab == 0) ...<Widget>[
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: <Widget>[
                  _CountChip(
                    label: 'Searching',
                    count: _byBucket('searching').length,
                    color: const Color(0xFF6B4EFF),
                  ),
                  _CountChip(
                    label: 'Accepted',
                    count: _byBucket('accepted').length +
                        _byBucket('driver_arriving').length,
                    color: const Color(0xFF0B7A75),
                  ),
                  _CountChip(
                    label: 'Arrived',
                    count: _byBucket('arrived').length +
                        _byBucket('arrived_pickup').length,
                    color: const Color(0xFFB45309),
                  ),
                  _CountChip(
                    label: 'In progress',
                    count: _byBucket('in_progress').length,
                    color: const Color(0xFF1565C0),
                  ),
                  _CountChip(
                    label: 'Online drivers',
                    count: _drivers.length,
                    color: const Color(0xFF2E7D32),
                  ),
                  _CountChip(
                    label: 'Busy drivers',
                    count: _drivers
                        .where((Map<String, dynamic> d) =>
                            d['driver_class'] == 'busy')
                        .length,
                    color: const Color(0xFFC62828),
                  ),
                  _CountChip(
                    label: 'Idle drivers',
                    count: _drivers
                        .where((Map<String, dynamic> d) =>
                            d['driver_class'] == 'idle')
                        .length,
                    color: const Color(0xFF5D4037),
                  ),
                  _CountChip(
                    label: 'Merchant orders',
                    count: _trips
                        .where((Map<String, dynamic> t) =>
                            t['trip_kind'] == 'merchant_order' ||
                            t['delivery_source'] == 'merchant_food_order')
                        .length,
                    color: const Color(0xFF6A1B9A),
                  ),
                  _CountChip(
                    label: 'Dispatch',
                    count: _trips
                        .where((Map<String, dynamic> t) =>
                            t['delivery_source'] == 'dispatch')
                        .length,
                    color: const Color(0xFF00838F),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              _TripTableCard(
                title: 'Active & searching trips',
                rows: _trips,
                onOpen: _openDetail,
                elapsedLabel: _elapsedLabel,
              ),
              const SizedBox(height: 20),
              _TripTableCard(
                title: 'Completed recently (sampled)',
                rows: _recentCompleted,
                onOpen: _openDetail,
                elapsedLabel: _elapsedLabel,
              ),
              const SizedBox(height: 20),
              _TripTableCard(
                title: 'Cancelled recently (sampled)',
                rows: _recentCancelled,
                onOpen: _openDetail,
                elapsedLabel: _elapsedLabel,
              ),
              const SizedBox(height: 20),
              _DriversCard(
                drivers: _drivers,
                allowDriverWrite: widget.session.hasPermission('drivers.write'),
                onForceOffline: (String id) {
                  unawaited(() async {
                    final String? reason = await showAdminSensitiveActionDialog(
                      context,
                      title: 'Force driver offline',
                      message:
                          'Removes the driver from the online pool immediately. '
                          'Provide an operations reason (audit log).',
                      confirmLabel: 'Force offline',
                      minReasonLength: 4,
                    );
                    if (reason == null) {
                      return;
                    }
                    await _runTripAction('adminForceDriverOffline', <String, dynamic>{
                      'driverId': id,
                      'reason': reason,
                    });
                  }());
                },
                onSuspend: (String id) {
                  unawaited(() async {
                    final note = await _promptNote('Suspend driver');
                    if (note == null) return;
                    await _runTripAction('adminSuspendDriver', <String, dynamic>{
                      'driverId': id,
                      'note': note,
                    });
                  }());
                },
              ),
              ] else
                _buildBrowseTripsPanel(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBrowseTripsPanel() {
    if (_browseLoading && _browseTrips.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: CircularProgressIndicator(),
        ),
      );
    }
    if (_browseError != null && _browseTrips.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            _browseError!,
            style: const TextStyle(color: AdminThemeTokens.slate),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () => unawaited(_loadBrowseTrips(resetCursors: true)),
            child: const Text('Retry'),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'adminListTripsPage — up to 50 trips per request (server search + status filter).',
          style: TextStyle(
            color: AdminThemeTokens.slate,
            fontSize: 13,
            height: 1.35,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            SizedBox(
              width: 280,
              child: TextField(
                controller: _browseTripSearch,
                decoration: const InputDecoration(
                  labelText: 'Search trip id, rider, or driver',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (_) => _scheduleBrowseTripSearchReload(),
              ),
            ),
            DropdownButton<String>(
              value: _browseStatusFilter,
              items: const <DropdownMenuItem<String>>[
                DropdownMenuItem(value: 'All', child: Text('All statuses')),
                DropdownMenuItem(value: 'requested', child: Text('requested')),
                DropdownMenuItem(value: 'assigned', child: Text('assigned')),
                DropdownMenuItem(value: 'accepted', child: Text('accepted')),
                DropdownMenuItem(value: 'started', child: Text('started')),
                DropdownMenuItem(value: 'completed', child: Text('completed')),
                DropdownMenuItem(value: 'cancelled', child: Text('cancelled')),
              ],
              onChanged: (String? v) {
                if (v == null) {
                  return;
                }
                setState(() {
                  _browseStatusFilter = v;
                });
                unawaited(_loadBrowseTrips(resetCursors: true));
              },
            ),
            TextButton.icon(
              onPressed: _browseLoading
                  ? null
                  : () => unawaited(_loadBrowseTrips(resetCursors: true)),
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Reload page'),
            ),
          ],
        ),
        if (_browseLoading) ...<Widget>[
          const SizedBox(height: 8),
          const LinearProgressIndicator(minHeight: 3),
        ],
        const SizedBox(height: 16),
        if (_browseTrips.isEmpty)
          const Text(
            'No trips matched this page.',
            style: TextStyle(color: AdminThemeTokens.slate),
          )
        else
          AdminDataTableCard(
            heading: Text('Trips (${_browseTrips.length} on this page)'),
            columns: const <DataColumn>[
              DataColumn(label: Text('Trip')),
              DataColumn(label: Text('Status')),
              DataColumn(label: Text('City')),
              DataColumn(label: Text('Rider')),
              DataColumn(label: Text('Driver')),
              DataColumn(label: Text('Fare')),
              DataColumn(label: Text('Created')),
            ],
            rows: _browseTrips.map((AdminTripRecord t) {
              return DataRow(
                onSelectChanged: (_) {
                  unawaited(_openDetail(t.id));
                },
                cells: <DataCell>[
                  DataCell(Text(t.id, style: const TextStyle(fontWeight: FontWeight.w700))),
                  DataCell(Text(t.status)),
                  DataCell(Text(t.city.isNotEmpty ? t.city : '—')),
                  DataCell(Text(t.riderName.isNotEmpty ? t.riderName : '—')),
                  DataCell(Text(t.driverName.isNotEmpty ? t.driverName : '—')),
                  DataCell(Text(formatAdminCurrency(t.fareAmount))),
                  DataCell(Text(
                    t.createdAt != null
                        ? formatAdminDateTime(t.createdAt!)
                        : '—',
                  )),
                ],
              );
            }).toList(),
          ),
        const SizedBox(height: 12),
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                'Cursor paging uses the last scanned RTDB key; narrow filters if you need a specific trip.',
                style: TextStyle(
                  color: AdminThemeTokens.slate,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
            ),
            TextButton(
              onPressed: (_browseLoading || _browseCursorStack.length <= 1)
                  ? null
                  : _onBrowseServerPrevPage,
              child: const Text('Previous'),
            ),
            TextButton(
              onPressed: (!_browseHasMore ||
                      _browseLoading ||
                      (_browseNextCursor ?? '').isEmpty)
                  ? null
                  : _onBrowseServerNextPage,
              child: const Text('Next'),
            ),
          ],
        ),
      ],
    );
  }
}

String _liveOpsKindLabel(Map<String, dynamic> t) {
  final kind = t['trip_kind']?.toString() ?? '';
  if (kind == 'ride') return 'Ride';
  if (kind == 'merchant_order') return 'Merchant order';
  final src = t['delivery_source']?.toString() ?? '';
  if (src == 'merchant_food_order') return 'Merchant';
  if (src == 'dispatch') return 'Dispatch';
  return 'Delivery';
}

class _CountChip extends StatelessWidget {
  const _CountChip({
    required this.label,
    required this.count,
    required this.color,
  });

  final String label;
  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: CircleAvatar(
        backgroundColor: color.withValues(alpha: 0.15),
        child: Text(
          '$count',
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.w800,
            fontSize: 12,
          ),
        ),
      ),
      label: Text(label),
    );
  }
}

class _TripTableCard extends StatelessWidget {
  const _TripTableCard({
    required this.title,
    required this.rows,
    required this.onOpen,
    required this.elapsedLabel,
  });

  final String title;
  final List<Map<String, dynamic>> rows;
  final Future<void> Function(String tripId) onOpen;
  final String Function(Map<String, dynamic>) elapsedLabel;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return AdminSurfaceCard(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            '$title — no rows',
            style: TextStyle(
              color: AdminThemeTokens.ink,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    }
    return AdminDataTableCard(
      heading: Text('$title (${rows.length})'),
      columns: const <DataColumn>[
        DataColumn(label: Text('Kind')),
        DataColumn(label: Text('Trip')),
        DataColumn(label: Text('Bucket')),
        DataColumn(label: Text('Region')),
        DataColumn(label: Text('Rider')),
        DataColumn(label: Text('Driver')),
        DataColumn(label: Text('Payment')),
        DataColumn(label: Text('Fare / final')),
        DataColumn(label: Text('Elapsed')),
        DataColumn(label: Text('Emergency')),
      ],
      rows: rows.map((Map<String, dynamic> t) {
        final id = t['trip_id']?.toString() ?? '';
        final kind = _liveOpsKindLabel(t);
        final fare = (t['fare_estimate'] is num)
            ? (t['fare_estimate'] as num).toDouble()
            : 0.0;
        final finalFare = (t['final_fare'] is num)
            ? (t['final_fare'] as num).toDouble()
            : fare;
        return DataRow(
          onSelectChanged: (_) {
            onOpen(id);
          },
          cells: <DataCell>[
            DataCell(Text(kind)),
            DataCell(
              Text(id, style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
            DataCell(Text(t['ui_bucket']?.toString() ?? '—')),
            DataCell(Text(t['region']?.toString() ?? '—')),
            DataCell(Text(t['rider_name']?.toString() ?? '—')),
            DataCell(Text(t['driver_name']?.toString() ?? '—')),
            DataCell(
              Text(
                '${t['payment_method'] ?? ''} • ${t['payment_status'] ?? ''}',
              ),
            ),
            DataCell(Text('${formatAdminCurrency(fare)} / ${formatAdminCurrency(finalFare)}')),
            DataCell(Text(elapsedLabel(t))),
            DataCell(
              Icon(
                t['admin_emergency'] == true
                    ? Icons.warning_amber_rounded
                    : Icons.shield_outlined,
                color: t['admin_emergency'] == true
                    ? Colors.deepOrange
                    : Colors.grey,
              ),
            ),
          ],
        );
      }).toList(),
    );
  }
}

class _DriversCard extends StatelessWidget {
  const _DriversCard({
    required this.drivers,
    required this.onForceOffline,
    required this.onSuspend,
    required this.allowDriverWrite,
  });

  final List<Map<String, dynamic>> drivers;
  final void Function(String driverId) onForceOffline;
  final void Function(String driverId) onSuspend;
  final bool allowDriverWrite;

  @override
  Widget build(BuildContext context) {
    if (drivers.isEmpty) {
      return AdminSurfaceCard(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            'Online drivers — none',
            style: TextStyle(
              color: AdminThemeTokens.ink,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    }
    return AdminDataTableCard(
      heading: Text('Online drivers (${drivers.length})'),
      columns: const <DataColumn>[
        DataColumn(label: Text('Driver')),
        DataColumn(label: Text('Class')),
        DataColumn(label: Text('Market')),
        DataColumn(label: Text('Active trip')),
        DataColumn(label: Text('Actions')),
      ],
      rows: drivers.map((Map<String, dynamic> d) {
        final id = d['driver_id']?.toString() ?? '';
        return DataRow(
          cells: <DataCell>[
            DataCell(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(d['name']?.toString() ?? id,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text(d['phone']?.toString() ?? ''),
                ],
              ),
            ),
            DataCell(Text(d['driver_class']?.toString() ?? '—')),
            DataCell(Text(d['market']?.toString() ?? '—')),
            DataCell(
              Text(
                '${d['active_trip_kind'] ?? ''} ${d['active_trip_id'] ?? ''}'
                    .trim(),
              ),
            ),
            DataCell(
              Builder(
                builder: (BuildContext _) {
                  final Widget forceBtn = TextButton(
                    onPressed: id.isEmpty || !allowDriverWrite
                        ? null
                        : () => onForceOffline(id),
                    child: const Text('Force offline'),
                  );
                  final Widget suspendBtn = TextButton(
                    onPressed: id.isEmpty || !allowDriverWrite
                        ? null
                        : () => onSuspend(id),
                    child: const Text('Suspend'),
                  );
                  return Wrap(
                    spacing: 8,
                    children: <Widget>[
                      allowDriverWrite
                          ? forceBtn
                          : Tooltip(
                              message: kAdminNoPermissionTooltip,
                              child: forceBtn,
                            ),
                      allowDriverWrite
                          ? suspendBtn
                          : Tooltip(
                              message: kAdminNoPermissionTooltip,
                              child: suspendBtn,
                            ),
                    ],
                  );
                },
              ),
            ),
          ],
        );
      }).toList(),
    );
  }
}

class _TripDetailSheet extends StatelessWidget {
  const _TripDetailSheet({
    required this.tripId,
    required this.tripKind,
    required this.record,
    required this.payments,
    required this.auditTimeline,
    required this.scrollController,
    required this.onAction,
    required this.onClose,
    required this.session,
  });

  final String tripId;
  final String tripKind;
  final Map<String, dynamic> record;
  final List<Map<String, dynamic>> payments;
  final List<Map<String, dynamic>> auditTimeline;
  final ScrollController scrollController;
  final Future<void> Function(String name, Map<String, dynamic> payload)
      onAction;
  final VoidCallback onClose;
  final AdminSession session;

  Widget _tonalGate({required bool allowed, required Widget child}) {
    if (allowed) {
      return child;
    }
    return Tooltip(message: kAdminNoPermissionTooltip, child: child);
  }

  Map<String, String> _flattenRecord() {
    final out = <String, String>{};
    void walk(String prefix, Object? v) {
      if (v == null) return;
      if (v is Map) {
        v.forEach((dynamic k, dynamic val) {
          walk(prefix.isEmpty ? '$k' : '$prefix.$k', val);
        });
        return;
      }
      out[prefix] = v.toString();
    }

    walk('', record);
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final flat = _flattenRecord();
    final pickup = record['pickup'];
    final dropoff = record['dropoff'] ?? record['destination'];
    final bool canTripWrite = session.hasPermission('trips.write');
    final bool canDriversWrite = session.hasPermission('drivers.write');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: ListView(
        controller: scrollController,
        children: <Widget>[
          Text(
            'Trip $tripId',
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
          ),
          Text(
            '${sentenceCaseStatus(tripKind)} • ${sentenceCaseStatus(record['trip_state']?.toString() ?? '')} • ${sentenceCaseStatus(record['status']?.toString() ?? '')}',
            style: const TextStyle(color: Color(0xFF6B655B)),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              _tonalGate(
                allowed: canTripWrite,
                child: FilledButton.tonal(
                onPressed: () {
                  unawaited(() async {
                    final note =
                        await _promptNoteStatic(context, 'Cancel trip');
                    if (note == null) return;
                    await onAction('adminCancelTrip', <String, dynamic>{
                      'tripId': tripId,
                      'kind': tripKind,
                      'note': note,
                    });
                    onClose();
                  }());
                },
                child: const Text('Cancel trip'),
              ),
              ),
              _tonalGate(
                allowed: canTripWrite,
                child: FilledButton.tonal(
                onPressed: () {
                  unawaited(() async {
                    final note =
                        await _promptNoteStatic(context, 'Mark emergency');
                    if (note == null) return;
                    await onAction('adminMarkTripEmergency', <String, dynamic>{
                      'tripId': tripId,
                      'note': note,
                    });
                  }());
                },
                child: const Text('Mark emergency'),
              ),
              ),
              _tonalGate(
                allowed: canTripWrite,
                child: FilledButton.tonal(
                onPressed: () {
                  unawaited(() async {
                    final note =
                        await _promptNoteStatic(context, 'Resolve emergency');
                    if (note == null) return;
                    await onAction('adminResolveTripEmergency', <String, dynamic>{
                      'tripId': tripId,
                      'note': note,
                    });
                  }());
                },
                child: const Text('Resolve emergency'),
              ),
              ),
              if ((record['driver_id'] ?? '').toString().trim().isNotEmpty &&
                  record['driver_id'].toString() != 'waiting')
                _tonalGate(
                  allowed: canDriversWrite,
                  child: FilledButton.tonal(
                  onPressed: () {
                    unawaited(() async {
                      final did = record['driver_id'].toString();
                      final String? reason = await showAdminSensitiveActionDialog(
                        context,
                        title: 'Force driver offline',
                        message:
                            'Driver $did will be taken offline immediately.',
                        confirmLabel: 'Force offline',
                        minReasonLength: 4,
                      );
                      if (reason == null) {
                        return;
                      }
                      await onAction('adminForceDriverOffline', <String, dynamic>{
                        'driverId': did,
                        'reason': reason,
                      });
                    }());
                  },
                  child: const Text('Force driver offline'),
                ),
                ),
              if ((record['driver_id'] ?? '').toString().trim().isNotEmpty &&
                  record['driver_id'].toString() != 'waiting')
                _tonalGate(
                  allowed: canDriversWrite,
                  child: FilledButton.tonal(
                  onPressed: () {
                    unawaited(() async {
                      final did = record['driver_id'].toString();
                      final note =
                          await _promptNoteStatic(context, 'Suspend driver');
                      if (note == null) return;
                      await onAction('adminSuspendDriver', <String, dynamic>{
                        'driverId': did,
                        'note': note,
                      });
                    }());
                  },
                  child: const Text('Suspend driver'),
                ),
                ),
            ],
          ),
          const SizedBox(height: 20),
          const Text('Pickup / dropoff',
              style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(pickup?.toString() ?? '—'),
          Text(dropoff?.toString() ?? '—'),
          const SizedBox(height: 20),
          const Text('Payments',
              style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          if (payments.isEmpty)
            const Text('No linked payment rows.')
          else
            ...payments.map(
              (Map<String, dynamic> p) => ListTile(
                dense: true,
                title: Text(p['reference']?.toString() ?? ''),
                subtitle: Text(
                  'verified=${p['verified']} amount=${p['amount']}',
                ),
              ),
            ),
          const SizedBox(height: 20),
          const Text('Safety / emergency',
              style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text('admin_emergency: ${record['admin_emergency']}'),
          Text('admin_emergency_note: ${record['admin_emergency_note'] ?? ''}'),
          const SizedBox(height: 20),
          const Text('Admin audit (recent matches)',
              style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          if (auditTimeline.isEmpty)
            const Text('No matching admin audit entries.')
          else
            ...auditTimeline.take(25).map(
                  (Map<String, dynamic> a) {
                    final ms = (a['created_at'] is num)
                        ? (a['created_at'] as num).toInt()
                        : 0;
                    final when = ms > 0
                        ? formatAdminDateTime(
                            DateTime.fromMillisecondsSinceEpoch(ms),
                          )
                        : '—';
                    return ListTile(
                      dense: true,
                      title: Text(a['type']?.toString() ?? ''),
                      subtitle: Text(
                        '$when • ${a['note'] ?? a['reason'] ?? ''}',
                      ),
                    );
                  },
                ),
          const SizedBox(height: 16),
          const Text('Raw record (flattened)',
              style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          AdminKeyValueWrap(
            items: Map<String, String>.fromEntries(flat.entries.take(48)),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  static Future<String?> _promptNoteStatic(
      BuildContext context, String title) async {
    final controller = TextEditingController();
    final note = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) {
        return AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
              hintText: 'Required note (at least 8 characters)',
              border: OutlineInputBorder(),
            ),
            minLines: 2,
            maxLines: 5,
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Confirm'),
            ),
          ],
        );
      },
    );
    if (note == null || note.length < 8) {
      if (note != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Note must be at least 8 characters.')),
        );
      }
      return null;
    }
    return note;
  }
}

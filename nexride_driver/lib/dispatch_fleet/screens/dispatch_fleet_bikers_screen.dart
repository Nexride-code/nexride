import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../dispatch_fleet_account_gate.dart';
import '../dispatch_fleet_functions.dart';
import '../dispatch_fleet_routes.dart';

class DispatchFleetBikersScreen extends StatefulWidget {
  const DispatchFleetBikersScreen({super.key});

  @override
  State<DispatchFleetBikersScreen> createState() =>
      _DispatchFleetBikersScreenState();
}

class _DispatchFleetBikersScreenState extends State<DispatchFleetBikersScreen> {
  final DispatchFleetFunctions _fleet = DispatchFleetFunctions();

  final List<Map<String, dynamic>> _items = <Map<String, dynamic>>[];
  String? _nextCursor;
  bool _hasMore = false;
  bool _loading = false;
  bool _loadingMore = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh(reset: true));
  }

  Future<void> _refresh({required bool reset}) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (!mounted) {
        return;
      }
      await Navigator.of(context).pushReplacementNamed(DispatchFleetRoutes.login);
      return;
    }

    if (reset) {
      setState(() {
        _loading = true;
        _error = null;
        _items.clear();
        _nextCursor = null;
        _hasMore = false;
      });
    } else {
      setState(() {
        _loadingMore = true;
        _error = null;
      });
    }

    try {
      final accountRes = await _fleet.dispatchFleetGetMyAccount();
      if (!mounted) {
        return;
      }
      final dest = destinationForFleetAccountResponse(accountRes);
      if (dest != DispatchFleetAccountDestination.dashboard) {
        await Navigator.of(context).pushNamedAndRemoveUntil(
          DispatchFleetRoutes.session,
          (Route<dynamic> route) => false,
        );
        return;
      }

      final listRes = await _fleet.fleetListLinkedDriversPage(
        limit: 25,
        cursorDriverId: reset ? null : _nextCursor,
      );
      if (!mounted) {
        return;
      }
      if (!dfSuccess(listRes['success'])) {
        setState(() {
          _error = dfLinkedBikersErrorMessage(listRes['reason']?.toString());
          _loading = false;
          _loadingMore = false;
        });
        return;
      }

      final rawItems = listRes['items'];
      final parsed = rawItems is List
          ? rawItems
              .whereType<Map>()
              .map((e) => e.map((k, v) => MapEntry(k.toString(), v)))
              .toList()
          : <Map<String, dynamic>>[];

      setState(() {
        if (reset) {
          _items
            ..clear()
            ..addAll(parsed);
        } else {
          _items.addAll(parsed);
        }
        _nextCursor = listRes['next_cursor_driver_id']?.toString();
        _hasMore = listRes['has_more'] == true ||
            listRes['has_more']?.toString().toLowerCase() == 'true';
        _loading = false;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = 'Could not load linked bikers. Tap refresh to try again.';
      });
    }
  }

  String _formatLinkedAt(dynamic raw) {
    final ms = int.tryParse(raw?.toString() ?? '');
    if (ms == null || ms <= 0) {
      return '—';
    }
    final dt = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
    return '${dt.year}-${_two(dt.month)}-${_two(dt.day)}';
  }

  String _two(int n) => n.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Linked Bikers'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading || _loadingMore
                ? null
                : () => _refresh(reset: true),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _loading && _items.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () => _refresh(reset: true),
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                children: <Widget>[
                  if (_error != null) ...<Widget>[
                    Text(
                      _error!,
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (_items.isEmpty && !_loading)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 48),
                      child: Center(
                        child: Text(
                          'No linked bikers yet.\nCreate an invite and ask riders to redeem it.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  else
                    ..._items.map(_buildBikerCard),
                  if (_hasMore) ...<Widget>[
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: _loadingMore
                          ? null
                          : () => _refresh(reset: false),
                      child: _loadingMore
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Load more'),
                    ),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _buildBikerCard(Map<String, dynamic> item) {
    final driverId = item['driver_id']?.toString() ?? '—';
    final name = item['driver_name']?.toString().trim();
    final status = item['business_link_status']?.toString() ?? 'approved';
    final vehicle = item['dispatch_vehicle_type']?.toString() ?? '—';
    final ownership = item['ownership_mode']?.toString() ?? 'business_managed';
    final online = item['online'] == true ||
        item['online']?.toString().toLowerCase() == 'true';

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    name?.isNotEmpty == true ? name! : driverId,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                    ),
                  ),
                ),
                _StatusChip(label: status),
              ],
            ),
            if (name?.isNotEmpty == true) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                driverId,
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.black.withValues(alpha: 0.55),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                _MetaChip(icon: Icons.two_wheeler_outlined, label: vehicle),
                _MetaChip(icon: Icons.business_outlined, label: ownership),
                _MetaChip(
                  icon: online ? Icons.circle : Icons.circle_outlined,
                  label: online ? 'Online' : 'Offline',
                ),
                _MetaChip(
                  icon: Icons.event_outlined,
                  label: 'Linked ${_formatLinkedAt(item['linked_at'])}',
                ),
              ],
            ),
            if (item['phone']?.toString().trim().isNotEmpty == true) ...<Widget>[
              const SizedBox(height: 10),
              Text('Phone: ${item['phone']}'),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final normalized = label.trim().toLowerCase();
    final color = switch (normalized) {
      'approved' || 'active' => Colors.green.shade700,
      'suspended' => Colors.orange.shade800,
      'rejected' => Colors.red.shade700,
      _ => Colors.blueGrey.shade700,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12),
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.black.withValues(alpha: 0.08)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 14),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}

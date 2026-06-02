import 'package:firebase_database/firebase_database.dart' as rtdb;
import 'package:flutter/material.dart';

import '../services/driver_finance_service.dart';
import 'driver_trip_detail_screen.dart';

class TripHistoryScreen extends StatefulWidget {
  const TripHistoryScreen({super.key, required this.driverId});

  final String driverId;

  @override
  State<TripHistoryScreen> createState() => _TripHistoryScreenState();
}

class _TripHistoryScreenState extends State<TripHistoryScreen> {
  List<Map<String, dynamic>> _items = const <Map<String, dynamic>>[];
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadTripHistory();
  }

  Future<List<Map<String, dynamic>>> _loadPath(String path) async {
    final snapshot = await rtdb.FirebaseDatabase.instance.ref(path).get();
    if (!snapshot.exists) {
      return const <Map<String, dynamic>>[];
    }
    final raw = Map<Object?, Object?>.from(snapshot.value as Map);
    final out = <Map<String, dynamic>>[];
    raw.forEach((key, value) {
      if (value is! Map) {
        return;
      }
      final item = value.map<String, dynamic>(
        (dynamic k, dynamic v) => MapEntry(k.toString(), v),
      );
      out.add(_normalizeItem(item, key?.toString() ?? ''));
    });
    return out;
  }

  Map<String, dynamic> _normalizeItem(
    Map<String, dynamic> item,
    String fallbackId,
  ) {
    final pickup = item['pickup'];
    final destination = item['destination'];
    final id = item['rideId']?.toString() ??
        item['orderId']?.toString() ??
        item['trip_id']?.toString() ??
        fallbackId;
    return <String, dynamic>{
      ...item,
      'trip_id': id,
      'pickup_address': item['pickup_address'] ??
          (pickup is Map ? pickup['address']?.toString() : null),
      'destination_address': item['destination_address'] ??
          (destination is Map ? destination['address']?.toString() : null),
    };
  }

  Future<void> _loadTripHistory({bool showLoader = true}) async {
    if (showLoader) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
    } else {
      setState(() {
        _errorMessage = null;
      });
    }

    try {
      final batches = await Future.wait<List<Map<String, dynamic>>>(<Future<List<Map<String, dynamic>>>>[
        _loadPath('driver_trip_history/${widget.driverId}'),
        _loadPath('driver_order_history/${widget.driverId}'),
        _loadPath('driver_trips/${widget.driverId}'),
      ]);
      final merged = <String, Map<String, dynamic>>{};
      for (final batch in batches) {
        for (final item in batch) {
          final id = item['trip_id']?.toString() ?? '';
          if (id.isEmpty) {
            continue;
          }
          merged[id] = item;
        }
      }
      final items = merged.values.toList()
        ..sort((a, b) => _timestamp(b).compareTo(_timestamp(a)));
      if (!mounted) {
        return;
      }
      setState(() {
        _items = items;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoading = false;
        _errorMessage =
            'We could not load trip history right now. Pull to refresh or try again.';
      });
    }
  }

  int _timestamp(Map<String, dynamic> item) {
    for (final key in <String>[
      'completed_at',
      'completedAt',
      'cancelled_at',
      'cancelledAt',
      'timestamp',
      'updated_at',
      'created_at',
      'createdAt',
    ]) {
      final value = item[key];
      if (value is num) {
        return value.toInt();
      }
      final parsed = int.tryParse(value?.toString() ?? '');
      if (parsed != null) {
        return parsed;
      }
    }
    return 0;
  }

  String _formatDate(Map<String, dynamic> item) {
    final ts = _timestamp(item);
    if (ts <= 0) {
      return 'Date unavailable';
    }
    return DriverFinanceService.formatDateTime(
      DateTime.fromMillisecondsSinceEpoch(ts).toLocal(),
    );
  }

  String _formatFare(dynamic raw) {
    final amount =
        raw is num ? raw.toDouble() : double.tryParse(raw?.toString() ?? '') ?? 0;
    return '₦${amount.toStringAsFixed(amount.truncateToDouble() == amount ? 0 : 2)}';
  }

  String _kindLabel(Map<String, dynamic> item) {
    if (item['type']?.toString() == 'order') {
      return 'Delivery / order';
    }
    return 'Ride';
  }

  Future<void> _openDetail(Map<String, dynamic> item) async {
    final tripId = item['trip_id']?.toString() ?? '';
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => DriverTripDetailScreen(
          tripId: tripId,
          driverId: widget.driverId,
          tripData: item,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Trip history')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null && _items.isEmpty
              ? _TripHistoryErrorState(
                  message: _errorMessage!,
                  onRetry: _loadTripHistory,
                )
              : RefreshIndicator(
                  onRefresh: () => _loadTripHistory(showLoader: false),
                  child: _items.isEmpty
                      ? ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: const [
                            SizedBox(height: 120),
                            _TripHistoryEmptyState(
                              icon: Icons.receipt_long_outlined,
                              title: 'No trip records yet',
                              message:
                                  'Completed rides and deliveries will appear here after they finish.',
                            ),
                          ],
                        )
                      : ListView.separated(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                          itemCount: _items.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 12),
                          itemBuilder: (context, index) {
                            final item = _items[index];
                            final status =
                                item['status']?.toString() ?? 'completed';
                            return Material(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(20),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(20),
                                onTap: () => _openDetail(item),
                                child: Padding(
                                  padding: const EdgeInsets.all(18),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              _formatFare(item['fare']),
                                              style: const TextStyle(
                                                fontSize: 20,
                                                fontWeight: FontWeight.w800,
                                              ),
                                            ),
                                          ),
                                          _TripHistoryStatusChip(label: status),
                                        ],
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        _formatDate(item),
                                        style: TextStyle(
                                          color: Colors.black.withValues(alpha: 0.62),
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        _kindLabel(item),
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                          color: Color(0xFF8A6424),
                                        ),
                                      ),
                                      const SizedBox(height: 12),
                                      Text(
                                        item['pickup_address']?.toString() ??
                                            'Pickup unavailable',
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        item['destination_address']?.toString() ??
                                            'Destination unavailable',
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 12),
                                      const Align(
                                        alignment: Alignment.centerRight,
                                        child: Text(
                                          'View details',
                                          style: TextStyle(
                                            fontWeight: FontWeight.w700,
                                            color: Color(0xFF8A6424),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                ),
    );
  }
}

class _TripHistoryStatusChip extends StatelessWidget {
  const _TripHistoryStatusChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final lower = label.toLowerCase();
    final color = lower.contains('cancel')
        ? const Color(0xFFD64545)
        : const Color(0xFF1B7F5A);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _TripHistoryEmptyState extends StatelessWidget {
  const _TripHistoryEmptyState({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          Icon(icon, size: 48, color: const Color(0xFF8A6424)),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.black.withValues(alpha: 0.66)),
          ),
        ],
      ),
    );
  }
}

class _TripHistoryErrorState extends StatelessWidget {
  const _TripHistoryErrorState({
    required this.message,
    required this.onRetry,
  });

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 18),
            ElevatedButton(
              onPressed: onRetry,
              child: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}

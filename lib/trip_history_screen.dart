import 'package:firebase_database/firebase_database.dart' as rtdb;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'service_type.dart';
import 'support/startup_rtdb_support.dart';
import 'trip_detail_screen.dart';

class RiderTripHistoryScreen extends StatefulWidget {
  const RiderTripHistoryScreen({super.key, required this.userId});

  final String userId;

  @override
  State<RiderTripHistoryScreen> createState() => _RiderTripHistoryScreenState();
}

class _RiderTripHistoryScreenState extends State<RiderTripHistoryScreen> {
  static const Color _gold = Color(0xFFB57A2A);

  List<Map<String, dynamic>> trips = <Map<String, dynamic>>[];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    debugPrint(
      '[RideType] RiderTripHistoryScreen initState userId=${widget.userId}',
    );
    fetchTrips();
  }

  Future<void> fetchTrips() async {
    final ref = rtdb.FirebaseDatabase.instance.ref(
      'rider_trips/${widget.userId}',
    );

    try {
      final snapshot = await runOptionalStartupRead<rtdb.DataSnapshot>(
        source: 'trip_history.fetch',
        path: 'rider_trips/${widget.userId}',
        action: () => ref.get(),
      );

      if (snapshot != null && snapshot.exists) {
        final data = Map<Object?, Object?>.from(snapshot.value as Map);
        final loaded = <Map<String, dynamic>>[];

        data.forEach((rawKey, rawValue) {
          if (rawValue is! Map) {
            return;
          }

          final trip = rawValue.map<String, dynamic>(
            (dynamic key, dynamic value) => MapEntry(key.toString(), value),
          );
          trip.putIfAbsent('trip_id', () => rawKey?.toString() ?? '');
          loaded.add(trip);
        });

        loaded.sort((a, b) => _tripTimestamp(b).compareTo(_tripTimestamp(a)));

        if (!mounted) {
          return;
        }

        setState(() {
          trips = loaded;
          loading = false;
        });
      } else {
        if (!mounted) {
          return;
        }

        setState(() {
          trips = <Map<String, dynamic>>[];
          loading = false;
        });
      }
    } catch (error, stackTrace) {
      debugPrint('[RideType] Trip history fetch failed: $error');
      debugPrintStack(
        label: '[RideType] Trip history fetch stack',
        stackTrace: stackTrace,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        loading = false;
      });
    }
  }

  int _tripTimestamp(Map<String, dynamic> trip) {
    for (final key in <String>['completed_at', 'timestamp', 'created_at']) {
      final value = trip[key];
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

  String formatDate(Map<String, dynamic> trip) {
    final timestamp = _tripTimestamp(trip);
    if (timestamp <= 0) {
      return 'Pending';
    }

    final date = DateTime.fromMillisecondsSinceEpoch(timestamp).toLocal();
    return DateFormat('dd MMM yyyy, hh:mm a').format(date);
  }

  String _formatFare(dynamic rawFare) {
    final amount = rawFare is num
        ? rawFare.toDouble()
        : double.tryParse(rawFare?.toString() ?? '') ?? 0;
    return '₦${amount.toStringAsFixed(amount.truncateToDouble() == amount ? 0 : 2)}';
  }

  String _formatDistance(dynamic rawDistance) {
    final distance = rawDistance is num
        ? rawDistance.toDouble()
        : double.tryParse(rawDistance?.toString() ?? '') ?? 0;
    return '${distance.toStringAsFixed(distance.truncateToDouble() == distance ? 0 : 1)} km';
  }

  Future<void> _openTripDetails(Map<String, dynamic> trip) async {
    final tripId = trip['trip_id']?.toString() ?? '';
    debugPrint('[RideType] Trip detail tap fired tripId=$tripId');

    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => TripDetailScreen(
          tripId: tripId,
          riderId: widget.userId,
          tripData: trip,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F2EA),
      appBar: AppBar(
        title: const Text('My Trips'),
        centerTitle: true,
        backgroundColor: _gold,
        foregroundColor: Colors.black,
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : trips.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      Icons.history_toggle_off,
                      size: 52,
                      color: Colors.black.withValues(alpha: 0.45),
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      'No trips yet',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Completed rides and deliveries will appear here for easy review and support.',
                      style: TextStyle(
                        color: Colors.black.withValues(alpha: 0.62),
                        height: 1.5,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: trips.length,
              itemBuilder: (_, int index) {
                final trip = trips[index];
                final serviceType = riderServiceTypeFromKey(
                  (trip['service_type'] ?? trip['serviceType'])?.toString(),
                );

                return Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Material(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(24),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(24),
                      onTap: () => _openTripDetails(trip),
                      child: Ink(
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(24),
                          boxShadow: const <BoxShadow>[
                            BoxShadow(
                              color: Color(0x12000000),
                              blurRadius: 16,
                              offset: Offset(0, 10),
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Row(
                              children: <Widget>[
                                Container(
                                  width: 48,
                                  height: 48,
                                  decoration: BoxDecoration(
                                    color: _gold.withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: Icon(serviceType.icon, color: _gold),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Text(
                                        _formatFare(trip['fare']),
                                        style: const TextStyle(
                                          fontSize: 20,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        formatDate(trip),
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.black.withValues(
                                            alpha: 0.6,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 7,
                                  ),
                                  decoration: BoxDecoration(
                                    color: _gold.withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: Text(
                                    serviceType.detailLabel,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF8A6424),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            _HistoryLine(
                              icon: Icons.my_location,
                              text:
                                  trip['pickup_address']?.toString() ??
                                  'Pickup unavailable',
                              iconColor: Colors.green,
                            ),
                            const SizedBox(height: 8),
                            _HistoryLine(
                              icon: Icons.location_on_outlined,
                              text:
                                  (trip['destination_address'] ??
                                          trip['final_destination_address'])
                                      ?.toString() ??
                                  'Destination unavailable',
                              iconColor: Colors.redAccent,
                            ),
                            const SizedBox(height: 14),
                            Row(
                              children: <Widget>[
                                Text(
                                  _formatDistance(trip['distance']),
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: Colors.black.withValues(alpha: 0.7),
                                  ),
                                ),
                                const Spacer(),
                                const Text(
                                  'View details',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF8A6424),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class _HistoryLine extends StatelessWidget {
  const _HistoryLine({required this.icon, required this.text, this.iconColor});

  final IconData icon;
  final String text;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(icon, size: 18, color: iconColor ?? Colors.black87),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}

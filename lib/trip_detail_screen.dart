import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'service_type.dart';
import 'trip_report_screen.dart';

class TripDetailScreen extends StatelessWidget {
  const TripDetailScreen({
    super.key,
    required this.tripId,
    required this.riderId,
    required this.tripData,
  });

  final String tripId;
  final String riderId;
  final Map<String, dynamic> tripData;

  static const Color _gold = Color(0xFFB57A2A);

  RiderServiceType get _serviceType => riderServiceTypeFromKey(
    (tripData['service_type'] ?? tripData['serviceType'])?.toString(),
  );

  String _formatCurrency(dynamic rawFare) {
    final value = rawFare is num
        ? rawFare.toDouble()
        : double.tryParse(rawFare?.toString() ?? '') ?? 0;
    return '₦${value.toStringAsFixed(value.truncateToDouble() == value ? 0 : 2)}';
  }

  String _formatDistance(dynamic rawDistance) {
    final value = rawDistance is num
        ? rawDistance.toDouble()
        : double.tryParse(rawDistance?.toString() ?? '') ?? 0;
    return '${value.toStringAsFixed(value.truncateToDouble() == value ? 0 : 1)} km';
  }

  String _formatTimestamp(dynamic rawValue) {
    final timestamp = rawValue is num
        ? rawValue.toInt()
        : int.tryParse(rawValue?.toString() ?? '');
    if (timestamp == null || timestamp <= 0) {
      return 'Not available';
    }

    return DateFormat(
      'dd MMM yyyy, hh:mm a',
    ).format(DateTime.fromMillisecondsSinceEpoch(timestamp).toLocal());
  }

  String _value(dynamic rawValue) {
    final value = rawValue?.toString().trim() ?? '';
    return value.isEmpty ? 'Not available' : value;
  }

  Widget _buildInfoTile({
    required IconData icon,
    required String label,
    required String value,
    Color? iconColor,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, color: iconColor ?? Colors.black87),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Colors.black.withValues(alpha: 0.55),
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openReportFlow(BuildContext context) async {
    debugPrint('[TripDetail] report tapped tripId=$tripId');
    final submitted = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute<Map<String, dynamic>>(
        builder: (_) => TripReportScreen(
          tripId: tripId,
          riderId: riderId,
          tripData: tripData,
        ),
      ),
    );

    if (submitted != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Report sent successfully to customer care.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = tripData['status']?.toString() ?? 'completed';
    return Scaffold(
      backgroundColor: const Color(0xFFF7F2EA),
      appBar: AppBar(
        backgroundColor: _gold,
        foregroundColor: Colors.black,
        centerTitle: true,
        title: const Text('Trip details'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: <Widget>[
            Container(
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(28),
                boxShadow: const <BoxShadow>[
                  BoxShadow(
                    color: Color(0x26000000),
                    blurRadius: 24,
                    offset: Offset(0, 16),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: _gold.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: _gold.withValues(alpha: 0.4)),
                    ),
                    child: Text(
                      _serviceType.detailLabel,
                      style: const TextStyle(
                        color: Color(0xFFF6E7CF),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    _formatCurrency(tripData['fare']),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 32,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    riderServiceStatusLabel(_serviceType, status),
                    style: const TextStyle(color: Colors.white70, fontSize: 15),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Trip ID: $tripId',
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            _buildInfoTile(
              icon: Icons.my_location,
              label: 'PICKUP',
              value: _value(tripData['pickup_address']),
              iconColor: Colors.green,
            ),
            const SizedBox(height: 12),
            _buildInfoTile(
              icon: Icons.location_on_outlined,
              label: _serviceType == RiderServiceType.dispatchDelivery
                  ? 'DROPOFF'
                  : 'DESTINATION',
              value: _value(
                tripData['destination_address'] ??
                    tripData['final_destination_address'],
              ),
              iconColor: Colors.redAccent,
            ),
            const SizedBox(height: 12),
            _buildInfoTile(
              icon: Icons.route_outlined,
              label: 'DISTANCE',
              value: _formatDistance(tripData['distance']),
            ),
            const SizedBox(height: 12),
            _buildInfoTile(
              icon: Icons.schedule_outlined,
              label: 'CREATED',
              value: _formatTimestamp(tripData['created_at']),
            ),
            const SizedBox(height: 12),
            _buildInfoTile(
              icon: Icons.check_circle_outline,
              label: 'COMPLETED',
              value: _formatTimestamp(
                tripData['completed_at'] ?? tripData['timestamp'],
              ),
            ),
            const SizedBox(height: 12),
            _buildInfoTile(
              icon: Icons.badge_outlined,
              label: 'DRIVER ID',
              value: _value(tripData['driver_id']),
            ),
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _gold,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
                onPressed: () => _openReportFlow(context),
                icon: const Icon(Icons.support_agent),
                label: const Text(
                  'Report this trip',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

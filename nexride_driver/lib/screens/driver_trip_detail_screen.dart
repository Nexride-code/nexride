import 'package:flutter/material.dart';

import '../services/driver_finance_service.dart';
import '../services/user_support_ticket_service.dart';

class DriverTripDetailScreen extends StatelessWidget {
  const DriverTripDetailScreen({
    super.key,
    required this.tripId,
    required this.driverId,
    required this.tripData,
  });

  final String tripId;
  final String driverId;
  final Map<String, dynamic> tripData;

  static const Color _gold = Color(0xFFB57A2A);

  bool get _isOrder => tripData['type']?.toString() == 'order';

  String _formatCurrency(dynamic rawFare) {
    final value = rawFare is num
        ? rawFare.toDouble()
        : double.tryParse(rawFare?.toString() ?? '') ?? 0;
    return '₦${value.toStringAsFixed(value.truncateToDouble() == value ? 0 : 2)}';
  }

  String _formatTimestamp(dynamic rawValue) {
    final timestamp = rawValue is num
        ? rawValue.toInt()
        : int.tryParse(rawValue?.toString() ?? '');
    if (timestamp == null || timestamp <= 0) {
      return 'Not available';
    }
    return DriverFinanceService.formatDateTime(
      DateTime.fromMillisecondsSinceEpoch(timestamp).toLocal(),
    );
  }

  String _value(dynamic rawValue) {
    final value = rawValue?.toString().trim() ?? '';
    return value.isEmpty ? 'Not available' : value;
  }

  Future<void> _contactSupport(BuildContext context) async {
    final serviceType = tripData['service_type']?.toString() ??
        tripData['serviceType']?.toString() ??
        '';
    final status = tripData['status']?.toString() ?? '';
    final riderId = tripData['riderId']?.toString() ??
        tripData['rider_id']?.toString() ??
        '';
    final orderId = _isOrder ? tripId : tripData['orderId']?.toString() ?? '';
    final rideId = _isOrder ? '' : tripId;
    await const UserSupportTicketService().createTicket(
      createdByUserId: driverId,
      createdByType: 'driver',
      subject: _isOrder
          ? 'Support request for order $tripId'
          : 'Support request for trip $tripId',
      message:
          'Driver requested support.\n'
          'rideId=${rideId.isEmpty ? 'n/a' : rideId}\n'
          'orderId=${orderId.isEmpty ? 'n/a' : orderId}\n'
          'userId=${riderId.isEmpty ? driverId : riderId}\n'
          'driverId=$driverId\n'
          'serviceType=$serviceType\n'
          'status=$status',
      category: 'trip_issue',
      priority: 'normal',
      tripId: rideId,
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Support request sent.')),
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
        title: Text(_isOrder ? 'Order details' : 'Trip details'),
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
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
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
                    status,
                    style: const TextStyle(color: Colors.white70, fontSize: 15),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '${_isOrder ? 'Order' : 'Trip'} ID: $tripId',
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            _InfoTile(
              icon: Icons.my_location,
              label: 'PICKUP',
              value: _value(tripData['pickup_address']),
            ),
            const SizedBox(height: 12),
            _InfoTile(
              icon: Icons.location_on_outlined,
              label: 'DESTINATION',
              value: _value(tripData['destination_address']),
            ),
            const SizedBox(height: 12),
            _InfoTile(
              icon: Icons.schedule_outlined,
              label: 'CREATED',
              value: _formatTimestamp(
                tripData['created_at'] ?? tripData['createdAt'],
              ),
            ),
            const SizedBox(height: 12),
            _InfoTile(
              icon: Icons.check_circle_outline,
              label: 'COMPLETED',
              value: _formatTimestamp(
                tripData['completed_at'] ??
                    tripData['completedAt'] ??
                    tripData['cancelled_at'] ??
                    tripData['cancelledAt'],
              ),
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
                onPressed: () => _contactSupport(context),
                icon: const Icon(Icons.support_agent),
                label: Text(
                  _isOrder
                      ? 'Contact support about this order'
                      : 'Contact support about this trip',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoTile extends StatelessWidget {
  const _InfoTile({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon),
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
}

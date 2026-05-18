import 'package:flutter/material.dart';

import '../admin_config.dart';
import '../models/admin_models.dart';
import '../services/admin_data_service.dart';
import 'admin_components.dart';

/// Opens admin records from System Health drill-down actions.
class AdminHealthDrilldownNav {
  AdminHealthDrilldownNav._();

  static Map<String, dynamic> _mapOf(Object? raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return <String, dynamic>{};
  }

  static Future<void> showRecordSheet({
    required BuildContext context,
    required String title,
    required Map<String, dynamic> fields,
    List<String> actions = const <String>[],
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext ctx) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.75,
          minChildSize: 0.4,
          maxChildSize: 0.92,
          builder: (_, ScrollController sc) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              child: ListView(
                controller: sc,
                children: <Widget>[
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: AdminThemeTokens.ink,
                    ),
                  ),
                  const SizedBox(height: 12),
                  ...fields.entries.map(
                    (MapEntry<String, dynamic> e) => Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: SelectableText(
                        '${e.key}: ${e.value}',
                        style: const TextStyle(fontSize: 12, height: 1.35),
                      ),
                    ),
                  ),
                  if (actions.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 12),
                    Text(
                      'Actions: ${actions.join(', ')}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: AdminThemeTokens.slate,
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        );
      },
    );
  }

  static Future<void> openTripDetail(
    BuildContext context,
    AdminDataService dataService,
    String tripId,
  ) async {
    final id = tripId.trim();
    if (id.isEmpty) return;
    final data = await dataService.fetchTripDetailForAdmin(id);
    if (!context.mounted) return;
    if (data == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not load trip $id')),
      );
      return;
    }
    final record = _mapOf(data['ride']).isNotEmpty
        ? _mapOf(data['ride'])
        : _mapOf(data['delivery']);
    final fields = <String, dynamic>{
      'trip_id': id,
      'trip_kind': data['trip_kind'],
      ...record,
    };
    await showRecordSheet(
      context: context,
      title: 'Trip $id',
      fields: fields,
    );
  }

  static AdminRiderRecord minimalRider(String id) {
    return AdminRiderRecord(
      id: id,
      name: id,
      phone: '',
      email: '',
      city: '',
      status: 'unknown',
      verificationStatus: 'unknown',
      riskStatus: 'unknown',
      paymentStatus: 'unknown',
      profileCompleted: false,
      createdAt: null,
      lastActiveAt: null,
      walletBalance: 0,
      tripSummary: const AdminTripSummary(
        totalTrips: 0,
        completedTrips: 0,
        cancelledTrips: 0,
      ),
      rating: 0,
      ratingCount: 0,
      outstandingFeesNgn: 0,
      rawData: const <String, dynamic>{},
    );
  }

  static AdminSupportTicketListItem minimalSupportTicket(String id) {
    return AdminSupportTicketListItem(
      id: id,
      status: 'open',
      subject: id,
      rideId: '',
      createdByUserId: '',
      updatedAtMs: 0,
      createdAtMs: 0,
      raw: const <String, dynamic>{},
    );
  }
}

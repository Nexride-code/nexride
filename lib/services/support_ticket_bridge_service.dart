import 'package:firebase_database/firebase_database.dart' as rtdb;

class SupportTicketBridgeService {
  const SupportTicketBridgeService({rtdb.FirebaseDatabase? database})
    : _database = database;

  final rtdb.FirebaseDatabase? _database;

  rtdb.FirebaseDatabase get database =>
      _database ?? rtdb.FirebaseDatabase.instance;
  rtdb.DatabaseReference get _rootRef => database.ref();
  rtdb.DatabaseReference get _ticketsRef => _rootRef.child('support_tickets');

  Future<void> upsertTripDisputeTicket({
    required String sourceReference,
    required String rideId,
    required String riderId,
    required String driverId,
    required String serviceType,
    required String reason,
    required String message,
    required String source,
  }) async {
    final documentId = 'trip_dispute__$sourceReference';
    final existing = await _ticketsRef.child(documentId).get();
    if (existing.exists) {
      return;
    }

    final snapshots =
        await Future.wait<rtdb.DataSnapshot>(<Future<rtdb.DataSnapshot>>[
          _rootRef.child('ride_requests/$rideId').get(),
          _rootRef.child('users/$riderId').get(),
        ]);
    final ride = _map(snapshots[0].value);
    final rider = _map(snapshots[1].value);
    final riderVerification = _map(rider['verification']);
    final riderTrust = _map(rider['trustSummary']);

    final normalizedReason = reason.trim().toLowerCase();
    final subject = 'Trip dispute: ${_titleCase(reason)}';
    final body = message.trim().isEmpty
        ? 'Rider submitted a trip dispute for this ride.'
        : message.trim();

    final requesterProfile = <String, dynamic>{
      'userId': riderId,
      'userType': 'rider',
      'name': _firstText(<dynamic>[
        ride['rider_name'],
        rider['name'],
      ], fallback: 'Rider'),
      'phone': _firstText(<dynamic>[ride['rider_phone'], rider['phone']]),
      'email': _firstText(<dynamic>[rider['email']]),
      'city': _firstText(<dynamic>[ride['city'], rider['city']]),
      'status': _firstText(<dynamic>[
        riderTrust['accountStatus'],
        rider['status'],
      ], fallback: 'active'),
      'verificationStatus': _firstText(<dynamic>[
        riderVerification['overallStatus'],
        riderTrust['verificationStatus'],
      ], fallback: 'unknown'),
      'rating': _toDouble(riderTrust['rating']) ?? 0,
      'ratingCount': _toInt(riderTrust['ratingCount']) ?? 0,
    };

    final counterpartyProfile = <String, dynamic>{
      'userId': driverId,
      'userType': 'driver',
      'name': _firstText(<dynamic>[ride['driver_name']], fallback: 'Driver'),
      'phone': _firstText(<dynamic>[ride['driver_phone']]),
      'email': '',
      'city': _firstText(<dynamic>[ride['city']]),
      'status': _firstText(<dynamic>[
        ride['driver_status'],
      ], fallback: 'active'),
      'verificationStatus': _firstText(<dynamic>[
        ride['driver_verification_status'],
      ], fallback: 'unknown'),
      'rating': _toDouble(ride['driver_rating']) ?? 0,
      'ratingCount': _toInt(ride['driver_rating_count']) ?? 0,
    };

    final tripSnapshot = <String, dynamic>{
      'tripId': rideId,
      'rideId': rideId,
      'status': _firstText(<dynamic>[ride['status']], fallback: 'unknown'),
      'city': _firstText(<dynamic>[ride['city']]),
      'serviceType': _firstText(<dynamic>[serviceType, ride['service_type']]),
      'pickupAddress': _firstText(<dynamic>[
        ride['pickup_address'],
        ride['pickup'],
      ]),
      'destinationAddress': _firstText(<dynamic>[
        ride['destination_address'],
        ride['destination'],
        ride['final_destination'],
      ]),
      'paymentMethod': _firstText(<dynamic>[
        ride['payment_method'],
        ride['paymentMethod'],
      ]),
      'fareAmount':
          _toDouble(ride['fare']) ?? _toDouble(ride['grossFare']) ?? 0,
      'distanceKm': _toDouble(ride['distance_km']) ?? 0,
      'durationMinutes': _toDouble(ride['duration_minutes']) ?? 0,
      'riderId': riderId,
      'riderName': requesterProfile['name'],
      'driverId': driverId,
      'driverName': counterpartyProfile['name'],
      'disputeReason': reason,
      'source': source,
      'createdAt': ride['createdAt'],
      'completedAt': ride['completedAt'],
    };

    final ticketId = _ticketCode('TD', sourceReference);
    final tags = <String>[
      'trip_dispute',
      normalizedReason.replaceAll(' ', '_'),
      source.trim().toLowerCase().replaceAll(' ', '_'),
      serviceType.trim().toLowerCase(),
    ].where((String value) => value.isNotEmpty).toList(growable: false);

    await _ticketsRef.child(documentId).set(<String, dynamic>{
      'ticketId': ticketId,
      'createdByUserId': riderId,
      'createdByType': 'rider',
      'category': _categoryFromReason(normalizedReason),
      'priority': _priorityFromReason(normalizedReason),
      'status': 'open',
      'subject': subject,
      'message': body,
      'attachments': const <String>[],
      'tripId': rideId,
      'assignedToStaffId': '',
      'assignedToStaffName': 'Unassigned',
      'createdAt': rtdb.ServerValue.timestamp,
      'updatedAt': rtdb.ServerValue.timestamp,
      'lastReplyAt': rtdb.ServerValue.timestamp,
      'lastExternalReplyAt': rtdb.ServerValue.timestamp,
      'lastSupportReplyAt': null,
      'lastPublicSenderRole': 'rider',
      'requesterSeenAt': rtdb.ServerValue.timestamp,
      'resolution': '',
      'internalNotes': const <String>[],
      'tags': tags,
      'escalated': false,
      'firstResponseAt': null,
      'resolvedAt': null,
      'closedAt': null,
      'replyCount': 1,
      'internalNoteCount': 0,
      'sourceType': 'trip_dispute',
      'sourceReference': sourceReference,
      'requesterProfile': requesterProfile,
      'counterpartyProfile': counterpartyProfile,
      'tripSnapshot': tripSnapshot,
      'staffSeenAt': const <String, dynamic>{},
    });
    await _rootRef
        .child('support_ticket_messages/$documentId/initial')
        .set(<String, dynamic>{
          'ticketDocumentId': documentId,
          'senderId': riderId,
          'senderRole': 'rider',
          'senderName': requesterProfile['name'],
          'message': body,
          'attachmentUrl': '',
          'visibility': 'public',
          'createdAt': rtdb.ServerValue.timestamp,
        });
  }

  String _ticketCode(String prefix, String sourceReference) {
    final normalized = sourceReference
        .replaceAll(RegExp(r'[^A-Za-z0-9]'), '')
        .toUpperCase();
    final suffix = normalized.length <= 6
        ? normalized
        : normalized.substring(normalized.length - 6);
    return 'SUP-$prefix-$suffix';
  }

  String _categoryFromReason(String reason) {
    if (reason.contains('safety')) {
      return 'safety';
    }
    if (reason.contains('fare')) {
      return 'fare';
    }
    if (reason.contains('lost')) {
      return 'lost_item';
    }
    if (reason.contains('behavior')) {
      return 'behavior';
    }
    return 'trip_dispute';
  }

  String _priorityFromReason(String reason) {
    if (reason.contains('safety')) {
      return 'urgent';
    }
    if (reason.contains('abuse')) {
      return 'high';
    }
    if (reason.contains('fare')) {
      return 'medium';
    }
    return 'medium';
  }

  String _titleCase(String value) {
    return value
        .split(' ')
        .where((String part) => part.trim().isNotEmpty)
        .map(
          (String part) =>
              '${part[0].toUpperCase()}${part.substring(1).toLowerCase()}',
        )
        .join(' ');
  }

  Map<String, dynamic> _map(dynamic value) {
    if (value is Map) {
      return value.map<String, dynamic>(
        (dynamic key, dynamic entry) => MapEntry(key.toString(), entry),
      );
    }
    return <String, dynamic>{};
  }

  String _firstText(Iterable<dynamic> values, {String fallback = ''}) {
    for (final value in values) {
      final text = value?.toString().trim() ?? '';
      if (text.isNotEmpty) {
        return text;
      }
    }
    return fallback;
  }

  double? _toDouble(dynamic value) {
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '');
  }

  int? _toInt(dynamic value) {
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '');
  }
}

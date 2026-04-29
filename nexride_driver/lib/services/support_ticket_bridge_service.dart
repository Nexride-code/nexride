import 'package:firebase_database/firebase_database.dart' as rtdb;

class SupportTicketBridgeService {
  const SupportTicketBridgeService({
    rtdb.FirebaseDatabase? database,
  }) : _database = database;

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
    required String createdByType,
  }) async {
    final documentId = 'trip_dispute__$sourceReference';
    final existing = await _ticketsRef.child(documentId).get();
    if (existing.exists) {
      return;
    }

    final snapshots =
        await Future.wait<rtdb.DataSnapshot>(<Future<rtdb.DataSnapshot>>[
      _rootRef.child('ride_requests/$rideId').get(),
      _rootRef.child('drivers/$driverId').get(),
    ]);
    final ride = _map(snapshots[0].value);
    final driver = _map(snapshots[1].value);
    final driverVerification = _map(driver['verification']);
    final pricingSnapshot =
        _map(ride['pricing_snapshot'] ?? ride['pricingSnapshot']);
    final paymentPlaceholder =
        _map(ride['payment_placeholder'] ?? ride['paymentPlaceholder']);

    final normalizedReason = reason.trim().toLowerCase();
    final subject = 'Trip dispute: ${_titleCase(reason)}';
    final body = message.trim().isEmpty
        ? 'Driver submitted a trip dispute for this ride.'
        : message.trim();

    final requesterProfile = <String, dynamic>{
      'userId': driverId,
      'userType': 'driver',
      'name': _firstText(<dynamic>[driver['name'], ride['driver_name']],
          fallback: 'Driver'),
      'phone': _firstText(<dynamic>[driver['phone'], ride['driver_phone']]),
      'email': _firstText(<dynamic>[driver['email']]),
      'city': _firstText(<dynamic>[driver['city'], ride['city']]),
      'status': _firstText(<dynamic>[driver['status']], fallback: 'active'),
      'verificationStatus': _firstText(
        <dynamic>[
          driverVerification['overallStatus'],
          driver['verificationStatus'],
        ],
        fallback: 'unknown',
      ),
      'rating': _toDouble(driver['rating']) ?? 0,
      'ratingCount': _toInt(driver['ratingCount']) ?? 0,
    };

    final counterpartyProfile = <String, dynamic>{
      'userId': riderId,
      'userType': 'rider',
      'name': _firstText(<dynamic>[ride['rider_name']], fallback: 'Rider'),
      'phone': _firstText(<dynamic>[ride['rider_phone']]),
      'email': '',
      'city': _firstText(<dynamic>[ride['city']]),
      'status': _firstText(<dynamic>[ride['rider_status']], fallback: 'active'),
      'verificationStatus': _firstText(
        <dynamic>[ride['rider_verification_status']],
        fallback: 'unknown',
      ),
      'rating': _toDouble(ride['rider_rating']) ?? 0,
      'ratingCount': _toInt(ride['rider_rating_count']) ?? 0,
    };

    final tripSnapshot = <String, dynamic>{
      'tripId': rideId,
      'rideId': rideId,
      'status': _firstText(<dynamic>[ride['status']], fallback: 'unknown'),
      'city': _firstText(<dynamic>[ride['city']]),
      'serviceType': _firstText(<dynamic>[serviceType, ride['service_type']]),
      'pickupAddress':
          _firstText(<dynamic>[ride['pickup_address'], ride['pickup']]),
      'destinationAddress': _firstText(
        <dynamic>[
          ride['destination_address'],
          ride['destination'],
          ride['final_destination'],
        ],
      ),
      'paymentMethod':
          _firstText(<dynamic>[ride['payment_method'], ride['paymentMethod'], paymentPlaceholder['method'], paymentPlaceholder['provider'], paymentPlaceholder['status']]),
      'fareAmount': _toDouble(ride['fare']) ??
          _toDouble(ride['grossFare']) ??
          _toDouble(ride['fareEstimate']) ??
          _toDouble(ride['fare_estimate']) ??
          _toDouble(pricingSnapshot['fareEstimate']) ??
          _toDouble(pricingSnapshot['fare_estimate']) ??
          0,
      'distanceKm': _toDouble(ride['distance_km']) ?? 0,
      'durationMinutes': _toDouble(ride['duration_minutes']) ?? 0,
      'riderId': riderId,
      'riderName': counterpartyProfile['name'],
      'driverId': driverId,
      'driverName': requesterProfile['name'],
      'disputeReason': reason,
      'source': source,
      'createdAt': ride['createdAt'],
      'completedAt': ride['completedAt'],
    };

    final ticketId = _ticketCode('TD', sourceReference);
    final tags = <String>[
      'trip_dispute',
      createdByType,
      normalizedReason.replaceAll(' ', '_'),
      source.trim().toLowerCase().replaceAll(' ', '_'),
      serviceType.trim().toLowerCase(),
    ].where((String value) => value.isNotEmpty).toList(growable: false);

    await _ticketsRef.child(documentId).set(<String, dynamic>{
      'ticketId': ticketId,
      'createdByUserId': createdByType == 'driver' ? driverId : riderId,
      'createdByType': createdByType,
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
      'lastPublicSenderRole': createdByType,
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
      'senderId': createdByType == 'driver' ? driverId : riderId,
      'senderRole': createdByType,
      'senderName': requesterProfile['name'],
      'message': body,
      'attachmentUrl': '',
      'visibility': 'public',
      'createdAt': rtdb.ServerValue.timestamp,
    });
  }

  Future<void> upsertRiderReportTicket({
    required String sourceReference,
    required String rideId,
    required String riderId,
    required String driverId,
    required String serviceType,
    required String reason,
    required String message,
    required String rideStatus,
    required String paymentMethod,
    required int amountDueNgn,
    required String evidenceSummary,
    required String evidenceReference,
    required List<String> evidenceTypes,
  }) async {
    final documentId = 'rider_report__$sourceReference';
    final existing = await _ticketsRef.child(documentId).get();
    if (existing.exists) {
      return;
    }

    final snapshots =
        await Future.wait<rtdb.DataSnapshot>(<Future<rtdb.DataSnapshot>>[
      _rootRef.child('ride_requests/$rideId').get(),
      _rootRef.child('drivers/$driverId').get(),
    ]);
    final ride = _map(snapshots[0].value);
    final driver = _map(snapshots[1].value);
    final driverVerification = _map(driver['verification']);
    final pricingSnapshot =
        _map(ride['pricing_snapshot'] ?? ride['pricingSnapshot']);
    final paymentPlaceholder =
        _map(ride['payment_placeholder'] ?? ride['paymentPlaceholder']);

    final normalizedReason = reason.trim().toLowerCase();
    final subject = 'Driver report: ${_titleCase(reason)}';
    final body = message.trim().isEmpty
        ? 'Driver submitted a rider report for support review.'
        : message.trim();

    final requesterProfile = <String, dynamic>{
      'userId': driverId,
      'userType': 'driver',
      'name': _firstText(<dynamic>[driver['name'], ride['driver_name']],
          fallback: 'Driver'),
      'phone': _firstText(<dynamic>[driver['phone'], ride['driver_phone']]),
      'email': _firstText(<dynamic>[driver['email']]),
      'city': _firstText(<dynamic>[driver['city'], ride['city']]),
      'status': _firstText(<dynamic>[driver['status']], fallback: 'active'),
      'verificationStatus': _firstText(
        <dynamic>[
          driverVerification['overallStatus'],
          driver['verificationStatus'],
        ],
        fallback: 'unknown',
      ),
      'rating': _toDouble(driver['rating']) ?? 0,
      'ratingCount': _toInt(driver['ratingCount']) ?? 0,
    };

    final counterpartyProfile = <String, dynamic>{
      'userId': riderId,
      'userType': 'rider',
      'name': _firstText(<dynamic>[ride['rider_name']], fallback: 'Rider'),
      'phone': _firstText(<dynamic>[ride['rider_phone']]),
      'email': '',
      'city': _firstText(<dynamic>[ride['city']]),
      'status': _firstText(<dynamic>[ride['rider_status']], fallback: 'active'),
      'verificationStatus': _firstText(
        <dynamic>[ride['rider_verification_status']],
        fallback: 'unknown',
      ),
      'rating': _toDouble(ride['rider_rating']) ?? 0,
      'ratingCount': _toInt(ride['rider_rating_count']) ?? 0,
    };

    final tripSnapshot = <String, dynamic>{
      'tripId': rideId,
      'rideId': rideId,
      'status': rideStatus,
      'city': _firstText(<dynamic>[ride['city']]),
      'serviceType': _firstText(<dynamic>[serviceType, ride['service_type']]),
      'pickupAddress':
          _firstText(<dynamic>[ride['pickup_address'], ride['pickup']]),
      'destinationAddress': _firstText(
        <dynamic>[
          ride['destination_address'],
          ride['destination'],
          ride['final_destination'],
        ],
      ),
      'paymentMethod': paymentMethod,
      'fareAmount': _toDouble(ride['fare']) ??
          _toDouble(ride['grossFare']) ??
          _toDouble(ride['fareEstimate']) ??
          _toDouble(ride['fare_estimate']) ??
          _toDouble(pricingSnapshot['fareEstimate']) ??
          _toDouble(pricingSnapshot['fare_estimate']) ??
          0,
      'paymentPlaceholderMethod': _firstText(
        <dynamic>[
          paymentPlaceholder['method'],
          paymentPlaceholder['provider'],
          paymentPlaceholder['status'],
        ],
      ),
      'distanceKm': _toDouble(ride['distance_km']) ?? 0,
      'durationMinutes': _toDouble(ride['duration_minutes']) ?? 0,
      'riderId': riderId,
      'riderName': counterpartyProfile['name'],
      'driverId': driverId,
      'driverName': requesterProfile['name'],
      'disputeReason': reason,
      'source': 'driver_rider_report',
      'amountDueNgn': amountDueNgn,
      'evidenceSummary': evidenceSummary,
      'evidenceReference': evidenceReference,
      'evidenceTypes': evidenceTypes,
    };

    final tags = <String>[
      'rider_report',
      normalizedReason.replaceAll(' ', '_'),
      serviceType.trim().toLowerCase(),
      if (amountDueNgn > 0) 'payment_due',
      ...evidenceTypes.map((String type) => type.trim().toLowerCase()),
    ].where((String value) => value.isNotEmpty).toList(growable: false);

    await _ticketsRef.child(documentId).set(<String, dynamic>{
      'ticketId': _ticketCode('RR', sourceReference),
      'createdByUserId': driverId,
      'createdByType': 'driver',
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
      'lastPublicSenderRole': 'driver',
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
      'sourceType': 'rider_report',
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
      'senderId': driverId,
      'senderRole': 'driver',
      'senderName': requesterProfile['name'],
      'message': body,
      'attachmentUrl': '',
      'visibility': 'public',
      'createdAt': rtdb.ServerValue.timestamp,
    });
  }

  String _ticketCode(String prefix, String sourceReference) {
    final normalized =
        sourceReference.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
    final suffix = normalized.length <= 6
        ? normalized
        : normalized.substring(normalized.length - 6);
    return 'SUP-$prefix-$suffix';
  }

  String _categoryFromReason(String reason) {
    if (reason.contains('safety') || reason.contains('abuse')) {
      return 'safety';
    }
    if (reason.contains('non-payment') || reason.contains('payment')) {
      return 'payment';
    }
    if (reason.contains('fare')) {
      return 'fare';
    }
    return 'driver_report';
  }

  String _priorityFromReason(String reason) {
    if (reason.contains('safety') || reason.contains('abuse')) {
      return 'urgent';
    }
    if (reason.contains('non-payment')) {
      return 'high';
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

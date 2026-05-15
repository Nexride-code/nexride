import 'package:firebase_database/firebase_database.dart' as rtdb;
import 'package:flutter/foundation.dart';

import '../support/realtime_database_error_support.dart';

@immutable
class UserSupportInboxSummary {
  const UserSupportInboxSummary({
    required this.totalTickets,
    required this.openTickets,
    required this.unreadReplies,
  });

  final int totalTickets;
  final int openTickets;
  final int unreadReplies;
}

@immutable
class UserSupportTripOption {
  const UserSupportTripOption({
    required this.tripId,
    required this.title,
    required this.subtitle,
    required this.status,
    this.updatedAt,
  });

  final String tripId;
  final String title;
  final String subtitle;
  final String status;
  final DateTime? updatedAt;
}

@immutable
class UserSupportTripSnapshot {
  const UserSupportTripSnapshot({
    required this.tripId,
    required this.status,
    required this.serviceType,
    required this.city,
    required this.pickupAddress,
    required this.destinationAddress,
    required this.paymentMethod,
    required this.fareAmount,
    required this.driverName,
    required this.riderName,
    required this.rawData,
  });

  final String tripId;
  final String status;
  final String serviceType;
  final String city;
  final String pickupAddress;
  final String destinationAddress;
  final String paymentMethod;
  final double fareAmount;
  final String driverName;
  final String riderName;
  final Map<String, dynamic> rawData;

  factory UserSupportTripSnapshot.fromMap(
    Map<String, dynamic> data, {
    required String fallbackTripId,
  }) {
    return UserSupportTripSnapshot(
      tripId: _text(data['tripId']).isNotEmpty
          ? _text(data['tripId'])
          : fallbackTripId,
      status: _text(data['status']),
      serviceType: _text(data['serviceType']),
      city: _text(data['city']),
      pickupAddress: _text(data['pickupAddress']),
      destinationAddress: _text(data['destinationAddress']),
      paymentMethod: _text(data['paymentMethod']),
      fareAmount: _toDouble(data['fareAmount']) ?? 0,
      driverName: _text(data['driverName']),
      riderName: _text(data['riderName']),
      rawData: data,
    );
  }
}

@immutable
class UserSupportTicketSummary {
  const UserSupportTicketSummary({
    required this.documentId,
    required this.ticketId,
    required this.createdByUserId,
    required this.createdByType,
    required this.subject,
    required this.message,
    required this.category,
    required this.priority,
    required this.status,
    required this.tripId,
    required this.createdAt,
    required this.updatedAt,
    required this.lastReplyAt,
    required this.lastSupportReplyAt,
    required this.requesterSeenAt,
    required this.lastPublicSenderRole,
    required this.resolution,
    required this.requesterName,
    required this.tripSnapshot,
    required this.rawData,
  });

  final String documentId;
  final String ticketId;
  final String createdByUserId;
  final String createdByType;
  final String subject;
  final String message;
  final String category;
  final String priority;
  final String status;
  final String tripId;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? lastReplyAt;
  final DateTime? lastSupportReplyAt;
  final DateTime? requesterSeenAt;
  final String lastPublicSenderRole;
  final String resolution;
  final String requesterName;
  final UserSupportTripSnapshot tripSnapshot;
  final Map<String, dynamic> rawData;

  bool get isResolved => status == 'resolved' || status == 'closed';

  bool get hasUnreadSupportReply {
    final supportReplyAt = lastSupportReplyAt ??
        (_isSupportRole(lastPublicSenderRole) ? lastReplyAt : null);
    if (supportReplyAt == null || isResolved) {
      return false;
    }
    final seenAt = requesterSeenAt;
    return seenAt == null || supportReplyAt.isAfter(seenAt);
  }

  factory UserSupportTicketSummary.fromRecord(
    String documentId,
    dynamic value,
  ) {
    final data = _map(value);
    return UserSupportTicketSummary(
      documentId: documentId,
      ticketId: _text(data['ticketId']).isNotEmpty
          ? _text(data['ticketId'])
          : documentId,
      createdByUserId: _text(data['createdByUserId']),
      createdByType: _text(data['createdByType']),
      subject: _text(data['subject']),
      message: _text(data['message']),
      category: _text(data['category']),
      priority: _text(data['priority']),
      status: _text(data['status']),
      tripId: _text(data['tripId']),
      createdAt: _dateTimeFromDynamic(data['createdAt']),
      updatedAt: _dateTimeFromDynamic(data['updatedAt']),
      lastReplyAt: _dateTimeFromDynamic(data['lastReplyAt']),
      lastSupportReplyAt: _dateTimeFromDynamic(data['lastSupportReplyAt']),
      requesterSeenAt: _dateTimeFromDynamic(data['requesterSeenAt']),
      lastPublicSenderRole: _text(data['lastPublicSenderRole']),
      resolution: _text(data['resolution']),
      requesterName: _firstText(
        <dynamic>[
          _map(data['requesterProfile'])['name'],
          data['createdByName'],
        ],
        fallback: 'NexRide user',
      ),
      tripSnapshot: UserSupportTripSnapshot.fromMap(
        _map(data['tripSnapshot']),
        fallbackTripId: _text(data['tripId']),
      ),
      rawData: data,
    );
  }
}

@immutable
class UserSupportTicketMessage {
  const UserSupportTicketMessage({
    required this.documentId,
    required this.senderId,
    required this.senderRole,
    required this.senderName,
    required this.message,
    required this.attachmentUrl,
    required this.visibility,
    required this.createdAt,
  });

  final String documentId;
  final String senderId;
  final String senderRole;
  final String senderName;
  final String message;
  final String attachmentUrl;
  final String visibility;
  final DateTime? createdAt;

  bool get isPublic => visibility != 'internal';
  bool get isFromSupport => _isSupportRole(senderRole);

  factory UserSupportTicketMessage.fromRecord(
    String documentId,
    dynamic value,
  ) {
    final data = _map(value);
    return UserSupportTicketMessage(
      documentId: documentId,
      senderId: _text(data['senderId']),
      senderRole: _text(data['senderRole']),
      senderName: _firstText(
        <dynamic>[data['senderName'], data['displayName']],
        fallback: 'NexRide',
      ),
      message: _text(data['message']),
      attachmentUrl: _text(data['attachmentUrl']),
      visibility: _firstText(<dynamic>[data['visibility']], fallback: 'public'),
      createdAt: _dateTimeFromDynamic(data['createdAt']),
    );
  }
}

class UserSupportTicketService {
  const UserSupportTicketService({
    rtdb.FirebaseDatabase? database,
  }) : _database = database;

  final rtdb.FirebaseDatabase? _database;

  rtdb.FirebaseDatabase get database =>
      _database ?? rtdb.FirebaseDatabase.instance;
  rtdb.DatabaseReference get _rootRef => database.ref();
  rtdb.DatabaseReference get _ticketsRef => _rootRef.child('support_tickets');
  rtdb.DatabaseReference get _messagesRef =>
      _rootRef.child('support_ticket_messages');

  Stream<List<UserSupportTicketSummary>> watchOwnTickets({
    required String userId,
    required String createdByType,
  }) {
    final normalizedType = _normalizeCreatedByType(createdByType);
    logRealtimeDatabaseStreamSubscription(
      source: 'driver_user_support.watch_own_tickets',
      path:
          'support_tickets[orderByChild=createdByUserId,equalTo=${userId.trim()}]',
    );
    return _ticketOwnerQuery(userId).limitToLast(200).onValue.map((rtdb.DatabaseEvent event) {
      final tickets = _map(event.snapshot.value)
          .entries
          .map(
            (MapEntry<String, dynamic> entry) =>
                UserSupportTicketSummary.fromRecord(entry.key, entry.value),
          )
          .where(
            (UserSupportTicketSummary ticket) =>
                ticket.createdByType == normalizedType,
          )
          .toList()
        ..sort(
          (UserSupportTicketSummary a, UserSupportTicketSummary b) =>
              (b.updatedAt?.millisecondsSinceEpoch ?? 0)
                  .compareTo(a.updatedAt?.millisecondsSinceEpoch ?? 0),
        );
      return tickets;
    });
  }

  Stream<UserSupportTicketSummary?> watchTicket({
    required String ticketDocumentId,
  }) {
    logRealtimeDatabaseStreamSubscription(
      source: 'driver_user_support.watch_ticket',
      path: 'support_tickets/${ticketDocumentId.trim()}',
    );
    return _ticketsRef
        .child(ticketDocumentId.trim())
        .onValue
        .map((rtdb.DatabaseEvent event) {
      final data = _map(event.snapshot.value);
      if (data.isEmpty) {
        return null;
      }
      return UserSupportTicketSummary.fromRecord(ticketDocumentId.trim(), data);
    });
  }

  Stream<List<UserSupportTicketMessage>> watchPublicMessages({
    required String ticketDocumentId,
  }) {
    logRealtimeDatabaseStreamSubscription(
      source: 'driver_user_support.watch_public_messages',
      path:
          'support_ticket_messages/${ticketDocumentId.trim()}[orderByChild=visibility,equalTo=public]',
    );
    return _messagesRef
        .child(ticketDocumentId.trim())
        .orderByChild('visibility')
        .equalTo('public')
        .onValue
        .map((rtdb.DatabaseEvent event) {
      final messages = _map(event.snapshot.value)
          .entries
          .map(
            (MapEntry<String, dynamic> entry) =>
                UserSupportTicketMessage.fromRecord(entry.key, entry.value),
          )
          .where((UserSupportTicketMessage message) => message.isPublic)
          .toList()
        ..sort(
          (UserSupportTicketMessage a, UserSupportTicketMessage b) =>
              (a.createdAt?.millisecondsSinceEpoch ?? 0)
                  .compareTo(b.createdAt?.millisecondsSinceEpoch ?? 0),
        );
      return messages;
    });
  }

  Future<UserSupportInboxSummary> fetchInboxSummary({
    required String userId,
    required String createdByType,
  }) async {
    final normalizedType = _normalizeCreatedByType(createdByType);
    final snapshot = await runOptionalRealtimeDatabaseRead<rtdb.DataSnapshot>(
      source: 'driver_user_support.fetch_inbox_summary',
      path:
          'support_tickets[orderByChild=createdByUserId,equalTo=${userId.trim()}]',
      action: () => _ticketOwnerQuery(userId).limitToLast(400).get(),
    );
    final tickets = _map(snapshot?.value)
        .entries
        .map(
          (MapEntry<String, dynamic> entry) =>
              UserSupportTicketSummary.fromRecord(entry.key, entry.value),
        )
        .where(
          (UserSupportTicketSummary ticket) =>
              ticket.createdByType == normalizedType,
        )
        .toList(growable: false);

    final summary = UserSupportInboxSummary(
      totalTickets: tickets.length,
      openTickets: tickets
          .where((UserSupportTicketSummary ticket) => !ticket.isResolved)
          .length,
      unreadReplies: tickets
          .where(
            (UserSupportTicketSummary ticket) => ticket.hasUnreadSupportReply,
          )
          .length,
    );

    await _syncSupportCounters(
      userId: userId,
      createdByType: normalizedType,
      summary: summary,
    );

    return summary;
  }

  Future<List<UserSupportTripOption>> fetchRecentTrips({
    required String userId,
    required String createdByType,
    int limit = 12,
  }) async {
    final normalizedType = _normalizeCreatedByType(createdByType);
    final normalizedUserId = userId.trim();
    final primaryPath = normalizedType == 'driver'
        ? 'driver_trips/$normalizedUserId'
        : 'rider_trips/$normalizedUserId';
    final fallbackPath =
        normalizedType == 'driver' ? 'drivers/$normalizedUserId/trips' : '';
    final ownerKey = normalizedType == 'driver' ? 'driver_id' : 'rider_id';
    final ownerAliasKey = normalizedType == 'driver' ? 'driverId' : 'riderId';
    final optionLimit = limit < 1 ? 1 : limit;
    final queryLimit = optionLimit * 4;
    final candidates = <String, _TripOptionCandidate>{};

    void mergeRawCollection(
      dynamic rawValue, {
      required String source,
    }) {
      final rawTrips = _recordEntriesFromDynamic(rawValue);
      for (final entry in rawTrips) {
        final candidate = _tripOptionCandidateFromRecord(
          entry.value,
          fallbackTripId: entry.key,
          source: source,
        );
        if (candidate == null) {
          continue;
        }
        final existing = candidates[candidate.option.tripId];
        if (existing == null || candidate.isBetterThan(existing)) {
          candidates[candidate.option.tripId] = candidate;
        }
      }
    }

    try {
      final snapshots =
          await Future.wait<rtdb.DataSnapshot?>(<Future<rtdb.DataSnapshot?>>[
        runOptionalRealtimeDatabaseRead<rtdb.DataSnapshot>(
          source: 'driver_user_support.fetch_recent_trips.primary',
          path: primaryPath,
          action: () => _rootRef.child(primaryPath).get(),
        ),
        if (fallbackPath.isNotEmpty)
          runOptionalRealtimeDatabaseRead<rtdb.DataSnapshot>(
            source: 'driver_user_support.fetch_recent_trips.fallback',
            path: fallbackPath,
            action: () => _rootRef.child(fallbackPath).get(),
          ),
        runOptionalRealtimeDatabaseRead<rtdb.DataSnapshot>(
          source: 'driver_user_support.fetch_recent_trips.ride_requests_owner',
          path:
              'ride_requests[orderByChild=$ownerKey,equalTo=$normalizedUserId,limitToLast=$queryLimit]',
          action: () => _rootRef
              .child('ride_requests')
              .orderByChild(ownerKey)
              .equalTo(normalizedUserId)
              .limitToLast(queryLimit)
              .get(),
        ),
        runOptionalRealtimeDatabaseRead<rtdb.DataSnapshot>(
          source:
              'driver_user_support.fetch_recent_trips.ride_requests_owner_alias',
          path:
              'ride_requests[orderByChild=$ownerAliasKey,equalTo=$normalizedUserId,limitToLast=$queryLimit]',
          action: () => _rootRef
              .child('ride_requests')
              .orderByChild(ownerAliasKey)
              .equalTo(normalizedUserId)
              .limitToLast(queryLimit)
              .get(),
        ),
        if (normalizedType == 'driver')
          runOptionalRealtimeDatabaseRead<rtdb.DataSnapshot>(
            source:
                'driver_user_support.fetch_recent_trips.trip_settlement_hooks_driverId',
            path:
                'trip_settlement_hooks[orderByChild=driverId,equalTo=$normalizedUserId,limitToLast=$queryLimit]',
            action: () => _rootRef
                .child('trip_settlement_hooks')
                .orderByChild('driverId')
                .equalTo(normalizedUserId)
                .limitToLast(queryLimit)
                .get(),
          ),
        if (normalizedType == 'driver')
          runOptionalRealtimeDatabaseRead<rtdb.DataSnapshot>(
            source:
                'driver_user_support.fetch_recent_trips.trip_settlement_hooks_driver_id',
            path:
                'trip_settlement_hooks[orderByChild=driver_id,equalTo=$normalizedUserId,limitToLast=$queryLimit]',
            action: () => _rootRef
                .child('trip_settlement_hooks')
                .orderByChild('driver_id')
                .equalTo(normalizedUserId)
                .limitToLast(queryLimit)
                .get(),
          ),
      ]);

      for (final snapshot in snapshots) {
        mergeRawCollection(
          snapshot?.value,
          source: snapshot?.ref.parent?.key ?? snapshot?.ref.key ?? 'rtdb',
        );
      }

      final options = candidates.values
          .map((candidate) => candidate.option)
          .toList(growable: false)
        ..sort(
          (UserSupportTripOption a, UserSupportTripOption b) =>
              (b.updatedAt?.millisecondsSinceEpoch ?? 0)
                  .compareTo(a.updatedAt?.millisecondsSinceEpoch ?? 0),
        );

      if (options.length <= optionLimit) {
        return options;
      }
      return options.take(optionLimit).toList(growable: false);
    } catch (_) {
      return const <UserSupportTripOption>[];
    }
  }

  Future<void> markTicketViewed({
    required String ticketDocumentId,
  }) async {
    await _rootRef.update(<String, dynamic>{
      'support_tickets/${ticketDocumentId.trim()}/requesterSeenAt':
          rtdb.ServerValue.timestamp,
    });
  }

  Future<String> createTicket({
    required String createdByUserId,
    required String createdByType,
    required String subject,
    required String message,
    required String category,
    required String priority,
    String tripId = '',
  }) async {
    final normalizedType = _normalizeCreatedByType(createdByType);
    final normalizedTripId = tripId.trim();
    final ticketKey = _ticketsRef.push().key ?? _fallbackKey();
    final requesterProfile = await _loadRequesterProfile(
      userId: createdByUserId.trim(),
      createdByType: normalizedType,
    );
    Map<String, dynamic> tripData = const <String, dynamic>{};
    if (normalizedTripId.isNotEmpty) {
      final snapshot = await runOptionalRealtimeDatabaseRead<rtdb.DataSnapshot>(
        source: 'driver_user_support.create_ticket_trip_lookup',
        path: 'ride_requests/$normalizedTripId',
        action: () => _rootRef.child('ride_requests/$normalizedTripId').get(),
      );
      tripData = _map(snapshot?.value);
    }
    final counterpartyProfile = _buildCounterpartyProfile(
      createdByType: normalizedType,
      tripData: tripData,
    );
    final tripSnapshot = _buildTripSnapshot(
      tripId: normalizedTripId,
      tripData: tripData,
    );
    final ticketId = _ticketCode(
      normalizedType == 'driver' ? 'DRV' : 'RDR',
      ticketKey,
    );

    await _ticketsRef.child(ticketKey).set(<String, dynamic>{
      'ticketId': ticketId,
      'createdByUserId': createdByUserId.trim(),
      'createdByType': normalizedType,
      'subject': subject.trim(),
      'message': message.trim(),
      'category': category.trim().toLowerCase(),
      'priority': priority.trim().toLowerCase(),
      'status': 'open',
      'attachments': const <String>[],
      'tripId': normalizedTripId,
      'assignedToStaffId': '',
      'assignedToStaffName': 'Unassigned',
      'createdAt': rtdb.ServerValue.timestamp,
      'updatedAt': rtdb.ServerValue.timestamp,
      'lastReplyAt': rtdb.ServerValue.timestamp,
      'lastExternalReplyAt': rtdb.ServerValue.timestamp,
      'lastSupportReplyAt': null,
      'requesterSeenAt': rtdb.ServerValue.timestamp,
      'firstResponseAt': null,
      'resolvedAt': null,
      'closedAt': null,
      'resolution': '',
      'internalNotes': const <String>[],
      'tags': <String>[
        normalizedType,
        category.trim().toLowerCase(),
        if (normalizedTripId.isNotEmpty) 'trip_linked',
      ],
      'escalated': false,
      'replyCount': 1,
      'internalNoteCount': 0,
      'lastPublicSenderRole': normalizedType,
      'sourceType': '${normalizedType}_support_ticket',
      'sourceReference': ticketKey,
      'requesterProfile': requesterProfile,
      'counterpartyProfile': counterpartyProfile,
      'tripSnapshot': tripSnapshot,
      'staffSeenAt': const <String, dynamic>{},
    });
    await _messagesRef.child(ticketKey).child('initial').set(<String, dynamic>{
      'ticketDocumentId': ticketKey,
      'senderId': createdByUserId.trim(),
      'senderRole': normalizedType,
      'senderName': _firstText(
        <dynamic>[requesterProfile['name']],
        fallback: 'NexRide user',
      ),
      'message': message.trim(),
      'attachmentUrl': '',
      'visibility': 'public',
      'createdAt': rtdb.ServerValue.timestamp,
    });

    return ticketKey;
  }

  Future<void> addReply({
    required String ticketDocumentId,
    required String senderId,
    required String senderRole,
    required String senderName,
    required String message,
  }) async {
    final trimmedMessage = message.trim();
    if (trimmedMessage.isEmpty) {
      throw StateError('Reply message is required.');
    }

    final normalizedRole = _normalizeCreatedByType(senderRole);
    final ticketPath = 'support_tickets/${ticketDocumentId.trim()}';
    final ticketSnapshot =
        await _ticketsRef.child(ticketDocumentId.trim()).get();
    final ticketData = _map(ticketSnapshot.value);
    if (ticketData.isEmpty) {
      throw StateError('This support ticket no longer exists.');
    }

    final currentStatus = _text(ticketData['status']).toLowerCase();
    final shouldReopen = currentStatus == 'pending_user' ||
        currentStatus == 'resolved' ||
        currentStatus == 'closed';
    final replyCount = _toInt(ticketData['replyCount']) ?? 0;
    final messageId = _messagesRef.child(ticketDocumentId.trim()).push().key ??
        _fallbackKey();

    await _rootRef.update(<String, dynamic>{
      'support_ticket_messages/${ticketDocumentId.trim()}/$messageId':
          <String, dynamic>{
        'ticketDocumentId': ticketDocumentId.trim(),
        'senderId': senderId.trim(),
        'senderRole': normalizedRole,
        'senderName': senderName.trim(),
        'message': trimmedMessage,
        'attachmentUrl': '',
        'visibility': 'public',
        'createdAt': rtdb.ServerValue.timestamp,
      },
      '$ticketPath/updatedAt': rtdb.ServerValue.timestamp,
      '$ticketPath/lastReplyAt': rtdb.ServerValue.timestamp,
      '$ticketPath/lastExternalReplyAt': rtdb.ServerValue.timestamp,
      '$ticketPath/requesterSeenAt': rtdb.ServerValue.timestamp,
      '$ticketPath/replyCount': replyCount + 1,
      '$ticketPath/lastPublicSenderRole': normalizedRole,
      if (shouldReopen) '$ticketPath/status': 'open',
      if (shouldReopen) '$ticketPath/resolvedAt': null,
      if (shouldReopen) '$ticketPath/closedAt': null,
    });
  }

  Future<void> _syncSupportCounters({
    required String userId,
    required String createdByType,
    required UserSupportInboxSummary summary,
  }) async {
    if (createdByType != 'driver') {
      return;
    }

    try {
      await _rootRef.update(<String, dynamic>{
        'drivers/${userId.trim()}/supportCounters/total': summary.totalTickets,
        'drivers/${userId.trim()}/supportCounters/open': summary.openTickets,
        'drivers/${userId.trim()}/supportCounters/unreadReplies':
            summary.unreadReplies,
        'drivers/${userId.trim()}/supportCounters/updated_at':
            rtdb.ServerValue.timestamp,
      });
    } catch (_) {
      // Live ticket reads remain the source of truth, so counter sync is best-effort.
    }
  }

  rtdb.Query _ticketOwnerQuery(String userId) {
    return _ticketsRef.orderByChild('createdByUserId').equalTo(userId.trim());
  }

  Future<Map<String, dynamic>> _loadRequesterProfile({
    required String userId,
    required String createdByType,
  }) async {
    final path =
        createdByType == 'driver' ? 'drivers/$userId' : 'users/$userId';
    final snapshot = await runOptionalRealtimeDatabaseRead<rtdb.DataSnapshot>(
      source: 'driver_user_support.load_requester_profile',
      path: path,
      action: () => _rootRef.child(path).get(),
    );
    final data = _map(snapshot?.value);
    final verification = _map(data['verification']);
    final trustSummary = _map(data['trustSummary']);

    return <String, dynamic>{
      'userId': userId,
      'userType': createdByType,
      'name': _firstText(
        <dynamic>[data['name'], data['fullName'], data['displayName']],
        fallback: createdByType == 'driver' ? 'Driver' : 'Rider',
      ),
      'phone': _firstText(<dynamic>[data['phone']]),
      'email': _firstText(<dynamic>[data['email']]),
      'city': _firstText(<dynamic>[data['city']]),
      'status': _firstText(<dynamic>[data['status']], fallback: 'active'),
      'verificationStatus': _firstText(
        <dynamic>[
          verification['overallStatus'],
          trustSummary['verificationStatus'],
          data['verificationStatus'],
        ],
        fallback: 'unknown',
      ),
      'rating': _toDouble(data['rating']) ??
          _toDouble(trustSummary['rating']) ??
          _toDouble(data['averageRating']) ??
          0,
      'ratingCount': _toInt(data['ratingCount']) ??
          _toInt(trustSummary['ratingCount']) ??
          0,
    };
  }

  Map<String, dynamic> _buildCounterpartyProfile({
    required String createdByType,
    required Map<String, dynamic> tripData,
  }) {
    if (tripData.isEmpty) {
      return <String, dynamic>{
        'userId': '',
        'userType': createdByType == 'driver' ? 'rider' : 'driver',
        'name': '',
        'phone': '',
        'email': '',
        'city': '',
        'status': '',
        'verificationStatus': '',
        'rating': 0,
        'ratingCount': 0,
      };
    }

    final isDriverTicket = createdByType == 'driver';
    return <String, dynamic>{
      'userId': _firstText(<dynamic>[
        tripData[isDriverTicket ? 'rider_id' : 'driver_id'],
        tripData[isDriverTicket ? 'riderId' : 'driverId'],
      ]),
      'userType': isDriverTicket ? 'rider' : 'driver',
      'name': _firstText(
        <dynamic>[
          tripData[isDriverTicket ? 'rider_name' : 'driver_name'],
          tripData[isDriverTicket ? 'riderName' : 'driverName'],
        ],
        fallback: isDriverTicket ? 'Rider' : 'Driver',
      ),
      'phone': _firstText(
        <dynamic>[tripData[isDriverTicket ? 'rider_phone' : 'driver_phone']],
      ),
      'email': '',
      'city': _firstText(<dynamic>[tripData['city']]),
      'status': _firstText(
        <dynamic>[tripData[isDriverTicket ? 'rider_status' : 'driver_status']],
        fallback: 'active',
      ),
      'verificationStatus': _firstText(
        <dynamic>[
          tripData[isDriverTicket
              ? 'rider_verification_status'
              : 'driver_verification_status'],
        ],
        fallback: 'unknown',
      ),
      'rating': _toDouble(
            tripData[isDriverTicket ? 'rider_rating' : 'driver_rating'],
          ) ??
          0,
      'ratingCount': _toInt(
            tripData[
                isDriverTicket ? 'rider_rating_count' : 'driver_rating_count'],
          ) ??
          0,
    };
  }

  Map<String, dynamic> _buildTripSnapshot({
    required String tripId,
    required Map<String, dynamic> tripData,
  }) {
    final pricingSnapshot = _map(
      tripData['pricing_snapshot'] ?? tripData['pricingSnapshot'],
    );
    final paymentPlaceholder = _map(
      tripData['payment_placeholder'] ?? tripData['paymentPlaceholder'],
    );
    return <String, dynamic>{
      'tripId': tripId,
      'rideId': tripId,
      'status': _firstText(<dynamic>[tripData['status']], fallback: 'unknown'),
      'city': _firstText(<dynamic>[tripData['city']]),
      'serviceType': _firstText(
        <dynamic>[tripData['service_type'], tripData['serviceType']],
      ),
      'pickupAddress': _firstText(
        <dynamic>[tripData['pickup_address'], tripData['pickup']],
      ),
      'destinationAddress': _firstText(
        <dynamic>[
          tripData['destination_address'],
          tripData['final_destination_address'],
          tripData['destination'],
        ],
      ),
      'paymentMethod': _firstText(
        <dynamic>[
          tripData['payment_method'],
          tripData['paymentMethod'],
          paymentPlaceholder['method'],
          paymentPlaceholder['provider'],
          paymentPlaceholder['status'],
        ],
      ),
      'fareAmount': _toDouble(tripData['fare']) ??
          _toDouble(tripData['grossFare']) ??
          _toDouble(tripData['fareEstimate']) ??
          _toDouble(tripData['fare_estimate']) ??
          _toDouble(pricingSnapshot['fareEstimate']) ??
          _toDouble(pricingSnapshot['fare_estimate']) ??
          0,
      'driverId':
          _firstText(<dynamic>[tripData['driver_id'], tripData['driverId']]),
      'driverName': _firstText(
        <dynamic>[tripData['driver_name'], tripData['driverName']],
      ),
      'riderId':
          _firstText(<dynamic>[tripData['rider_id'], tripData['riderId']]),
      'riderName': _firstText(
        <dynamic>[tripData['rider_name'], tripData['riderName']],
      ),
      'source': 'user_support',
    };
  }

  String _ticketCode(String prefix, String documentId) {
    final normalized =
        documentId.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
    final suffix = normalized.length <= 6
        ? normalized
        : normalized.substring(normalized.length - 6);
    return 'SUP-$prefix-$suffix';
  }

  String _normalizeCreatedByType(String value) {
    return value.trim().toLowerCase() == 'driver' ? 'driver' : 'rider';
  }

  String _fallbackKey() => DateTime.now().microsecondsSinceEpoch.toString();
}

String sentenceCaseSupportType(String value) {
  final normalized = value.trim().toLowerCase();
  if (normalized.isEmpty) {
    return 'User';
  }
  return '${normalized[0].toUpperCase()}${normalized.substring(1)}';
}

bool _isSupportRole(String role) {
  final normalized = role.trim().toLowerCase();
  return normalized == 'support' ||
      normalized == 'support_agent' ||
      normalized == 'support_manager' ||
      normalized == 'admin' ||
      normalized == 'super_admin';
}

Map<String, dynamic> _map(dynamic value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return value.map<String, dynamic>(
      (dynamic key, dynamic entry) => MapEntry(key.toString(), entry),
    );
  }
  return <String, dynamic>{};
}

String _text(dynamic value) => value?.toString().trim() ?? '';

String _firstText(Iterable<dynamic> values, {String fallback = ''}) {
  for (final dynamic value in values) {
    final text = _text(value);
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
  return double.tryParse(_text(value));
}

int? _toInt(dynamic value) {
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(_text(value));
}

DateTime? _dateTimeFromDynamic(dynamic value) {
  if (value == null) {
    return null;
  }
  if (value is int) {
    return DateTime.fromMillisecondsSinceEpoch(value);
  }
  if (value is num) {
    return DateTime.fromMillisecondsSinceEpoch(value.toInt());
  }
  final parsedInt = int.tryParse(_text(value));
  if (parsedInt != null) {
    return DateTime.fromMillisecondsSinceEpoch(parsedInt);
  }
  return null;
}

List<MapEntry<String, dynamic>> _recordEntriesFromDynamic(dynamic value) {
  if (value is List) {
    return <MapEntry<String, dynamic>>[
      for (var index = 0; index < value.length; index += 1)
        MapEntry<String, dynamic>(index.toString(), value[index]),
    ];
  }

  if (value is Map) {
    return Map<Object?, Object?>.from(value)
        .entries
        .map(
          (entry) => MapEntry<String, dynamic>(
            entry.key?.toString() ?? '',
            entry.value,
          ),
        )
        .toList(growable: false);
  }

  return const <MapEntry<String, dynamic>>[];
}

class _TripOptionCandidate {
  const _TripOptionCandidate({
    required this.option,
    required this.richnessScore,
  });

  final UserSupportTripOption option;
  final int richnessScore;

  bool isBetterThan(_TripOptionCandidate other) {
    final myMillis = option.updatedAt?.millisecondsSinceEpoch ?? 0;
    final otherMillis = other.option.updatedAt?.millisecondsSinceEpoch ?? 0;
    if (myMillis != otherMillis) {
      return myMillis > otherMillis;
    }
    return richnessScore > other.richnessScore;
  }
}

_TripOptionCandidate? _tripOptionCandidateFromRecord(
  dynamic rawValue, {
  required String fallbackTripId,
  required String source,
}) {
  final trip = _map(rawValue);
  final tripId = _firstText(<dynamic>[
    trip['trip_id'],
    trip['tripId'],
    trip['rideId'],
    trip['ride_id'],
    trip['requestId'],
    fallbackTripId,
  ]);
  if (tripId.isEmpty) {
    return null;
  }

  final pickup = _tripAddressLabel(
    <dynamic>[
      trip['pickup_address'],
      _map(trip['pickup'])['address'],
      _map(trip['pickup'])['name'],
      trip['pickup'],
      trip['pickupAddress'],
    ],
    fallback: 'Pickup not recorded',
  );
  final destination = _tripAddressLabel(
    <dynamic>[
      trip['destination_address'],
      trip['final_destination_address'],
      _map(trip['destination'])['address'],
      _map(trip['final_destination'])['address'],
      _map(trip['destination'])['name'],
      trip['destination'],
      trip['destinationAddress'],
    ],
    fallback: 'Destination not recorded',
  );
  final status = _firstText(
    <dynamic>[
      trip['status'],
      trip['trip_state'],
      trip['tripState'],
      trip['settlementStatus'],
    ],
    fallback: 'completed',
  );
  final serviceType = _firstText(
    <dynamic>[
      trip['service_type'],
      trip['serviceType'],
      trip['service'],
    ],
    fallback: 'Trip',
  );
  final city = _firstText(<dynamic>[trip['city']]);
  final updatedAt = _dateTimeFromDynamic(
    trip['updated_at'] ??
        trip['updatedAt'] ??
        trip['completed_at'] ??
        trip['completedAt'] ??
        trip['requested_at'] ??
        trip['requestedAt'] ??
        trip['created_at'] ??
        trip['createdAt'],
  );
  final subtitleParts = <String>[
    _supportSentenceCase(serviceType),
    if (city.isNotEmpty) _supportSentenceCase(city),
    _supportSentenceCase(status),
  ];
  final richnessScore = <String>[
    pickup,
    destination,
    serviceType,
    city,
    status,
    source,
  ].where((value) => value.trim().isNotEmpty).length;

  return _TripOptionCandidate(
    option: UserSupportTripOption(
      tripId: tripId,
      title: '$pickup -> $destination',
      subtitle: subtitleParts.join(' • '),
      status: status,
      updatedAt: updatedAt,
    ),
    richnessScore: richnessScore,
  );
}

String _tripAddressLabel(
  Iterable<dynamic> values, {
  required String fallback,
}) {
  for (final value in values) {
    if (value is Map) {
      final mapped = _map(value);
      final text = _firstText(<dynamic>[
        mapped['address'],
        mapped['label'],
        mapped['name'],
      ]);
      if (text.isNotEmpty) {
        return text;
      }
      continue;
    }

    final text = _text(value);
    if (text.isNotEmpty) {
      return text;
    }
  }

  return fallback;
}

String _supportSentenceCase(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    return '';
  }

  final spaced =
      normalized.replaceAll('_', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  return '${spaced[0].toUpperCase()}${spaced.substring(1)}';
}

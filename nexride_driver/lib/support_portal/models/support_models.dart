import 'package:flutter/material.dart';

enum SupportInboxView {
  dashboard,
  open,
  assignedToMe,
  pendingUser,
  escalated,
  resolved,
}

extension SupportInboxViewPresentation on SupportInboxView {
  String get label {
    return switch (this) {
      SupportInboxView.dashboard => 'Dashboard',
      SupportInboxView.open => 'Open tickets',
      SupportInboxView.assignedToMe => 'Assigned to me',
      SupportInboxView.pendingUser => 'Pending user',
      SupportInboxView.escalated => 'Escalated',
      SupportInboxView.resolved => 'Resolved',
    };
  }

  String get shortLabel {
    return switch (this) {
      SupportInboxView.dashboard => 'Overview',
      SupportInboxView.open => 'Open',
      SupportInboxView.assignedToMe => 'Mine',
      SupportInboxView.pendingUser => 'Pending',
      SupportInboxView.escalated => 'Escalated',
      SupportInboxView.resolved => 'Resolved',
    };
  }

  IconData get icon {
    return switch (this) {
      SupportInboxView.dashboard => Icons.space_dashboard_rounded,
      SupportInboxView.open => Icons.inbox_outlined,
      SupportInboxView.assignedToMe => Icons.assignment_ind_outlined,
      SupportInboxView.pendingUser => Icons.hourglass_top_rounded,
      SupportInboxView.escalated => Icons.priority_high_rounded,
      SupportInboxView.resolved => Icons.task_alt_rounded,
    };
  }
}

@immutable
class SupportPermissions {
  const SupportPermissions({
    required this.canReplyToTickets,
    required this.canUpdateTicketStatus,
    required this.canAddInternalNotes,
    required this.canAssignTickets,
    required this.canEscalateTickets,
    required this.canViewSupportAnalytics,
    required this.canAuditStaffActions,
    required this.canOverrideTicketControls,
  });

  final bool canReplyToTickets;
  final bool canUpdateTicketStatus;
  final bool canAddInternalNotes;
  final bool canAssignTickets;
  final bool canEscalateTickets;
  final bool canViewSupportAnalytics;
  final bool canAuditStaffActions;
  final bool canOverrideTicketControls;

  factory SupportPermissions.forRole(String role) {
    final normalized = role.trim().toLowerCase();
    switch (normalized) {
      case 'super_admin':
      case 'admin':
        return const SupportPermissions(
          canReplyToTickets: true,
          canUpdateTicketStatus: true,
          canAddInternalNotes: true,
          canAssignTickets: true,
          canEscalateTickets: true,
          canViewSupportAnalytics: true,
          canAuditStaffActions: true,
          canOverrideTicketControls: true,
        );
      case 'support_manager':
        return const SupportPermissions(
          canReplyToTickets: true,
          canUpdateTicketStatus: true,
          canAddInternalNotes: true,
          canAssignTickets: true,
          canEscalateTickets: true,
          canViewSupportAnalytics: true,
          canAuditStaffActions: false,
          canOverrideTicketControls: false,
        );
      case 'support_agent':
        return const SupportPermissions(
          canReplyToTickets: true,
          canUpdateTicketStatus: true,
          canAddInternalNotes: true,
          canAssignTickets: false,
          canEscalateTickets: false,
          canViewSupportAnalytics: false,
          canAuditStaffActions: false,
          canOverrideTicketControls: false,
        );
      default:
        return const SupportPermissions(
          canReplyToTickets: false,
          canUpdateTicketStatus: false,
          canAddInternalNotes: false,
          canAssignTickets: false,
          canEscalateTickets: false,
          canViewSupportAnalytics: false,
          canAuditStaffActions: false,
          canOverrideTicketControls: false,
        );
    }
  }
}

@immutable
class SupportSession {
  const SupportSession({
    required this.uid,
    required this.email,
    required this.displayName,
    required this.role,
    required this.accessMode,
    required this.permissions,
    this.mustChangePassword = false,
  });

  final String uid;
  final String email;
  final String displayName;
  final String role;
  final String accessMode;
  final SupportPermissions permissions;

  /// True when the user's account is flagged with `temporaryPassword=true`
  /// (custom claim or RTDB `/account_security/{uid}`). Gated routes use
  /// this to force-redirect the operator to the change-password screen.
  final bool mustChangePassword;

  bool get isAdminOverride =>
      role == 'admin' ||
      role == 'super_admin' ||
      permissions.canOverrideTicketControls;

  factory SupportSession.adminOverride({
    required String uid,
    required String email,
    required String displayName,
    required String role,
    required String accessMode,
    bool mustChangePassword = false,
  }) {
    return SupportSession(
      uid: uid,
      email: email,
      displayName: displayName,
      role: role,
      accessMode: accessMode,
      permissions: SupportPermissions.forRole(role),
      mustChangePassword: mustChangePassword,
    );
  }

  SupportSession copyWith({bool? mustChangePassword}) {
    return SupportSession(
      uid: uid,
      email: email,
      displayName: displayName,
      role: role,
      accessMode: accessMode,
      permissions: permissions,
      mustChangePassword: mustChangePassword ?? this.mustChangePassword,
    );
  }
}

@immutable
class SupportStaffRecord {
  const SupportStaffRecord({
    required this.uid,
    required this.displayName,
    required this.email,
    required this.role,
    required this.enabled,
    required this.lastActiveAt,
    required this.rawData,
  });

  final String uid;
  final String displayName;
  final String email;
  final String role;
  final bool enabled;
  final DateTime? lastActiveAt;
  final Map<String, dynamic> rawData;

  factory SupportStaffRecord.fromRecord(
    String uid,
    dynamic value,
  ) {
    final data = _map(value);
    return SupportStaffRecord(
      uid: uid,
      displayName: _firstText(
        <dynamic>[data['displayName'], data['name'], data['email']],
        fallback: 'Support staff',
      ),
      email: _firstText(<dynamic>[data['email']]),
      role: _normalizeRole(
          _firstText(<dynamic>[data['role']], fallback: 'support_agent')),
      enabled: data['enabled'] != false && data['disabled'] != true,
      lastActiveAt: _dateTimeFromDynamic(data['lastActiveAt']),
      rawData: data,
    );
  }
}

@immutable
class SupportParticipantSnapshot {
  const SupportParticipantSnapshot({
    required this.userId,
    required this.userType,
    required this.name,
    required this.phone,
    required this.email,
    required this.city,
    required this.status,
    required this.verificationStatus,
    required this.rating,
    required this.ratingCount,
    required this.rawData,
  });

  final String userId;
  final String userType;
  final String name;
  final String phone;
  final String email;
  final String city;
  final String status;
  final String verificationStatus;
  final double rating;
  final int ratingCount;
  final Map<String, dynamic> rawData;

  factory SupportParticipantSnapshot.fromMap(
    dynamic value, {
    required String fallbackUserType,
    required String fallbackUserId,
  }) {
    final data = _map(value);
    return SupportParticipantSnapshot(
      userId: _firstText(<dynamic>[data['userId'], data['id']],
          fallback: fallbackUserId),
      userType:
          _firstText(<dynamic>[data['userType']], fallback: fallbackUserType),
      name: _firstText(
        <dynamic>[data['name'], data['fullName'], data['displayName']],
        fallback: fallbackUserType == 'driver' ? 'Driver' : 'Rider',
      ),
      phone: _firstText(<dynamic>[data['phone'], data['phoneNumber']]),
      email: _firstText(<dynamic>[data['email']]),
      city: _firstText(<dynamic>[data['city']]),
      status: _firstText(<dynamic>[data['status']], fallback: 'active'),
      verificationStatus: _firstText(<dynamic>[data['verificationStatus']],
          fallback: 'unknown'),
      rating: _toDouble(data['rating']) ?? 0,
      ratingCount: _toInt(data['ratingCount']) ?? 0,
      rawData: data,
    );
  }
}

@immutable
class SupportTripSnapshot {
  const SupportTripSnapshot({
    required this.tripId,
    required this.status,
    required this.city,
    required this.serviceType,
    required this.pickupAddress,
    required this.destinationAddress,
    required this.paymentMethod,
    required this.fareAmount,
    required this.distanceKm,
    required this.durationMinutes,
    required this.riderId,
    required this.riderName,
    required this.driverId,
    required this.driverName,
    required this.disputeReason,
    required this.source,
    required this.createdAt,
    required this.completedAt,
    required this.rawData,
  });

  final String tripId;
  final String status;
  final String city;
  final String serviceType;
  final String pickupAddress;
  final String destinationAddress;
  final String paymentMethod;
  final double fareAmount;
  final double distanceKm;
  final double durationMinutes;
  final String riderId;
  final String riderName;
  final String driverId;
  final String driverName;
  final String disputeReason;
  final String source;
  final DateTime? createdAt;
  final DateTime? completedAt;
  final Map<String, dynamic> rawData;

  factory SupportTripSnapshot.fromMap(
    dynamic value, {
    required String fallbackTripId,
  }) {
    final data = _map(value);
    return SupportTripSnapshot(
      tripId: _firstText(<dynamic>[data['tripId'], data['rideId']],
          fallback: fallbackTripId),
      status: _firstText(<dynamic>[data['status']], fallback: 'unknown'),
      city: _firstText(<dynamic>[data['city']]),
      serviceType:
          _firstText(<dynamic>[data['serviceType'], data['service_type']]),
      pickupAddress: _firstText(
        <dynamic>[
          data['pickupAddress'],
          data['pickup_address'],
          data['pickup']
        ],
      ),
      destinationAddress: _firstText(
        <dynamic>[
          data['destinationAddress'],
          data['destination_address'],
          data['destination'],
          data['final_destination'],
        ],
      ),
      paymentMethod:
          _firstText(<dynamic>[data['paymentMethod'], data['payment_method']]),
      fareAmount: _toDouble(data['fareAmount']) ??
          _toDouble(data['fare']) ??
          _toDouble(data['grossFare']) ??
          0,
      distanceKm:
          _toDouble(data['distanceKm']) ?? _toDouble(data['distance_km']) ?? 0,
      durationMinutes: _toDouble(data['durationMinutes']) ??
          _toDouble(data['duration_minutes']) ??
          0,
      riderId: _firstText(<dynamic>[data['riderId'], data['rider_id']]),
      riderName: _firstText(<dynamic>[data['riderName'], data['rider_name']],
          fallback: 'Rider'),
      driverId: _firstText(<dynamic>[data['driverId'], data['driver_id']]),
      driverName: _firstText(<dynamic>[data['driverName'], data['driver_name']],
          fallback: 'Driver'),
      disputeReason:
          _firstText(<dynamic>[data['disputeReason'], data['reason']]),
      source: _firstText(<dynamic>[data['source']],
          fallback: 'support_ticket_bridge'),
      createdAt: _dateTimeFromDynamic(data['createdAt']),
      completedAt: _dateTimeFromDynamic(data['completedAt']),
      rawData: data,
    );
  }
}

@immutable
class SupportTicketSummary {
  const SupportTicketSummary({
    required this.documentId,
    required this.ticketId,
    required this.createdByUserId,
    required this.createdByType,
    required this.category,
    required this.priority,
    required this.status,
    required this.subject,
    required this.message,
    required this.attachments,
    required this.tripId,
    required this.assignedToStaffId,
    required this.assignedToStaffName,
    required this.createdAt,
    required this.updatedAt,
    required this.lastReplyAt,
    required this.lastExternalReplyAt,
    required this.firstResponseAt,
    required this.resolvedAt,
    required this.resolution,
    required this.internalNotes,
    required this.tags,
    required this.escalated,
    required this.requesterProfile,
    required this.counterpartyProfile,
    required this.tripSnapshot,
    required this.staffSeenAt,
    required this.replyCount,
    required this.internalNoteCount,
    required this.lastPublicSenderRole,
    required this.sourceType,
    required this.sourceReference,
    required this.rawData,
  });

  final String documentId;
  final String ticketId;
  final String createdByUserId;
  final String createdByType;
  final String category;
  final String priority;
  final String status;
  final String subject;
  final String message;
  final List<String> attachments;
  final String tripId;
  final String assignedToStaffId;
  final String assignedToStaffName;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? lastReplyAt;
  final DateTime? lastExternalReplyAt;
  final DateTime? firstResponseAt;
  final DateTime? resolvedAt;
  final String resolution;
  final List<String> internalNotes;
  final List<String> tags;
  final bool escalated;
  final SupportParticipantSnapshot requesterProfile;
  final SupportParticipantSnapshot counterpartyProfile;
  final SupportTripSnapshot tripSnapshot;
  final Map<String, DateTime> staffSeenAt;
  final int replyCount;
  final int internalNoteCount;
  final String lastPublicSenderRole;
  final String sourceType;
  final String sourceReference;
  final Map<String, dynamic> rawData;

  bool get isClosed => status == 'closed';
  bool get isResolved => status == 'resolved' || isClosed;
  bool get isOverdue {
    final created = createdAt;
    if (created == null || isResolved) {
      return false;
    }
    return DateTime.now().isAfter(created.add(prioritySla(priority)));
  }

  Duration? get age {
    final created = createdAt;
    if (created == null) {
      return null;
    }
    return DateTime.now().difference(created);
  }

  bool hasUnreadExternalReply(String viewerId) {
    final externalReplyAt = lastExternalReplyAt;
    if (externalReplyAt == null || isResolved) {
      return false;
    }
    final seenAt = staffSeenAt[viewerId];
    return seenAt == null || externalReplyAt.isAfter(seenAt);
  }

  factory SupportTicketSummary.fromRecord(
    String documentId,
    dynamic value,
  ) {
    final data = _map(value);
    return SupportTicketSummary(
      documentId: documentId,
      ticketId: _firstText(<dynamic>[data['ticketId']], fallback: documentId),
      createdByUserId: _firstText(<dynamic>[data['createdByUserId']]),
      createdByType:
          _firstText(<dynamic>[data['createdByType']], fallback: 'user'),
      category: _firstText(<dynamic>[data['category']], fallback: 'general'),
      priority: _firstText(<dynamic>[data['priority']], fallback: 'medium'),
      status: _firstText(<dynamic>[data['status']], fallback: 'open'),
      subject:
          _firstText(<dynamic>[data['subject']], fallback: 'Support ticket'),
      message: _firstText(<dynamic>[data['message']],
          fallback: 'No ticket message recorded.'),
      attachments: _stringList(data['attachments']),
      tripId: _firstText(<dynamic>[data['tripId'], data['rideId']]),
      assignedToStaffId: _firstText(<dynamic>[data['assignedToStaffId']]),
      assignedToStaffName: _firstText(<dynamic>[data['assignedToStaffName']],
          fallback: 'Unassigned'),
      createdAt: _dateTimeFromDynamic(data['createdAt']),
      updatedAt: _dateTimeFromDynamic(data['updatedAt']),
      lastReplyAt: _dateTimeFromDynamic(data['lastReplyAt']),
      lastExternalReplyAt: _dateTimeFromDynamic(data['lastExternalReplyAt']),
      firstResponseAt: _dateTimeFromDynamic(data['firstResponseAt']),
      resolvedAt: _dateTimeFromDynamic(data['resolvedAt']),
      resolution: _firstText(<dynamic>[data['resolution']]),
      internalNotes: _stringList(data['internalNotes']),
      tags: _stringList(data['tags']),
      escalated: data['escalated'] == true ||
          _firstText(<dynamic>[data['status']]) == 'escalated',
      requesterProfile: SupportParticipantSnapshot.fromMap(
        data['requesterProfile'],
        fallbackUserType:
            _firstText(<dynamic>[data['createdByType']], fallback: 'user'),
        fallbackUserId: _firstText(<dynamic>[data['createdByUserId']]),
      ),
      counterpartyProfile: SupportParticipantSnapshot.fromMap(
        data['counterpartyProfile'],
        fallbackUserType:
            _firstText(<dynamic>[data['createdByType']], fallback: 'user') ==
                    'driver'
                ? 'rider'
                : 'driver',
        fallbackUserId: '',
      ),
      tripSnapshot: SupportTripSnapshot.fromMap(
        data['tripSnapshot'],
        fallbackTripId: _firstText(<dynamic>[data['tripId'], data['rideId']]),
      ),
      staffSeenAt: _dateTimeMap(data['staffSeenAt']),
      replyCount: _toInt(data['replyCount']) ?? 0,
      internalNoteCount: _toInt(data['internalNoteCount']) ?? 0,
      lastPublicSenderRole:
          _firstText(<dynamic>[data['lastPublicSenderRole']], fallback: 'user'),
      sourceType:
          _firstText(<dynamic>[data['sourceType']], fallback: 'support_ticket'),
      sourceReference: _firstText(<dynamic>[data['sourceReference']]),
      rawData: data,
    );
  }
}

@immutable
class SupportTicketMessage {
  const SupportTicketMessage({
    required this.documentId,
    required this.ticketDocumentId,
    required this.senderId,
    required this.senderRole,
    required this.senderName,
    required this.message,
    required this.attachmentUrl,
    required this.visibility,
    required this.createdAt,
    required this.rawData,
  });

  final String documentId;
  final String ticketDocumentId;
  final String senderId;
  final String senderRole;
  final String senderName;
  final String message;
  final String attachmentUrl;
  final String visibility;
  final DateTime? createdAt;
  final Map<String, dynamic> rawData;

  bool get isInternalNote => visibility == 'internal';

  factory SupportTicketMessage.fromRecord(
    String documentId,
    dynamic value, {
    required String ticketDocumentId,
  }) {
    final data = _map(value);
    return SupportTicketMessage(
      documentId: documentId,
      ticketDocumentId: ticketDocumentId,
      senderId: _firstText(<dynamic>[data['senderId']]),
      senderRole:
          _firstText(<dynamic>[data['senderRole']], fallback: 'support'),
      senderName: _firstText(
        <dynamic>[data['senderName'], data['displayName']],
        fallback: 'NexRide',
      ),
      message: _firstText(<dynamic>[data['message']], fallback: ''),
      attachmentUrl: _firstText(<dynamic>[data['attachmentUrl']]),
      visibility: _firstText(<dynamic>[data['visibility']], fallback: 'public'),
      createdAt: _dateTimeFromDynamic(data['createdAt']),
      rawData: data,
    );
  }
}

@immutable
class SupportActivityLog {
  const SupportActivityLog({
    required this.documentId,
    required this.ticketDocumentId,
    required this.actorId,
    required this.actorRole,
    required this.actorName,
    required this.action,
    required this.summary,
    required this.createdAt,
    required this.metadata,
  });

  final String documentId;
  final String ticketDocumentId;
  final String actorId;
  final String actorRole;
  final String actorName;
  final String action;
  final String summary;
  final DateTime? createdAt;
  final Map<String, dynamic> metadata;

  factory SupportActivityLog.fromRecord(
    String documentId,
    dynamic value, {
    String fallbackTicketDocumentId = '',
  }) {
    final data = _map(value);
    return SupportActivityLog(
      documentId: documentId,
      ticketDocumentId: _firstText(
        <dynamic>[data['ticketDocumentId'], data['ticketId']],
        fallback: fallbackTicketDocumentId,
      ),
      actorId: _firstText(<dynamic>[data['actorId']]),
      actorRole: _firstText(<dynamic>[data['actorRole']], fallback: 'support'),
      actorName: _firstText(<dynamic>[data['actorName']], fallback: 'NexRide'),
      action: _firstText(<dynamic>[data['action']], fallback: 'update'),
      summary: _firstText(<dynamic>[data['summary']],
          fallback: 'Support activity recorded.'),
      createdAt: _dateTimeFromDynamic(data['createdAt']),
      metadata: _map(data['metadata']),
    );
  }
}

@immutable
class SupportAnalytics {
  const SupportAnalytics({
    required this.openTickets,
    required this.assignedToMe,
    required this.pendingUserTickets,
    required this.escalatedTickets,
    required this.resolvedTickets,
    required this.overdueTickets,
    required this.unreadReplies,
    required this.averageFirstResponseMinutes,
    required this.averageResolutionHours,
  });

  final int openTickets;
  final int assignedToMe;
  final int pendingUserTickets;
  final int escalatedTickets;
  final int resolvedTickets;
  final int overdueTickets;
  final int unreadReplies;
  final double averageFirstResponseMinutes;
  final double averageResolutionHours;
}

@immutable
class SupportPortalSnapshot {
  const SupportPortalSnapshot({
    required this.fetchedAt,
    required this.tickets,
    required this.staff,
    required this.logs,
    required this.analytics,
  });

  final DateTime fetchedAt;
  final List<SupportTicketSummary> tickets;
  final List<SupportStaffRecord> staff;
  final List<SupportActivityLog> logs;
  final SupportAnalytics analytics;
}

@immutable
class SupportTicketDetail {
  const SupportTicketDetail({
    required this.ticket,
    required this.messages,
    required this.logs,
  });

  final SupportTicketSummary ticket;
  final List<SupportTicketMessage> messages;
  final List<SupportActivityLog> logs;
}

@immutable
class SupportCannedResponse {
  const SupportCannedResponse({
    required this.label,
    required this.body,
  });

  final String label;
  final String body;
}

const List<SupportCannedResponse> kDefaultSupportCannedResponses =
    <SupportCannedResponse>[
  SupportCannedResponse(
    label: 'Trip dispute acknowledged',
    body:
        'We have opened your trip dispute and assigned it for review. A support specialist will check the trip details, payment context, and any related reports.',
  ),
  SupportCannedResponse(
    label: 'Safety escalation',
    body:
        'Your report has been escalated for priority review. We are checking the trip context and will update you as soon as the investigation moves forward.',
  ),
  SupportCannedResponse(
    label: 'Pending user details',
    body:
        'We need one more detail to continue this review. Please reply with any extra context, screenshot, or timeline note that can help us validate the complaint.',
  ),
  SupportCannedResponse(
    label: 'Resolution sent',
    body:
        'This ticket has been reviewed and resolved on our side. If you need anything else related to this trip, reply here and our team will reopen the case.',
  ),
];

Duration prioritySla(String priority) {
  switch (priority.trim().toLowerCase()) {
    case 'urgent':
      return const Duration(minutes: 30);
    case 'high':
      return const Duration(hours: 2);
    case 'low':
      return const Duration(hours: 24);
    default:
      return const Duration(hours: 8);
  }
}

String normalizeSupportRole(String value) => _normalizeRole(value);

Map<String, dynamic> supportMap(dynamic value) => _map(value);

DateTime? supportDateTimeFromDynamic(dynamic value) =>
    _dateTimeFromDynamic(value);

double? supportToDouble(dynamic value) => _toDouble(value);

int? supportToInt(dynamic value) => _toInt(value);

String _normalizeRole(String value) {
  final normalized = value.trim().toLowerCase();
  switch (normalized) {
    case 'super_admin':
    case 'admin':
    case 'support_manager':
    case 'support_agent':
      return normalized;
    case 'manager':
      return 'support_manager';
    case 'agent':
      return 'support_agent';
    default:
      return normalized;
  }
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

String _firstText(
  Iterable<dynamic> values, {
  String fallback = '',
}) {
  for (final value in values) {
    final text = value?.toString().trim() ?? '';
    if (text.isNotEmpty) {
      return text;
    }
  }
  return fallback;
}

List<String> _stringList(dynamic value) {
  if (value is List) {
    return value
        .map((dynamic entry) => entry.toString().trim())
        .where((String entry) => entry.isNotEmpty)
        .toList();
  }
  return const <String>[];
}

Map<String, DateTime> _dateTimeMap(dynamic value) {
  final data = _map(value);
  return <String, DateTime>{
    for (final entry in data.entries)
      if (_dateTimeFromDynamic(entry.value) != null)
        entry.key: _dateTimeFromDynamic(entry.value)!,
  };
}

DateTime? _dateTimeFromDynamic(dynamic value) {
  if (value == null) {
    return null;
  }
  if (value is DateTime) {
    return value;
  }
  if (value is int) {
    return DateTime.fromMillisecondsSinceEpoch(value);
  }
  if (value is num) {
    return DateTime.fromMillisecondsSinceEpoch(value.toInt());
  }
  if (value is String) {
    return DateTime.tryParse(value);
  }
  return null;
}

int? _toInt(dynamic value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '');
}

double? _toDouble(dynamic value) {
  if (value is double) {
    return value;
  }
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value?.toString() ?? '');
}

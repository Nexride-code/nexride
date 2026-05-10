import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

import '../models/support_models.dart';

class SupportTicketService {
  SupportTicketService({
    FirebaseDatabase? database,
  }) : _database = database;

  final FirebaseDatabase? _database;

  FirebaseDatabase get database => _database ?? FirebaseDatabase.instance;
  DatabaseReference get _rootRef => database.ref();
  DatabaseReference get _ticketsRef => _rootRef.child('support_tickets');
  DatabaseReference get _staffRef => _rootRef.child('support_staff');
  DatabaseReference get _messagesRef =>
      _rootRef.child('support_ticket_messages');
  DatabaseReference get _logsRef => _rootRef.child('support_logs');

  Future<SupportPortalSnapshot> fetchPortalSnapshot({
    required SupportSession session,
  }) async {
    Map<String, dynamic> ticketMap = <String, dynamic>{};
    Map<String, dynamic> staffMap = <String, dynamic>{};
    Map<String, dynamic> logsMap = <String, dynamic>{};
    try {
      final responses = await Future.wait<DataSnapshot>(<Future<DataSnapshot>>[
        _ticketsRef.get(),
        _staffRef.get(),
        _logsRef.get(),
      ]);
      ticketMap = _map(responses[0].value);
      staffMap = _map(responses[1].value);
      logsMap = _map(responses[2].value);
    } catch (error) {
      if (!_isPermissionDenied(error)) {
        rethrow;
      }
      final callable = FirebaseFunctions.instanceFor(
        region: 'us-central1',
      ).httpsCallable('supportListTickets');
      final result = await callable.call(<String, dynamic>{});
      final data = _map(result.data);
      final rows = data['tickets'];
      if (rows is List) {
        ticketMap = <String, dynamic>{
          for (var i = 0; i < rows.length; i++)
            'callable_${i + 1}': rows[i],
        };
      }
    }

    final tickets = ticketMap.entries
        .map(
          (MapEntry<String, dynamic> entry) =>
              SupportTicketSummary.fromRecord(entry.key, entry.value),
        )
        .toList()
      ..sort(_sortByUpdatedDesc);

    final staff = staffMap.entries
        .map(
          (MapEntry<String, dynamic> entry) =>
              SupportStaffRecord.fromRecord(entry.key, entry.value),
        )
        .where((SupportStaffRecord record) => record.enabled)
        .toList()
      ..sort(
        (SupportStaffRecord a, SupportStaffRecord b) =>
            a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
      );

    final logs = _flattenLogs(logsMap)
      ..sort(
        (SupportActivityLog a, SupportActivityLog b) =>
            (b.createdAt?.millisecondsSinceEpoch ?? 0)
                .compareTo(a.createdAt?.millisecondsSinceEpoch ?? 0),
      );

    final analytics = _buildAnalytics(tickets: tickets, viewerId: session.uid);

    return SupportPortalSnapshot(
      fetchedAt: DateTime.now(),
      tickets: tickets,
      staff: staff,
      logs: logs.take(250).toList(growable: false),
      analytics: analytics,
    );
  }

  Future<SupportTicketDetail> fetchTicketDetail({
    required String ticketDocumentId,
  }) async {
    final ticketRef = _ticketsRef.child(ticketDocumentId);
    final responses = await Future.wait<DataSnapshot>(<Future<DataSnapshot>>[
      ticketRef.get(),
      _messagesRef.child(ticketDocumentId).get(),
      _logsRef.child(ticketDocumentId).get(),
    ]);

    final ticketData = _map(responses[0].value);
    if (ticketData.isEmpty) {
      throw StateError('Support ticket $ticketDocumentId was not found.');
    }

    final messages = _map(responses[1].value)
        .entries
        .map(
          (MapEntry<String, dynamic> entry) => SupportTicketMessage.fromRecord(
            entry.key,
            entry.value,
            ticketDocumentId: ticketDocumentId,
          ),
        )
        .toList()
      ..sort(
        (SupportTicketMessage a, SupportTicketMessage b) =>
            (a.createdAt?.millisecondsSinceEpoch ?? 0)
                .compareTo(b.createdAt?.millisecondsSinceEpoch ?? 0),
      );

    final logs = _map(responses[2].value)
        .entries
        .map(
          (MapEntry<String, dynamic> entry) => SupportActivityLog.fromRecord(
            entry.key,
            entry.value,
            fallbackTicketDocumentId: ticketDocumentId,
          ),
        )
        .toList()
      ..sort(
        (SupportActivityLog a, SupportActivityLog b) =>
            (b.createdAt?.millisecondsSinceEpoch ?? 0)
                .compareTo(a.createdAt?.millisecondsSinceEpoch ?? 0),
      );

    return SupportTicketDetail(
      ticket: SupportTicketSummary.fromRecord(ticketDocumentId, ticketData),
      messages: messages,
      logs: logs,
    );
  }

  /// Best-effort presence ping. Writes the four self-managed presence
  /// fields under `/support_staff/{uid}` (displayName, accessMode,
  /// lastActiveAt, updatedAt) so the support directory shows fresh
  /// activity. Intentionally NEVER throws — a permission-denied here is
  /// purely cosmetic (it only delays the directory's "last active"
  /// timestamp) and must not block the dashboard from rendering.
  ///
  /// The writeable surface is constrained by `database.rules.json` (only
  /// the four leaf fields above accept self-writes; `role`, `enabled`,
  /// `disabled`, `email` remain server-only).
  Future<void> touchStaffPresence({
    required SupportSession session,
  }) async {
    if (session.isAdminOverride) {
      return;
    }
    try {
      await _rootRef.update(<String, dynamic>{
        'support_staff/${session.uid}/displayName': session.displayName,
        'support_staff/${session.uid}/accessMode': session.accessMode,
        'support_staff/${session.uid}/lastActiveAt': ServerValue.timestamp,
        'support_staff/${session.uid}/updatedAt': ServerValue.timestamp,
      });
    } catch (error) {
      debugPrint(
        '[SupportTicketService] touchStaffPresence skipped uid=${session.uid} error=$error',
      );
    }
  }

  Future<void> markTicketViewed({
    required String ticketDocumentId,
    required String viewerId,
  }) async {
    await _rootRef.update(<String, dynamic>{
      'support_tickets/$ticketDocumentId/staffSeenAt/$viewerId':
          ServerValue.timestamp,
    });
  }

  Future<void> addReply({
    required String ticketDocumentId,
    required SupportSession actor,
    required String message,
    required String visibility,
    String attachmentUrl = '',
  }) async {
    final trimmedMessage = message.trim();
    final normalizedVisibility =
        visibility.trim().toLowerCase() == 'internal' ? 'internal' : 'public';
    final normalizedAttachment = attachmentUrl.trim();
    if (trimmedMessage.isEmpty && normalizedAttachment.isEmpty) {
      throw StateError('A reply needs text or an attachment.');
    }

    final ticketSnapshot = await _ticketsRef.child(ticketDocumentId).get();
    final ticketData = _map(ticketSnapshot.value);
    if (ticketData.isEmpty) {
      throw StateError('Support ticket $ticketDocumentId was not found.');
    }

    final messageId =
        _messagesRef.child(ticketDocumentId).push().key ?? _fallbackKey();
    final internalNotes = _stringList(ticketData['internalNotes']);
    final tags = _stringList(ticketData['tags']);
    final replyCount = supportToInt(ticketData['replyCount']) ?? 0;
    final internalNoteCount =
        supportToInt(ticketData['internalNoteCount']) ?? 0;
    final updates = <String, dynamic>{
      'support_ticket_messages/$ticketDocumentId/$messageId': <String, dynamic>{
        'ticketDocumentId': ticketDocumentId,
        'senderId': actor.uid,
        'senderRole': actor.role,
        'senderName': actor.displayName,
        'message': trimmedMessage,
        'attachmentUrl': normalizedAttachment,
        'visibility': normalizedVisibility,
        'createdAt': ServerValue.timestamp,
      },
      'support_tickets/$ticketDocumentId/updatedAt': ServerValue.timestamp,
      'support_tickets/$ticketDocumentId/lastReplyAt': ServerValue.timestamp,
      'support_tickets/$ticketDocumentId/staffSeenAt/${actor.uid}':
          ServerValue.timestamp,
    };

    if (normalizedVisibility == 'internal') {
      updates.addAll(<String, dynamic>{
        'support_tickets/$ticketDocumentId/internalNoteCount':
            internalNoteCount + 1,
        'support_tickets/$ticketDocumentId/internalNotes': <String>[
          ...internalNotes,
          if (trimmedMessage.isNotEmpty) trimmedMessage,
        ],
      });
    } else {
      updates.addAll(<String, dynamic>{
        'support_tickets/$ticketDocumentId/replyCount': replyCount + 1,
        'support_tickets/$ticketDocumentId/lastPublicSenderRole': actor.role,
      });
      if (_isExternalRole(actor.role)) {
        updates['support_tickets/$ticketDocumentId/lastExternalReplyAt'] =
            ServerValue.timestamp;
      } else {
        updates['support_tickets/$ticketDocumentId/lastSupportReplyAt'] =
            ServerValue.timestamp;
        if (supportDateTimeFromDynamic(ticketData['firstResponseAt']) == null) {
          updates['support_tickets/$ticketDocumentId/firstResponseAt'] =
              ServerValue.timestamp;
        }
      }
    }

    if (tags.isEmpty) {
      updates['support_tickets/$ticketDocumentId/tags'] = const <String>[];
    }

    await _rootRef.update(updates);

    await _logAction(
      ticketDocumentId: ticketDocumentId,
      actor: actor,
      action:
          normalizedVisibility == 'internal' ? 'internal_note' : 'public_reply',
      summary: normalizedVisibility == 'internal'
          ? 'Added an internal note.'
          : 'Sent a public support reply.',
      metadata: <String, dynamic>{
        'visibility': normalizedVisibility,
        'hasAttachment': normalizedAttachment.isNotEmpty,
      },
    );
  }

  Future<void> assignTicket({
    required String ticketDocumentId,
    required SupportSession actor,
    required SupportStaffRecord assignee,
  }) async {
    await _rootRef.update(<String, dynamic>{
      'support_tickets/$ticketDocumentId/assignedToStaffId': assignee.uid,
      'support_tickets/$ticketDocumentId/assignedToStaffName':
          assignee.displayName,
      'support_tickets/$ticketDocumentId/updatedAt': ServerValue.timestamp,
    });

    await _logAction(
      ticketDocumentId: ticketDocumentId,
      actor: actor,
      action: 'assign_ticket',
      summary: 'Assigned the ticket to ${assignee.displayName}.',
      metadata: <String, dynamic>{
        'assignedToStaffId': assignee.uid,
        'assignedToStaffName': assignee.displayName,
      },
    );
  }

  Future<void> updateStatus({
    required String ticketDocumentId,
    required SupportSession actor,
    required String status,
    String resolution = '',
  }) async {
    final normalizedStatus = status.trim().toLowerCase();
    final trimmedResolution = resolution.trim();
    final updates = <String, dynamic>{
      'support_tickets/$ticketDocumentId/status': normalizedStatus,
      'support_tickets/$ticketDocumentId/updatedAt': ServerValue.timestamp,
    };

    if (normalizedStatus == 'resolved') {
      updates.addAll(<String, dynamic>{
        'support_tickets/$ticketDocumentId/resolvedAt': ServerValue.timestamp,
        'support_tickets/$ticketDocumentId/closedAt': null,
        'support_tickets/$ticketDocumentId/resolution': trimmedResolution,
      });
    } else if (normalizedStatus == 'closed') {
      updates.addAll(<String, dynamic>{
        'support_tickets/$ticketDocumentId/closedAt': ServerValue.timestamp,
        if (trimmedResolution.isNotEmpty)
          'support_tickets/$ticketDocumentId/resolution': trimmedResolution,
      });
    } else if (normalizedStatus == 'pending_user') {
      updates.addAll(<String, dynamic>{
        'support_tickets/$ticketDocumentId/pendingUserAt':
            ServerValue.timestamp,
      });
    } else {
      updates.addAll(<String, dynamic>{
        'support_tickets/$ticketDocumentId/closedAt': null,
        if (normalizedStatus == 'open')
          'support_tickets/$ticketDocumentId/resolvedAt': null,
      });
      if (trimmedResolution.isNotEmpty) {
        updates['support_tickets/$ticketDocumentId/resolution'] =
            trimmedResolution;
      }
    }

    await _rootRef.update(updates);

    await _logAction(
      ticketDocumentId: ticketDocumentId,
      actor: actor,
      action: 'status_update',
      summary: 'Updated the ticket status to $normalizedStatus.',
      metadata: <String, dynamic>{
        'status': normalizedStatus,
        if (trimmedResolution.isNotEmpty) 'resolution': trimmedResolution,
      },
    );
  }

  Future<void> escalateTicket({
    required String ticketDocumentId,
    required SupportSession actor,
  }) async {
    final ticketSnapshot = await _ticketsRef.child(ticketDocumentId).get();
    final ticketData = _map(ticketSnapshot.value);
    if (ticketData.isEmpty) {
      throw StateError('Support ticket $ticketDocumentId was not found.');
    }

    final tags = _stringList(ticketData['tags']);
    if (!tags.contains('escalated')) {
      tags.add('escalated');
    }

    await _rootRef.update(<String, dynamic>{
      'support_tickets/$ticketDocumentId/status': 'escalated',
      'support_tickets/$ticketDocumentId/escalated': true,
      'support_tickets/$ticketDocumentId/escalatedAt': ServerValue.timestamp,
      'support_tickets/$ticketDocumentId/updatedAt': ServerValue.timestamp,
      'support_tickets/$ticketDocumentId/tags': tags,
    });

    await _logAction(
      ticketDocumentId: ticketDocumentId,
      actor: actor,
      action: 'escalate_ticket',
      summary: 'Escalated the ticket for management review.',
      metadata: const <String, dynamic>{'status': 'escalated'},
    );
  }

  SupportAnalytics _buildAnalytics({
    required List<SupportTicketSummary> tickets,
    required String viewerId,
  }) {
    final open = tickets
        .where(
          (SupportTicketSummary ticket) =>
              ticket.status != 'resolved' && ticket.status != 'closed',
        )
        .length;
    final assigned = tickets
        .where((SupportTicketSummary ticket) =>
            ticket.assignedToStaffId == viewerId)
        .length;
    final pendingUser = tickets
        .where(
          (SupportTicketSummary ticket) => ticket.status == 'pending_user',
        )
        .length;
    final escalated =
        tickets.where((SupportTicketSummary ticket) => ticket.escalated).length;
    final resolved = tickets
        .where((SupportTicketSummary ticket) => ticket.isResolved)
        .length;
    final overdue =
        tickets.where((SupportTicketSummary ticket) => ticket.isOverdue).length;
    final unread = tickets
        .where((SupportTicketSummary ticket) =>
            ticket.hasUnreadExternalReply(viewerId))
        .length;

    final firstResponseDurations = tickets
        .where(
          (SupportTicketSummary ticket) =>
              ticket.createdAt != null && ticket.firstResponseAt != null,
        )
        .map(
          (SupportTicketSummary ticket) => ticket.firstResponseAt!
              .difference(ticket.createdAt!)
              .inMinutes
              .toDouble(),
        )
        .toList();

    final resolutionDurations = tickets
        .where(
          (SupportTicketSummary ticket) =>
              ticket.createdAt != null && ticket.resolvedAt != null,
        )
        .map(
          (SupportTicketSummary ticket) =>
              ticket.resolvedAt!.difference(ticket.createdAt!).inMinutes / 60,
        )
        .toList();

    return SupportAnalytics(
      openTickets: open,
      assignedToMe: assigned,
      pendingUserTickets: pendingUser,
      escalatedTickets: escalated,
      resolvedTickets: resolved,
      overdueTickets: overdue,
      unreadReplies: unread,
      averageFirstResponseMinutes: _average(firstResponseDurations),
      averageResolutionHours: _average(resolutionDurations),
    );
  }

  Future<void> _logAction({
    required String ticketDocumentId,
    required SupportSession actor,
    required String action,
    required String summary,
    Map<String, dynamic> metadata = const <String, dynamic>{},
  }) async {
    final logId = _logsRef.child(ticketDocumentId).push().key ?? _fallbackKey();
    await _logsRef.child(ticketDocumentId).child(logId).set(<String, dynamic>{
      'ticketDocumentId': ticketDocumentId,
      'actorId': actor.uid,
      'actorRole': actor.role,
      'actorName': actor.displayName,
      'action': action,
      'summary': summary,
      'metadata': metadata,
      'createdAt': ServerValue.timestamp,
    });
  }

  List<SupportActivityLog> _flattenLogs(Map<String, dynamic> logsTree) {
    final logs = <SupportActivityLog>[];
    for (final MapEntry<String, dynamic> entry in logsTree.entries) {
      final value = entry.value;
      final record = _map(value);
      if (record.containsKey('action') && record.containsKey('actorId')) {
        logs.add(
          SupportActivityLog.fromRecord(
            entry.key,
            value,
            fallbackTicketDocumentId: _firstText(
              <dynamic>[record['ticketDocumentId']],
            ),
          ),
        );
        continue;
      }
      final nested = _map(value);
      for (final MapEntry<String, dynamic> nestedEntry in nested.entries) {
        logs.add(
          SupportActivityLog.fromRecord(
            nestedEntry.key,
            nestedEntry.value,
            fallbackTicketDocumentId: entry.key,
          ),
        );
      }
    }
    return logs;
  }

  int _sortByUpdatedDesc(SupportTicketSummary a, SupportTicketSummary b) {
    return (b.updatedAt?.millisecondsSinceEpoch ?? 0)
        .compareTo(a.updatedAt?.millisecondsSinceEpoch ?? 0);
  }

  double _average(List<double> values) {
    if (values.isEmpty) {
      return 0;
    }
    final total =
        values.fold<double>(0, (double sum, double value) => sum + value);
    return total / values.length;
  }

  bool _isExternalRole(String role) {
    final normalized = role.trim().toLowerCase();
    return normalized == 'rider' ||
        normalized == 'driver' ||
        normalized == 'user';
  }

  String _fallbackKey() => DateTime.now().microsecondsSinceEpoch.toString();

  bool _isPermissionDenied(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('permission-denied') ||
        message.contains('permission denied');
  }

  Map<String, dynamic> _map(dynamic value) {
    return supportMap(value);
  }

  List<String> _stringList(dynamic value) {
    if (value is List) {
      return value
          .map((dynamic entry) => entry.toString().trim())
          .where((String entry) => entry.isNotEmpty)
          .toList(growable: false);
    }
    return <String>[];
  }

  String _firstText(Iterable<dynamic> values) {
    for (final dynamic value in values) {
      final text = value?.toString().trim() ?? '';
      if (text.isNotEmpty) {
        return text;
      }
    }
    return '';
  }
}

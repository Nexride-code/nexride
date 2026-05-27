import 'dart:async';

import 'package:firebase_database/firebase_database.dart';

/// Max wait for a single chat message RTDB [.set] (UI stays enabled regardless).
const Duration kRideChatRtdbWriteTimeout = Duration(seconds: 8);

/// Writes one chat message node with precise latency logs (Firebase [.set] only).
Future<void> persistRideChatMessageToRtdb({
  required DatabaseReference messageNode,
  required Map<String, dynamic> payload,
  required String role,
  required String rideId,
  required String messageId,
  required void Function(String line) logLine,
}) async {
  final beginMs = DateTime.now().millisecondsSinceEpoch;
  logLine(
    'CHAT_WRITE_BEGIN_NOW role=$role rideId=$rideId messageId=$messageId ms=$beginMs',
  );
  try {
    await messageNode.set(payload).timeout(kRideChatRtdbWriteTimeout);
    final durationMs = DateTime.now().millisecondsSinceEpoch - beginMs;
    logLine(
      'CHAT_WRITE_END_NOW role=$role rideId=$rideId messageId=$messageId '
      'durationMs=$durationMs',
    );
  } on TimeoutException {
    final durationMs = DateTime.now().millisecondsSinceEpoch - beginMs;
    logLine(
      'CHAT_WRITE_TIMEOUT role=$role rideId=$rideId messageId=$messageId '
      'durationMs=$durationMs',
    );
    rethrow;
  }
}

class RideChatMessage {
  const RideChatMessage({
    required this.id,
    required this.rideId,
    required this.messageId,
    required this.senderId,
    required this.senderRole,
    required this.type,
    required this.text,
    required this.imageUrl,
    required this.createdAt,
    required this.status,
    required this.isRead,
    required this.localTempId,
  });

  final String id;
  final String rideId;
  final String messageId;
  final String senderId;
  final String senderRole;
  final String type;
  final String text;
  final String imageUrl;
  final int createdAt;
  final String status;
  final bool isRead;
  final String localTempId;

  bool isSentBy(String currentUserId) {
    return currentUserId.isNotEmpty && senderId == currentUserId;
  }

  String get deliveryLabel {
    if (status == 'pending' || status == 'sending') {
      return 'Sending…';
    }
    if (status == 'failed') {
      return 'Failed';
    }
    return 'Sent';
  }

  bool get hasImage => imageUrl.trim().isNotEmpty;
}

class RideChatSnapshot {
  const RideChatSnapshot({
    required this.messages,
    required this.invalidRecordCount,
  });

  final List<RideChatMessage> messages;
  final int invalidRecordCount;
}

String canonicalRideChatMessagesPath(String rideId) {
  final normalizedRideId = rideId.trim();
  return 'ride_chats/$normalizedRideId/messages';
}

/// Max messages kept in memory per ride chat session.
const int kMaxRideChatMessagesInMemory = 100;

const String rideChatSafetyBannerText =
    'For your safety, keep communication respectful. Do not share private '
    'contact or payment details. Harassment, threats, sexual content, or abuse '
    'are prohibited. Report unsafe behavior immediately.';

String rideChatClientMessageIdFromMap(
  Map<String, dynamic> map, {
  required String fallbackMessageId,
}) {
  final explicit = (map['client_message_id'] ?? map['clientMessageId'])
      ?.toString()
      .trim();
  if (explicit != null && explicit.isNotEmpty) {
    return explicit;
  }
  return fallbackMessageId;
}

bool rideChatStatusIsPending(String status) {
  final normalized = status.trim().toLowerCase();
  return normalized == 'sending' || normalized == 'pending';
}

bool sameRideChatMessageSnapshot(RideChatMessage a, RideChatMessage b) {
  return a.id == b.id &&
      a.text == b.text &&
      a.status == b.status &&
      a.createdAt == b.createdAt &&
      a.senderId == b.senderId &&
      a.senderRole == b.senderRole &&
      a.imageUrl == b.imageUrl &&
      a.isRead == b.isRead;
}

/// Resolves the local map key for an own-message RTDB echo (same push id / client id).
String? findRideChatLocalMapKey({
  required Map<String, RideChatMessage> byId,
  required String snapshotMessageId,
  required RideChatMessage incoming,
}) {
  final snapId = snapshotMessageId.trim();
  if (snapId.isNotEmpty && byId.containsKey(snapId)) {
    return snapId;
  }
  final clientId = incoming.localTempId.trim();
  if (clientId.isNotEmpty && byId.containsKey(clientId)) {
    return clientId;
  }
  for (final entry in byId.entries) {
    final local = entry.value.localTempId.trim();
    if (local.isEmpty) {
      continue;
    }
    if (local == snapId || local == clientId || entry.key == clientId) {
      return entry.key;
    }
  }
  return null;
}

RideChatMessage mergeRideChatReconcile({
  required RideChatMessage existing,
  required RideChatMessage incoming,
  required String snapshotMessageId,
}) {
  final resolvedId = snapshotMessageId.trim().isNotEmpty
      ? snapshotMessageId.trim()
      : incoming.id;
  final resolvedStatus = rideChatStatusIsPending(incoming.status) &&
          rideChatStatusIsPending(existing.status)
      ? existing.status
      : (rideChatStatusIsPending(existing.status) ? 'sent' : incoming.status);
  return RideChatMessage(
    id: resolvedId,
    rideId: incoming.rideId,
    messageId: incoming.messageId.isNotEmpty ? incoming.messageId : resolvedId,
    senderId: incoming.senderId.isNotEmpty ? incoming.senderId : existing.senderId,
    senderRole:
        incoming.senderRole.isNotEmpty ? incoming.senderRole : existing.senderRole,
    type: incoming.type.isNotEmpty ? incoming.type : existing.type,
    text: incoming.text.isNotEmpty ? incoming.text : existing.text,
    imageUrl: incoming.imageUrl.isNotEmpty ? incoming.imageUrl : existing.imageUrl,
    createdAt: existing.createdAt > 0 ? existing.createdAt : incoming.createdAt,
    status: resolvedStatus,
    isRead: incoming.isRead || existing.isRead,
    localTempId: existing.localTempId.isNotEmpty
        ? existing.localTempId
        : incoming.localTempId,
  );
}

class RideChatMapApplyResult {
  const RideChatMapApplyResult({
    required this.applied,
    required this.skippedDuplicate,
    this.reconciledLocalKey,
    this.oldStatus,
    this.newStatus,
  });

  final bool applied;
  final bool skippedDuplicate;
  final String? reconciledLocalKey;
  final String? oldStatus;
  final String? newStatus;
}

/// Applies an RTDB child event to the in-memory chat map (own-message reconcile aware).
RideChatMapApplyResult applyIncomingRideChatToMap({
  required Map<String, RideChatMessage> byId,
  required String snapshotMessageId,
  required RideChatMessage incoming,
  required bool isIncoming,
}) {
  final snapId = snapshotMessageId.trim();
  if (snapId.isEmpty) {
    return const RideChatMapApplyResult(applied: false, skippedDuplicate: false);
  }

  if (isIncoming) {
    byId[snapId] = incoming;
    return const RideChatMapApplyResult(applied: true, skippedDuplicate: false);
  }

  final localKey = findRideChatLocalMapKey(
    byId: byId,
    snapshotMessageId: snapId,
    incoming: incoming,
  );
  if (localKey != null) {
    final existing = byId[localKey]!;
    if (rideChatStatusIsPending(existing.status) &&
        !rideChatStatusIsPending(incoming.status)) {
      final merged = mergeRideChatReconcile(
        existing: existing,
        incoming: incoming,
        snapshotMessageId: snapId,
      );
      if (localKey != snapId) {
        byId.remove(localKey);
      }
      byId[snapId] = merged;
      return RideChatMapApplyResult(
        applied: true,
        skippedDuplicate: false,
        reconciledLocalKey: localKey,
        oldStatus: existing.status,
        newStatus: merged.status,
      );
    }
    if (sameRideChatMessageSnapshot(existing, incoming)) {
      return RideChatMapApplyResult(
        applied: false,
        skippedDuplicate: true,
        reconciledLocalKey: localKey,
        oldStatus: existing.status,
        newStatus: incoming.status,
      );
    }
    if (localKey != snapId) {
      byId.remove(localKey);
    }
    byId[snapId] = incoming;
    return RideChatMapApplyResult(
      applied: true,
      skippedDuplicate: false,
      reconciledLocalKey: localKey,
      oldStatus: existing.status,
      newStatus: incoming.status,
    );
  }

  byId[snapId] = incoming;
  return const RideChatMapApplyResult(applied: true, skippedDuplicate: false);
}

String formatRideChatKnownIds(Iterable<String> ids, {int max = 12}) {
  final list = ids.map((id) => id.trim()).where((id) => id.isNotEmpty).toList();
  if (list.length <= max) {
    return list.join(',');
  }
  return '${list.take(max).join(',')}…(+${list.length - max})';
}

/// Pure append-only chat payload — single `.set()`, no side effects.
Map<String, dynamic> buildPureAppendChatPayload({
  required String messageId,
  required String rideId,
  required String senderId,
  required String senderRole,
  required String text,
  String type = 'text',
  int? clientCreatedAtMs,
}) {
  final clientCreatedAt =
      clientCreatedAtMs ?? DateTime.now().millisecondsSinceEpoch;
  return <String, dynamic>{
    'id': messageId,
    'message_id': messageId,
    'ride_id': rideId,
    'senderId': senderId,
    'sender_id': senderId,
    'senderRole': senderRole,
    'sender_role': senderRole,
    'text': text.trim(),
    'type': type,
    'status': 'sent',
    'client_message_id': messageId,
    'client_messageId': messageId,
    'created_at_client': clientCreatedAt,
    // Numeric timestamps only — ServerValue placeholders block indexed listeners
    // and can leave the sender stuck on "Sending…" until server resolution.
    'createdAt': clientCreatedAt,
    'created_at': clientCreatedAt,
    'timestamp': clientCreatedAt,
    'server_ack': true,
  };
}

RideChatMessage? parseRideChatMessageEntry({
  required String rideId,
  required String messageId,
  required dynamic raw,
}) {
  if (messageId.isEmpty || raw is! Map) {
    return null;
  }

  try {
    final map = <String, dynamic>{};
    raw.forEach((nestedKey, nestedValue) {
      if (nestedKey != null) {
        map[nestedKey.toString()] = nestedValue;
      }
    });

    final text = map['text']?.toString().trim() ?? '';
    final imageUrl = (map['imageUrl'] ?? map['image_url'])?.toString().trim() ?? '';
    if (text.isEmpty && imageUrl.isEmpty) {
      return null;
    }

    final senderId = (map['senderId'] ?? map['sender_id'])?.toString().trim() ?? '';
    final senderRole = _normalizeSenderRole(map['senderRole'] ?? map['sender_role']);
    final createdAt = rideChatTimestampFromRaw(
      primary: map['timestamp'] ?? map['created_at'],
      fallback: map['created_at_client'],
    );
    final status = rideChatStatusFromMessageMap(map);

    return RideChatMessage(
      id: messageId,
      rideId: rideId,
      messageId: (map['messageId'] ?? map['message_id'])?.toString().trim().isNotEmpty == true
          ? (map['messageId'] ?? map['message_id']).toString().trim()
          : messageId,
      senderId: senderId,
      senderRole: senderRole,
      type: (map['type']?.toString().trim().toLowerCase() ?? 'text'),
      text: text,
      imageUrl: imageUrl,
      createdAt: createdAt,
      status: status,
      isRead: map['read'] == true,
      localTempId: rideChatClientMessageIdFromMap(
        map,
        fallbackMessageId: messageId,
      ),
    );
  } catch (_) {
    return null;
  }
}

List<RideChatMessage> sortedRideChatMessagesFromMap(
  Map<String, RideChatMessage> byId,
) {
  final list = byId.values.toList();
  list.sort((a, b) {
    final timestampCompare = a.createdAt.compareTo(b.createdAt);
    if (timestampCompare != 0) {
      return timestampCompare;
    }
    return a.id.compareTo(b.id);
  });
  return List<RideChatMessage>.unmodifiable(list);
}

void trimRideChatMessagesById(
  Map<String, RideChatMessage> byId, {
  int maxCount = kMaxRideChatMessagesInMemory,
}) {
  if (byId.length <= maxCount) {
    return;
  }
  final sorted = sortedRideChatMessagesFromMap(byId);
  final removeCount = sorted.length - maxCount;
  for (var i = 0; i < removeCount; i++) {
    byId.remove(sorted[i].id);
  }
}

RideChatSnapshot parseRideChatSnapshot({
  required String rideId,
  required dynamic raw,
}) {
  final messages = <RideChatMessage>[];
  var invalidRecordCount = 0;

  if (raw is! Map) {
    return const RideChatSnapshot(
      messages: <RideChatMessage>[],
      invalidRecordCount: 0,
    );
  }

  raw.forEach((key, value) {
    try {
      final messageId = key?.toString().trim() ?? '';
      if (messageId.isEmpty || value is! Map) {
        invalidRecordCount += 1;
        return;
      }

      final map = <String, dynamic>{};
      value.forEach((nestedKey, nestedValue) {
        if (nestedKey != null) {
          map[nestedKey.toString()] = nestedValue;
        }
      });

      final text = map['text']?.toString().trim() ?? '';
      final imageUrl = (map['imageUrl'] ?? map['image_url'])?.toString().trim() ?? '';
      if (text.isEmpty && imageUrl.isEmpty) {
        invalidRecordCount += 1;
        return;
      }

      final senderId = (map['senderId'] ?? map['sender_id'])?.toString().trim() ?? '';
      final senderRole = _normalizeSenderRole(map['senderRole'] ?? map['sender_role']);
      final createdAt = rideChatTimestampFromRaw(
        primary: map['timestamp'] ?? map['created_at'],
        fallback: map['created_at_client'],
      );
      final status = rideChatStatusFromMessageMap(map);

      messages.add(
        RideChatMessage(
          id: messageId,
          rideId: rideId,
          messageId: (map['messageId'] ?? map['message_id'])?.toString().trim().isNotEmpty == true
              ? (map['messageId'] ?? map['message_id']).toString().trim()
              : messageId,
          senderId: senderId,
          senderRole: senderRole,
          type: (map['type']?.toString().trim().toLowerCase() ?? 'text'),
          text: text,
          imageUrl: imageUrl,
          createdAt: createdAt,
          status: status,
          isRead: map['read'] == true,
          localTempId: rideChatClientMessageIdFromMap(
            map,
            fallbackMessageId: messageId,
          ),
        ),
      );
    } catch (_) {
      invalidRecordCount += 1;
    }
  });

  messages.sort((a, b) {
    final timestampCompare = a.createdAt.compareTo(b.createdAt);
    if (timestampCompare != 0) {
      return timestampCompare;
    }
    return a.id.compareTo(b.id);
  });

  return RideChatSnapshot(
    messages: List<RideChatMessage>.unmodifiable(messages),
    invalidRecordCount: invalidRecordCount,
  );
}

int rideChatTimestampFromRaw({required dynamic primary, dynamic fallback}) {
  final primaryValue = _parseTimestamp(primary);
  if (primaryValue != null) {
    return primaryValue;
  }
  return _parseTimestamp(fallback) ?? 0;
}

int? _parseTimestamp(dynamic value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value.trim());
  }
  return null;
}

String _normalizeSenderRole(dynamic value) {
  final normalized = value?.toString().trim().toLowerCase() ?? '';
  if (normalized == 'rider' || normalized == 'driver') {
    return normalized;
  }
  if (normalized == 'system' || normalized == 'nexride' || normalized == 'support') {
    return 'system';
  }
  return 'unknown';
}

String _normalizeStatus(dynamic value) {
  final normalized = value?.toString().trim().toLowerCase() ?? '';
  if (normalized == 'failed' || normalized == 'pending' || normalized == 'sending') {
    return normalized;
  }
  if (normalized.isEmpty) {
    return 'sent';
  }
  return normalized;
}

String rideChatStatusFromMessageMap(Map<String, dynamic> map) {
  if (map['server_ack'] == true) {
    return 'sent';
  }
  final localStatus = map['local_status']?.toString().trim().toLowerCase() ?? '';
  if (localStatus == 'sending' || localStatus == 'failed') {
    return localStatus;
  }
  final rawClientStatus = map['client_status']?.toString().trim().toLowerCase() ?? '';
  if (rawClientStatus == 'failed' || rawClientStatus == 'pending' || rawClientStatus == 'sending') {
    return rawClientStatus;
  }
  return _normalizeStatus(map['status']);
}

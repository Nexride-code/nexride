class RideChatMessage {
  const RideChatMessage({
    required this.id,
    required this.rideId,
    required this.senderId,
    required this.senderRole,
    required this.text,
    required this.createdAt,
    required this.status,
    required this.isRead,
  });

  final String id;
  final String rideId;
  final String senderId;
  final String senderRole;
  final String text;
  final int createdAt;
  final String status;
  final bool isRead;

  bool isSentBy(String currentUserId) {
    return currentUserId.isNotEmpty && senderId == currentUserId;
  }

  String get deliveryLabel {
    if (status == 'pending' || status == 'sending') {
      return 'Sending…';
    }
    if (isRead) {
      return 'Read';
    }
    if (status == 'failed') {
      return 'Failed';
    }
    return 'Sent';
  }
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
  return 'chats/$normalizedRideId/messages';
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
    if (text.isEmpty) {
      return null;
    }

    final senderId = map['sender_id']?.toString().trim() ?? '';
    final senderRole = _normalizeSenderRole(map['sender_role']);
    final createdAt = rideChatTimestampFromRaw(
      primary: map['created_at'],
      fallback: map['created_at_client'],
    );
    final status = _normalizeStatus(map['status']);

    return RideChatMessage(
      id: messageId,
      rideId: rideId,
      senderId: senderId,
      senderRole: senderRole,
      text: text,
      createdAt: createdAt,
      status: status,
      isRead: map['read'] == true,
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
      if (text.isEmpty) {
        invalidRecordCount += 1;
        return;
      }

      final senderId = map['sender_id']?.toString().trim() ?? '';
      final senderRole = _normalizeSenderRole(map['sender_role']);
      final createdAt = rideChatTimestampFromRaw(
        primary: map['created_at'],
        fallback: map['created_at_client'],
      );
      final status = _normalizeStatus(map['status']);

      messages.add(
        RideChatMessage(
          id: messageId,
          rideId: rideId,
          senderId: senderId,
          senderRole: senderRole,
          text: text,
          createdAt: createdAt,
          status: status,
          isRead: map['read'] == true,
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

int rideChatTimestampFromRaw({
  required dynamic primary,
  dynamic fallback,
}) {
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
  return 'unknown';
}

String _normalizeStatus(dynamic value) {
  final normalized = value?.toString().trim().toLowerCase() ?? '';
  if (normalized.isEmpty) {
    return 'sent';
  }
  if (normalized == 'pending' || normalized == 'sending') {
    return normalized;
  }
  return normalized;
}

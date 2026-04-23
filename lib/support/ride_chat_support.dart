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
    if (isRead) {
      return 'Read';
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

String canonicalRideChatMetaPath(String rideId) {
  final normalizedRideId = rideId.trim();
  return 'ride_chats/$normalizedRideId/meta';
}

String canonicalRideChatUnreadCountPath(String rideId, String uid) {
  final r = rideId.trim();
  final u = uid.trim();
  return 'ride_chats/$r/unread/$u/count';
}

String canonicalRideChatUnreadUpdatedAtPath(String rideId, String uid) {
  final r = rideId.trim();
  final u = uid.trim();
  return 'ride_chats/$r/unread/$u/updated_at';
}

String canonicalRideChatParticipantPath(String rideId, String uid) {
  final r = rideId.trim();
  final u = uid.trim();
  return 'ride_chats/$r/participants/$u';
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
    final imageUrl = map['image_url']?.toString().trim() ?? '';
    if (text.isEmpty && imageUrl.isEmpty) {
      return null;
    }

    final senderId = map['sender_id']?.toString().trim() ?? '';
    final senderRole = _normalizeSenderRole(map['sender_role']);
    final createdAt = rideChatTimestampFromRaw(
      primary: map['created_at'],
      fallback: map['created_at_client'],
    );
    final status = rideChatStatusFromMessageMap(map);

    return RideChatMessage(
      id: messageId,
      rideId: rideId,
      messageId: map['message_id']?.toString().trim().isNotEmpty == true
          ? map['message_id'].toString().trim()
          : messageId,
      senderId: senderId,
      senderRole: senderRole,
      type: (map['type']?.toString().trim().toLowerCase() ?? 'text'),
      text: text,
      imageUrl: imageUrl,
      createdAt: createdAt,
      status: status,
      isRead: map['read'] == true,
      localTempId: map['local_temp_id']?.toString().trim() ?? '',
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
      final imageUrl = map['image_url']?.toString().trim() ?? '';
      if (text.isEmpty && imageUrl.isEmpty) {
        invalidRecordCount += 1;
        return;
      }

      final senderId = map['sender_id']?.toString().trim() ?? '';
      final senderRole = _normalizeSenderRole(map['sender_role']);
      final createdAt = rideChatTimestampFromRaw(
        primary: map['created_at'],
        fallback: map['created_at_client'],
      );
      final status = rideChatStatusFromMessageMap(map);

      messages.add(
        RideChatMessage(
          id: messageId,
          rideId: rideId,
          messageId: map['message_id']?.toString().trim().isNotEmpty == true
              ? map['message_id'].toString().trim()
              : messageId,
          senderId: senderId,
          senderRole: senderRole,
          type: (map['type']?.toString().trim().toLowerCase() ?? 'text'),
          text: text,
          imageUrl: imageUrl,
          createdAt: createdAt,
          status: status,
          isRead: map['read'] == true,
          localTempId: map['local_temp_id']?.toString().trim() ?? '',
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

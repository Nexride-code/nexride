/// RTDB delivery chat models and paths (`delivery_chats/{deliveryId}`).
library;

class DeliveryChatMessage {
  const DeliveryChatMessage({
    required this.id,
    required this.deliveryId,
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
  final String deliveryId;
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

  bool isSentBy(String currentUserId) =>
      currentUserId.isNotEmpty && senderId == currentUserId;

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

class DeliveryChatSnapshot {
  const DeliveryChatSnapshot({
    required this.messages,
    required this.invalidRecordCount,
  });

  final List<DeliveryChatMessage> messages;
  final int invalidRecordCount;
}

String canonicalDeliveryChatMessagesPath(String deliveryId) =>
    'delivery_chats/${deliveryId.trim()}/messages';

String canonicalDeliveryChatMetaPath(String deliveryId) =>
    'delivery_chats/${deliveryId.trim()}/meta';

String canonicalDeliveryChatUnreadCountPath(String deliveryId, String uid) =>
    'delivery_chats/${deliveryId.trim()}/unread/${uid.trim()}/count';

String canonicalDeliveryChatParticipantPath(String deliveryId, String uid) =>
    'delivery_chats/${deliveryId.trim()}/participants/${uid.trim()}';

const String kDeliveryChatSafetyNotice =
    'Keep communication respectful. Do not share private contact or payment '
    'details. Harassment, threats, sexual content, or abuse are prohibited. '
    'Report unsafe behavior immediately.';

DeliveryChatSnapshot parseDeliveryChatSnapshot({
  required String deliveryId,
  required dynamic raw,
}) {
  final messages = <DeliveryChatMessage>[];
  var invalidRecordCount = 0;
  if (raw is! Map) {
    return DeliveryChatSnapshot(messages: messages, invalidRecordCount: 0);
  }
  raw.forEach((key, value) {
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
    final imageUrl =
        (map['imageUrl'] ?? map['image_url'])?.toString().trim() ?? '';
    if (text.isEmpty && imageUrl.isEmpty) {
      invalidRecordCount += 1;
      return;
    }
    final senderId =
        (map['senderId'] ?? map['sender_id'])?.toString().trim() ?? '';
    final senderRole = _normalizeSenderRole(map['senderRole'] ?? map['sender_role']);
    final createdAt = _timestampFromRaw(
      primary: map['created_at_ms'] ?? map['timestamp'] ?? map['created_at'],
      fallback: map['created_at_client'],
    );
    messages.add(
      DeliveryChatMessage(
        id: messageId,
        deliveryId: deliveryId,
        messageId: (map['messageId'] ?? map['message_id'])?.toString().trim().isNotEmpty ==
                true
            ? (map['messageId'] ?? map['message_id']).toString().trim()
            : messageId,
        senderId: senderId,
        senderRole: senderRole,
        type: map['type']?.toString().trim().toLowerCase() ?? 'text',
        text: text,
        imageUrl: imageUrl,
        createdAt: createdAt,
        status: _statusFromMap(map),
        isRead: map['read'] == true || _readByCurrent(map),
        localTempId:
            (map['localTempId'] ?? map['local_temp_id'])?.toString().trim() ?? '',
      ),
    );
  });
  messages.sort((a, b) {
    final c = a.createdAt.compareTo(b.createdAt);
    return c != 0 ? c : a.id.compareTo(b.id);
  });
  return DeliveryChatSnapshot(
    messages: List<DeliveryChatMessage>.unmodifiable(messages),
    invalidRecordCount: invalidRecordCount,
  );
}

bool _readByCurrent(Map<String, dynamic> map) {
  final readBy = map['read_by'];
  if (readBy is! Map) {
    return false;
  }
  return readBy.isNotEmpty;
}

int _timestampFromRaw({required dynamic primary, dynamic fallback}) {
  final p = _parseTimestamp(primary);
  if (p != null) {
    return p;
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
  final n = value?.toString().trim().toLowerCase() ?? '';
  const allowed = <String>{
    'customer',
    'rider',
    'driver',
    'merchant',
    'admin',
    'support',
    'system',
  };
  if (allowed.contains(n)) {
    return n == 'rider' ? 'customer' : n;
  }
  return 'unknown';
}

String _statusFromMap(Map<String, dynamic> map) {
  if (map['server_ack'] == true) {
    return 'sent';
  }
  final local = map['local_status']?.toString().trim().toLowerCase() ?? '';
  if (local == 'sending' || local == 'failed' || local == 'pending') {
    return local;
  }
  final raw = map['status']?.toString().trim().toLowerCase() ?? '';
  if (raw == 'failed' || raw == 'sending' || raw == 'pending') {
    return raw;
  }
  return raw.isEmpty ? 'sent' : raw;
}

import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart' as rtdb;

import '../support/delivery_chat_support.dart';

/// RTDB delivery chat send/listen helper (customer, driver, merchant).
class DeliveryChatService {
  DeliveryChatService({
    rtdb.FirebaseDatabase? database,
    FirebaseFunctions? functions,
  })  : _database = database ?? rtdb.FirebaseDatabase.instance,
        _functions =
            functions ?? FirebaseFunctions.instanceFor(region: 'us-central1');

  final rtdb.FirebaseDatabase _database;
  final FirebaseFunctions _functions;

  rtdb.DatabaseReference _messagesRef(String deliveryId) =>
      _database.ref(canonicalDeliveryChatMessagesPath(deliveryId));

  StreamSubscription<rtdb.DatabaseEvent>? startListener({
    required String deliveryId,
    required void Function(List<DeliveryChatMessage> messages) onMessages,
    void Function(Object error)? onError,
  }) {
    final ref = _messagesRef(deliveryId).orderByChild('created_at_ms');
    return ref.onValue.listen(
      (event) {
        try {
          final parsed = parseDeliveryChatSnapshot(
            deliveryId: deliveryId,
            raw: event.snapshot.value,
          );
          onMessages(parsed.messages);
        } catch (e) {
          onError?.call(e);
        }
      },
      onError: onError,
    );
  }

  Future<String?> sendText({
    required String deliveryId,
    required String senderRole,
    required String text,
    String? retryMessageId,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return 'Please sign in to send messages.';
    }
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    final messagesRef = _messagesRef(deliveryId);
    final messageNode = retryMessageId?.trim().isNotEmpty == true
        ? messagesRef.child(retryMessageId!.trim())
        : messagesRef.push();
    final messageId = messageNode.key?.trim() ?? '';
    if (messageId.isEmpty) {
      return 'Unable to send message right now.';
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    try {
      await messageNode.setWithPriority(<String, dynamic>{
        'sender_id': user.uid,
        'sender_role': senderRole,
        'text': trimmed,
        'created_at_ms': now,
        'timestamp': rtdb.ServerValue.timestamp,
        'status': 'sent',
        'server_ack': true,
      }, -now);
      await _database.ref(canonicalDeliveryChatMetaPath(deliveryId)).update(<String, dynamic>{
        'delivery_id': deliveryId,
        'last_message': trimmed,
        'last_message_sender_id': user.uid,
        'last_message_at': now,
        'updated_at': now,
      });
      unawaited(_notifyChatPush(deliveryId, messageId));
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<void> markRead({
    required String deliveryId,
    required String uid,
  }) async {
    await _database
        .ref(canonicalDeliveryChatUnreadCountPath(deliveryId, uid))
        .set(0);
  }

  Future<void> _notifyChatPush(String deliveryId, String messageId) async {
    try {
      await _functions.httpsCallable('notifyDeliveryChatMessage').call(
        <String, dynamic>{
          'deliveryId': deliveryId,
          'messageId': messageId,
        },
      );
    } catch (_) {
      // Push bridge optional until functions deploy.
    }
  }
}

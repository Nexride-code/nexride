import 'package:flutter_test/flutter_test.dart';
import 'package:nexride_driver/support/ride_chat_moderation.dart';
import 'package:nexride_driver/support/ride_chat_support.dart';

void main() {
  test('ride chat snapshot sorts by timestamp and skips malformed records', () {
    final snapshot = parseRideChatSnapshot(
      rideId: 'ride-123',
      raw: <String, dynamic>{
        'b': <String, dynamic>{
          'text': 'Second',
          'sender_id': 'driver-1',
          'sender_role': 'driver',
          'created_at': 20,
          'status': 'sent',
        },
        'a': <String, dynamic>{
          'text': 'First',
          'sender_id': 'rider-1',
          'sender_role': 'rider',
          'created_at': 10,
          'status': 'sent',
        },
        'broken': 'oops',
      },
    );

    expect(snapshot.invalidRecordCount, 1);
    expect(snapshot.messages.map((message) => message.id), <String>['a', 'b']);
    expect(snapshot.messages.first.text, 'First');
  });

  test('buildPureAppendChatPayload writes messages path fields only', () {
    const clientTs = 1700000000000;
    final payload = buildPureAppendChatPayload(
      messageId: 'msg-1',
      rideId: 'ride-789',
      senderId: 'driver-9',
      senderRole: 'driver',
      text: 'On my way',
      clientCreatedAtMs: clientTs,
    );

    expect(payload['id'], 'msg-1');
    expect(payload['ride_id'], 'ride-789');
    expect(payload['sender_id'], 'driver-9');
    expect(payload['sender_role'], 'driver');
    expect(payload['text'], 'On my way');
    expect(payload['created_at_client'], clientTs);
    expect(payload['timestamp'], clientTs);
  });

  test('applyIncomingRideChatToMap reconciles pending optimistic by same id', () {
    final byId = <String, RideChatMessage>{
      'msg-1': const RideChatMessage(
        id: 'msg-1',
        rideId: 'ride-1',
        messageId: 'msg-1',
        senderId: 'driver-1',
        senderRole: 'driver',
        type: 'text',
        text: 'test driver',
        imageUrl: '',
        createdAt: 100,
        status: 'sending',
        isRead: false,
        localTempId: 'msg-1',
      ),
    };
    final incoming = parseRideChatMessageEntry(
      rideId: 'ride-1',
      messageId: 'msg-1',
      raw: buildPureAppendChatPayload(
        messageId: 'msg-1',
        rideId: 'ride-1',
        senderId: 'driver-1',
        senderRole: 'driver',
        text: 'test driver',
        clientCreatedAtMs: 100,
      ),
    );
    expect(incoming, isNotNull);

    final result = applyIncomingRideChatToMap(
      byId: byId,
      snapshotMessageId: 'msg-1',
      incoming: incoming!,
      isIncoming: false,
    );

    expect(result.applied, isTrue);
    expect(result.reconciledLocalKey, 'msg-1');
    expect(byId['msg-1']?.status, 'sent');
    expect(byId['msg-1']?.deliveryLabel, 'Sent');
  });

  test('scanRideChatMessage warns on phone and whatsapp', () {
    expect(scanRideChatMessage('call me on 08031234567'), isNotNull);
    expect(scanRideChatMessage('chat on whatsapp'), isNotNull);
    expect(scanRideChatMessage('see you at the gate'), isNull);
  });
}

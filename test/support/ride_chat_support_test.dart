import 'package:flutter_test/flutter_test.dart';
import 'package:nexride/support/ride_chat_moderation.dart';
import 'package:nexride/support/ride_chat_support.dart';

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
          'read': true,
        },
        'a': <String, dynamic>{
          'text': 'First',
          'sender_id': 'rider-1',
          'sender_role': 'rider',
          'created_at': 10,
          'status': 'sent',
          'read': false,
        },
        'broken_null_text': <String, dynamic>{
          'sender_role': 'driver',
          'created_at': 15,
        },
        'broken_not_map': 'oops',
      },
    );

    expect(snapshot.invalidRecordCount, 2);
    expect(snapshot.messages.map((message) => message.id), <String>['a', 'b']);
    expect(snapshot.messages.first.text, 'First');
    expect(snapshot.messages.last.deliveryLabel, 'Read');
  });

  test('ride chat snapshot falls back to client timestamp safely', () {
    final snapshot = parseRideChatSnapshot(
      rideId: 'ride-456',
      raw: <String, dynamic>{
        'message-1': <String, dynamic>{
          'text': 'Fallback timestamp',
          'sender_role': 'driver',
          'created_at': <String, dynamic>{'.sv': 'timestamp'},
          'created_at_client': '42',
        },
      },
    );

    expect(snapshot.invalidRecordCount, 0);
    expect(snapshot.messages.single.createdAt, 42);
    expect(snapshot.messages.single.senderId, isEmpty);
  });

  test('buildRideChatInitUpdates writes meta and participants paths', () {
    final updates = buildRideChatInitUpdates(
      rideId: 'ride-789',
      riderId: 'rider-1',
      driverId: 'driver-9',
    );

    expect(updates['ride_chats/ride-789/meta/ride_id'], 'ride-789');
    expect(updates['ride_chats/ride-789/meta/rider_id'], 'rider-1');
    expect(updates['ride_chats/ride-789/meta/driver_id'], 'driver-9');
    expect(updates['ride_chats/ride-789/meta/status'], 'active');
    expect(
      updates['ride_chats/ride-789/participants/rider-1'],
      isA<Map<String, dynamic>>(),
    );
    expect(
      updates['ride_chats/ride-789/participants/driver-9'],
      isA<Map<String, dynamic>>(),
    );
  });

  test('scanRideChatMessage warns on phone and whatsapp', () {
    expect(
      scanRideChatMessage('call me on 08031234567'),
      isNotNull,
    );
    expect(
      scanRideChatMessage('chat on whatsapp'),
      isNotNull,
    );
    expect(scanRideChatMessage('see you at the gate'), isNull);
  });
}

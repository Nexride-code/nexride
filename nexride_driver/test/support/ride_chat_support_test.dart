import 'package:flutter_test/flutter_test.dart';
import 'package:nexride_driver/support/ride_chat_support.dart';

void main() {
  test('driver ride chat snapshot sorts safely and ignores malformed rows', () {
    final snapshot = parseRideChatSnapshot(
      rideId: 'ride-789',
      raw: <String, dynamic>{
        'message-2': <String, dynamic>{
          'text': 'Later',
          'sender_id': 'driver-1',
          'sender_role': 'driver',
          'created_at': 30,
          'read': true,
        },
        'message-1': <String, dynamic>{
          'text': 'Sooner',
          'sender_id': 'rider-1',
          'sender_role': 'rider',
          'created_at': 10,
          'read': false,
        },
        'bad': <String, dynamic>{
          'sender_role': 'rider',
        },
      },
    );

    expect(snapshot.invalidRecordCount, 1);
    expect(
      snapshot.messages.map((message) => message.text),
      <String>['Sooner', 'Later'],
    );
  });

  test('driver ride chat timestamp helper handles numeric strings safely', () {
    expect(
      rideChatTimestampFromRaw(primary: '55', fallback: null),
      55,
    );
    expect(
      rideChatTimestampFromRaw(
        primary: <String, dynamic>{'.sv': 'timestamp'},
        fallback: 77,
      ),
      77,
    );
  });
}

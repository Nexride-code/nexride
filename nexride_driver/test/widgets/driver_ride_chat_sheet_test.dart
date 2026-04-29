import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexride_driver/support/ride_chat_support.dart';
import 'package:nexride_driver/widgets/driver_ride_chat_sheet.dart';

void main() {
  testWidgets('driver ride chat sheet shows send error and keeps UI alive', (
    WidgetTester tester,
  ) async {
    final messages = ValueNotifier<List<RideChatMessage>>(
      const <RideChatMessage>[],
    );

    addTearDown(messages.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DriverRideChatSheet(
            rideId: 'ride-1',
            currentUserId: 'driver-1',
            messagesListenable: messages,
            onSendMessage: (String rideId, String text) async =>
                'Unable to send message right now.',
            onRetryMessage:
                (String rideId, RideChatMessage message) async => null,
            onSendImage:
                (String rideId, DriverRideChatImageSource source) async => null,
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'Reply');
    await tester.tap(find.byType(ElevatedButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Unable to send message right now.'), findsOneWidget);
    expect(find.byIcon(Icons.send), findsOneWidget);
  });

  testWidgets('driver ride chat sheet prevents double send while pending', (
    WidgetTester tester,
  ) async {
    final messages = ValueNotifier<List<RideChatMessage>>(
      const <RideChatMessage>[],
    );
    final completer = Completer<String?>();
    var sendCount = 0;

    addTearDown(messages.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DriverRideChatSheet(
            rideId: 'ride-2',
            currentUserId: 'driver-1',
            messagesListenable: messages,
            onSendMessage: (String rideId, String text) {
              sendCount += 1;
              return completer.future;
            },
            onRetryMessage:
                (String rideId, RideChatMessage message) async => null,
            onSendImage:
                (String rideId, DriverRideChatImageSource source) async => null,
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'On my way');
    await tester.tap(find.byType(ElevatedButton));
    await tester.pump();
    await tester.tap(find.byType(ElevatedButton));
    await tester.pump();

    expect(sendCount, 1);

    completer.complete(null);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.send), findsOneWidget);
  });

  testWidgets(
    'driver ride chat sheet shows spinner until onSendMessage completes',
    (WidgetTester tester) async {
      final messages = ValueNotifier<List<RideChatMessage>>(
        const <RideChatMessage>[],
      );
      final completer = Completer<String?>();

      addTearDown(messages.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DriverRideChatSheet(
              rideId: 'ride-3',
              currentUserId: 'driver-1',
              messagesListenable: messages,
              onSendMessage: (String rideId, String text) => completer.future,
              onRetryMessage:
                  (String rideId, RideChatMessage message) async => null,
              onSendImage: (String rideId, DriverRideChatImageSource source) async =>
                  null,
            ),
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), 'Checking in');
      await tester.tap(find.byType(ElevatedButton));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      completer.complete(
        'Sending this message took too long. Please try again.',
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Sending this message took too long. Please try again.'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.send), findsOneWidget);
    },
  );
}

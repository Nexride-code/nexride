import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexride/support/ride_chat_support.dart';
import 'package:nexride/widgets/ride_chat_sheet.dart';

void main() {
  testWidgets('ride chat sheet shows send error and recovers spinner', (
    WidgetTester tester,
  ) async {
    final messages = ValueNotifier<List<RideChatMessage>>(
      const <RideChatMessage>[],
    );

    addTearDown(messages.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RideChatSheet(
            rideId: 'ride-1',
            currentUserId: 'rider-1',
            messagesListenable: messages,
            onSendMessage: (String rideId, String text) async =>
                'Unable to send message right now.',
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'Hello driver');
    await tester.tap(find.byType(ElevatedButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Unable to send message right now.'), findsOneWidget);
    expect(find.byIcon(Icons.send), findsOneWidget);
  });

  testWidgets('ride chat sheet prevents double send while request is pending', (
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
          body: RideChatSheet(
            rideId: 'ride-2',
            currentUserId: 'rider-1',
            messagesListenable: messages,
            onSendMessage: (String rideId, String text) {
              sendCount += 1;
              return completer.future;
            },
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'Hello again');
    await tester.tap(find.byType(ElevatedButton));
    await tester.pump();
    await tester.tap(find.byType(ElevatedButton));
    await tester.pump();

    expect(sendCount, 1);

    completer.complete(null);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.send), findsOneWidget);
  });

  testWidgets('ride chat sheet times out a stalled send and unlocks UI', (
    WidgetTester tester,
  ) async {
    final messages = ValueNotifier<List<RideChatMessage>>(
      const <RideChatMessage>[],
    );
    final completer = Completer<String?>();

    addTearDown(messages.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RideChatSheet(
            rideId: 'ride-3',
            currentUserId: 'rider-1',
            messagesListenable: messages,
            onSendMessage: (String rideId, String text) => completer.future,
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'Still there?');
    await tester.tap(find.byType(ElevatedButton));
    await tester.pump();
    await tester.pump(const Duration(seconds: 11));

    expect(
      find.text('Sending this message took too long. Please try again.'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.send), findsOneWidget);
  });
}

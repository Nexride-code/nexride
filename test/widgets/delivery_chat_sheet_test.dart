import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexride/support/delivery_chat_support.dart';
import 'package:nexride/widgets/delivery_chat_sheet.dart';

void main() {
  testWidgets('delivery chat sheet shows safety banner', (tester) async {
    final messages = ValueNotifier<List<DeliveryChatMessage>>(<DeliveryChatMessage>[]);
    addTearDown(messages.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DeliveryChatSheet(
            deliveryId: 'del_test',
            currentUserId: 'user1',
            messagesListenable: messages,
            onSendMessage: (_, __) async => null,
            onRetryMessage: (_, __) async => null,
          ),
        ),
      ),
    );
    expect(find.textContaining('Keep communication respectful'), findsOneWidget);
  });
}

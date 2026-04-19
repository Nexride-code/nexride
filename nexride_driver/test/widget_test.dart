import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('driver test harness renders a material shell', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Text('NexRide Driver'),
        ),
      ),
    );

    expect(find.text('NexRide Driver'), findsOneWidget);
  });
}

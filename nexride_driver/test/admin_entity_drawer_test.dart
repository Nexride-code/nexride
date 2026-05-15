import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexride_driver/admin/widgets/admin_entity_drawer.dart';

void main() {
  testWidgets('AdminEntityDrawer lazy-loads first tab then second tab',
      (WidgetTester tester) async {
    final loads = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(size: Size(1200, 800)),
            child: AdminEntityDrawer(
              entityType: 'test_entity',
              entityId: 'e1',
              title: 'Test title',
              subtitle: 'Sub',
              tabs: const <AdminEntityTabSpec>[
                AdminEntityTabSpec(id: 'alpha', label: 'Alpha'),
                AdminEntityTabSpec(id: 'beta', label: 'Beta'),
              ],
              loadBody: (String tabId) async {
                loads.add(tabId);
                return Text('body-$tabId', key: ValueKey<String>('body-$tabId'));
              },
            ),
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pumpAndSettle();

    expect(loads, contains('alpha'));
    expect(find.byKey(const ValueKey<String>('body-alpha')), findsOneWidget);

    await tester.tap(find.text('Beta'));
    await tester.pumpAndSettle();

    expect(loads, contains('beta'));
    expect(find.byKey(const ValueKey<String>('body-beta')), findsOneWidget);
  });
}

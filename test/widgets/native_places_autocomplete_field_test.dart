import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexride/services/native_places_service.dart';
import 'package:nexride/widgets/native_places_autocomplete_field.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('nexride/places');

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'searchPlaces':
              return <Map<String, Object?>>[
                <String, Object?>{
                  'placeId': 'lekki_phase_1',
                  'primaryText': 'Lekki Phase 1',
                  'secondaryText': 'Lagos',
                  'fullText': 'Lekki Phase 1, Lagos',
                },
              ];
            case 'fetchPlaceDetails':
              return <String, Object?>{
                'placeId': 'lekki_phase_1',
                'address': 'Lekki Phase 1, Lagos',
                'latitude': 6.4474,
                'longitude': 3.4722,
              };
          }
          return null;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('shows suggestions and forwards selection', (tester) async {
    final controller = TextEditingController();
    NativePlaceSuggestion? tappedSuggestion;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(24),
            child: NativePlacesAutocompleteField(
              controller: controller,
              hintText: 'Pickup location',
              onSelected: (suggestion) async {
                tappedSuggestion = suggestion;
              },
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'Lekki');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(find.text('Lekki Phase 1'), findsOneWidget);
    expect(find.text('Lagos'), findsOneWidget);

    await tester.tap(find.text('Lekki Phase 1'));
    await tester.pumpAndSettle();

    expect(tappedSuggestion?.placeId, 'lekki_phase_1');
    expect(controller.text, 'Lekki Phase 1, Lagos');
  });

  testWidgets('keeps suggestions visible inside a map-style stack', (
    tester,
  ) async {
    final controller = TextEditingController();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Positioned.fill(
                child: Container(color: const Color(0xFFE7E7E7)),
              ),
              Positioned(
                top: 60,
                left: 20,
                right: 20,
                child: NativePlacesAutocompleteField(
                  controller: controller,
                  hintText: 'Where to?',
                  onSelected: (_) async {},
                ),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: Container(
                  height: 180,
                  color: Colors.black12,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'Lekki');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(find.text('Lekki Phase 1'), findsOneWidget);
    expect(find.text('Lagos'), findsOneWidget);
  });
}

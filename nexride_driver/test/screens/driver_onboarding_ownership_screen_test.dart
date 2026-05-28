import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexride_driver/screens/driver_onboarding_ownership_screen.dart';
import 'package:nexride_driver/support/driver_profile_support.dart';

void main() {
  testWidgets(
    'independent choice persists correct fields and completes',
    (WidgetTester tester) async {
      Map<String, Object?>? captured;
      var completed = false;

      await tester.pumpWidget(
        MaterialApp(
          home: DriverOnboardingOwnershipScreen(
            driverId: 'driver_1',
            serviceType: kServiceTypeBikeDispatch,
            onCompleted: () => completed = true,
            persistOwnershipUpdate: (Map<String, Object?> update) async {
              captured = update;
            },
          ),
        ),
      );

      await tester.tap(find.text('Independent dispatch rider'));
      await tester.pumpAndSettle();

      expect(captured, isNotNull);
      expect(captured!['ownership_mode'], kOwnershipIndividual);
      expect(captured!['business_id'], isNull);
      expect(captured!['dispatch_role'], kDispatchRoleIndependent);
      expect(captured![kOwnershipOnboardingCompleteField], isTrue);
      expect(completed, isTrue);
    },
  );

  testWidgets(
    'fleet invite path opens the injected redeem screen',
    (WidgetTester tester) async {
      var builderInvoked = false;

      await tester.pumpWidget(
        MaterialApp(
          home: DriverOnboardingOwnershipScreen(
            driverId: 'driver_1',
            serviceType: kServiceTypeVanDispatch,
            onCompleted: () {},
            fleetInviteScreenBuilder: (BuildContext _) {
              builderInvoked = true;
              return const Scaffold(
                body: Text('STUB_REDEEM_SCREEN'),
              );
            },
          ),
        ),
      );

      await tester.tap(find.text('I have a business/fleet invite'));
      await tester.pumpAndSettle();

      expect(builderInvoked, isTrue);
      expect(find.text('STUB_REDEEM_SCREEN'), findsOneWidget);
    },
  );
}

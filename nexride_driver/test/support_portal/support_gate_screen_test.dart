import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexride_driver/support_portal/models/support_models.dart';
import 'package:nexride_driver/support_portal/screens/support_gate_screen.dart';
import 'package:nexride_driver/support_portal/services/support_auth_service.dart';

void main() {
  testWidgets(
    'signed-in users without support access are returned to support login',
    (WidgetTester tester) async {
      _setDesktopViewport(tester);
      addTearDown(() => _resetViewport(tester));

      final authService = _FakeSupportAuthService(
        authenticatedUserUid: 'support_missing_uid_001',
        authenticatedUserEmail: 'user@nexride.com',
      );

      await tester.pumpWidget(
        MaterialApp(
          routes: <String, WidgetBuilder>{
            '/support/login': (_) => const Scaffold(body: SizedBox.shrink()),
          },
          home: SupportGateScreen(
            mode: SupportGateMode.dashboard,
            authService: authService,
            loginRoute: '/support/login',
            dashboardRoute: '/support/dashboard',
          ),
        ),
      );

      await tester.pump();
      await tester.pump();

      expect(find.text('Support access not authorized'), findsOneWidget);
      expect(find.textContaining('live Realtime Database'), findsOneWidget);
    },
  );
}

void _setDesktopViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1600, 1200);
  tester.view.devicePixelRatio = 1.0;
}

void _resetViewport(WidgetTester tester) {
  tester.view.resetPhysicalSize();
  tester.view.resetDevicePixelRatio();
}

class _FakeSupportAuthService extends SupportAuthService {
  _FakeSupportAuthService({
    this.authenticatedUserUid = '',
    this.authenticatedUserEmail = '',
  });

  String authenticatedUserUid;
  String authenticatedUserEmail;

  @override
  bool get hasAuthenticatedUser => authenticatedUserUid.trim().isNotEmpty;

  @override
  String get authenticatedUid => authenticatedUserUid.trim();

  @override
  String get authenticatedEmail => authenticatedUserEmail.trim();

  @override
  Future<SupportSession?> currentSession() async => null;

  @override
  Future<void> signOut() async {
    authenticatedUserUid = '';
    authenticatedUserEmail = '';
  }
}

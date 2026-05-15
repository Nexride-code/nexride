import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexride_driver/admin/admin_app.dart';
import 'package:nexride_driver/admin/admin_config.dart';
import 'package:nexride_driver/admin/admin_rbac.dart';
import 'package:nexride_driver/admin/models/admin_models.dart';
import 'package:nexride_driver/admin/screens/admin_gate_screen.dart';
import 'package:nexride_driver/admin/services/admin_auth_service.dart';
import 'package:nexride_driver/admin/services/admin_data_service.dart';

void main() {
  final adminSession = AdminSession(
    uid: 'admin_uid_001',
    email: 'admin@nexride.africa',
    displayName: 'Ops Admin',
    accessMode: 'database_role',
    adminRole: 'super_admin',
    permissions: permissionsForAdminRole('super_admin'),
  );

  testWidgets('standalone admin app redirects signed-out root users to login', (
    WidgetTester tester,
  ) async {
    _setDesktopViewport(tester);
    addTearDown(() => _resetViewport(tester));

    await tester.pumpWidget(
      AdminApp(
        initialization: Future<void>.value(),
        startupUri: Uri.parse('http://localhost/'),
        authService: _FakeAdminAuthService(null),
        dataService: _FakeAdminDataService(_emptySnapshot),
        enableRealtimeBadgeListeners: false,
      ),
    );

    await _pumpRouteTransition(tester);

    expect(find.text('Admin sign in'), findsOneWidget);
    expect(find.text('NexRide Admin'), findsOneWidget);
  });

  testWidgets('standalone admin app opens dashboard for signed-in admins', (
    WidgetTester tester,
  ) async {
    _setDesktopViewport(tester);
    addTearDown(() => _resetViewport(tester));

    await tester.pumpWidget(
      AdminApp(
        initialization: Future<void>.value(),
        startupUri: Uri.parse('http://localhost/dashboard'),
        authService: _FakeAdminAuthService(adminSession),
        dataService: _FakeAdminDataService(_emptySnapshot),
        enableRealtimeBadgeListeners: false,
      ),
    );

    await _pumpRouteTransition(tester);

    expect(find.text('Admin sign in'), findsOneWidget);
    expect(find.text('Continue to dashboard'), findsOneWidget);
    await tester.tap(find.text('Continue to dashboard'));
    await _pumpRouteTransition(tester);

    expect(find.text('NexRide Control Center'), findsWidgets);
    expect(find.text('Dashboard'), findsWidgets);
  });

  testWidgets('signed-in users without /admins access are returned to login', (
    WidgetTester tester,
  ) async {
    _setDesktopViewport(tester);
    addTearDown(() => _resetViewport(tester));

    await tester.pumpWidget(
      MaterialApp(
        routes: <String, WidgetBuilder>{
          AdminRoutePaths.adminLogin: (_) =>
              const Scaffold(body: SizedBox.shrink()),
        },
        home: AdminGateScreen(
          authService: _FakeAdminAuthService(
            null,
            authenticatedUserUid: 'unauthorized_uid_001',
            authenticatedUserEmail: 'user@nexride.africa',
          ),
          dataService: _FakeAdminDataService(_emptySnapshot),
          loginRoute: AdminRoutePaths.adminLogin,
          dashboardRoute: AdminRoutePaths.admin,
          enableRealtimeBadgeListeners: false,
        ),
      ),
    );

    await tester.pump();
    await tester.pump();

    expect(find.text('Admin access not authorized'), findsOneWidget);
    expect(
      find.textContaining('NexRide system administrator'),
      findsOneWidget,
    );
  });

  testWidgets('standalone admin routes switch sections without driver flow', (
    WidgetTester tester,
  ) async {
    _setDesktopViewport(tester);
    addTearDown(() => _resetViewport(tester));

    await tester.pumpWidget(
      AdminApp(
        initialization: Future<void>.value(),
        startupUri: Uri.parse('http://localhost/dashboard'),
        authService: _FakeAdminAuthService(adminSession),
        dataService: _FakeAdminDataService(_emptySnapshot),
        enableRealtimeBadgeListeners: false,
      ),
    );

    await _pumpRouteTransition(tester);

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.pushReplacementNamed(
      AdminPortalRoutePaths.pathForSection(AdminSection.drivers),
    );
    await _pumpRouteTransition(tester);

    expect(find.text('No driver records yet'), findsOneWidget);
    expect(find.textContaining('driver operations module'), findsOneWidget);
  });

  testWidgets('admin login path ignores stale support hash fragments', (
    WidgetTester tester,
  ) async {
    _setDesktopViewport(tester);
    addTearDown(() => _resetViewport(tester));

    await tester.pumpWidget(
      AdminApp(
        initialization: Future<void>.value(),
        startupUri: Uri(
          scheme: 'http',
          host: 'localhost',
          path: '/admin/login',
          fragment: '/support',
        ),
        authService: _FakeAdminAuthService(null),
        dataService: _FakeAdminDataService(_emptySnapshot),
        enableRealtimeBadgeListeners: false,
      ),
    );

    await _pumpRouteTransition(tester);

    expect(find.text('Admin sign in'), findsOneWidget);
    expect(find.text('Open support portal'), findsNothing);
    expect(find.text('NexRide Support Portal'), findsNothing);
  });
}

Future<void> _pumpRouteTransition(WidgetTester tester) async {
  for (var index = 0; index < 10; index++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

void _setDesktopViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1600, 1200);
  tester.view.devicePixelRatio = 1.0;
}

void _resetViewport(WidgetTester tester) {
  tester.view.resetPhysicalSize();
  tester.view.resetDevicePixelRatio();
}

class _FakeAdminAuthService extends AdminAuthService {
  _FakeAdminAuthService(
    this.session, {
    this.authenticatedUserUid = '',
    this.authenticatedUserEmail = '',
  }) : super();

  final AdminSession? session;
  String authenticatedUserUid;
  String authenticatedUserEmail;

  @override
  bool get hasAuthenticatedUser =>
      session != null || authenticatedUserUid.trim().isNotEmpty;

  @override
  String? get authenticatedUid =>
      session?.uid ??
      (authenticatedUserUid.trim().isEmpty
          ? null
          : authenticatedUserUid.trim());

  @override
  String get authenticatedEmail =>
      session?.email ?? authenticatedUserEmail.trim();

  @override
  Future<AdminSession?> currentSession() async => session;

  @override
  Future<AdminSession> signIn({
    required String email,
    required String password,
  }) async {
    if (session == null) {
      throw StateError('No fake admin session available.');
    }
    return session!;
  }

  @override
  Future<void> forceTokenRefresh() async {}

  @override
  Future<void> signOut() async {
    authenticatedUserUid = '';
    authenticatedUserEmail = '';
  }
}

class _FakeAdminDataService extends AdminDataService {
  _FakeAdminDataService(this.snapshot);

  final AdminPanelSnapshot snapshot;

  @override
  Future<AdminPanelSnapshot> fetchSnapshot({
    String adminEmail = '',
    String adminUid = '',
  }) async {
    return snapshot;
  }

  @override
  Future<AdminPanelSnapshot> fetchDashboardSnapshot({
    String adminEmail = '',
    String adminUid = '',
  }) async {
    return snapshot;
  }

  @override
  Future<AdminRidersPageResult> fetchRidersPageForAdmin({
    String? cursor,
    int limit = 50,
    AdminListQuery? query,
  }) async {
    return AdminRidersPageResult(
      riders: snapshot.riders,
      nextCursor: null,
      hasMore: false,
    );
  }

  @override
  Future<Map<String, dynamic>?> fetchDriverProfileForAdmin(
    String driverId,
  ) async {
    return null;
  }

  @override
  Future<Map<String, dynamic>?> fetchDriverEntityTabForAdmin({
    required String driverId,
    required String tabId,
  }) async {
    if (driverId.isEmpty) {
      return null;
    }
    switch (tabId) {
      case 'overview':
        return <String, dynamic>{
          'success': true,
          'driver_id': driverId,
          'driver': <String, dynamic>{'name': 'Test', 'city': 'Lagos'},
          'document_slot_count': 2,
        };
      case 'verification':
        return <String, dynamic>{
          'success': true,
          'driver_id': driverId,
          'verification': <String, dynamic>{'status': 'pending'},
          'documents_meta': <String, dynamic>{},
          'driver_verification': <String, dynamic>{},
        };
      case 'wallet':
        return <String, dynamic>{
          'success': true,
          'driver_id': driverId,
          'wallet': <String, dynamic>{'balance': 0, 'currency': 'NGN'},
        };
      case 'trips':
        return <String, dynamic>{
          'success': true,
          'driver_id': driverId,
          'trips': <Map<String, dynamic>>[],
        };
      case 'subscription':
        return <String, dynamic>{
          'success': true,
          'driver_id': driverId,
          'subscription': <String, dynamic>{
            'monetization_model': 'commission',
            'subscription_plan_type': 'monthly',
            'subscription_status': 'active',
            'subscription_active': true,
          },
        };
      case 'violations':
        return <String, dynamic>{
          'success': true,
          'driver_id': driverId,
          'violations': <dynamic>[],
        };
      case 'notes':
        return <String, dynamic>{
          'success': true,
          'driver_id': driverId,
          'notes': <String, dynamic>{},
        };
      case 'audit':
        return <String, dynamic>{
          'success': true,
          'driver_id': driverId,
          'verification_audits': <dynamic>[],
          'admin_audit_tail': <dynamic>[],
        };
      default:
        return <String, dynamic>{'success': false, 'reason': 'unknown_tab'};
    }
  }

  @override
  Future<AdminWithdrawalsPageResult> fetchWithdrawalsPageForAdmin({
    String? cursor,
    int limit = 50,
    AdminListQuery? query,
  }) async {
    return AdminWithdrawalsPageResult(
      withdrawals: snapshot.withdrawals,
      nextCursor: null,
      hasMore: false,
    );
  }

  @override
  Future<AdminSupportTicketsPageResult> fetchSupportTicketsPageForAdmin({
    String? cursor,
    int limit = 50,
    AdminListQuery? query,
  }) async {
    return const AdminSupportTicketsPageResult(
      tickets: <AdminSupportTicketListItem>[],
      nextCursor: null,
      hasMore: false,
    );
  }

  @override
  Future<Map<String, dynamic>?> fetchSupportTicketForAdmin(
    String ticketId,
  ) async {
    return <String, dynamic>{
      'success': true,
      'ticket': <String, dynamic>{
        'id': ticketId,
        'status': 'open',
        'subject': 'Test ticket',
      },
      'messages': <String, dynamic>{},
    };
  }

  @override
  Future<bool> adminUpdateSupportTicketStatusCallable({
    required String ticketId,
    required String status,
  }) async =>
      true;

  @override
  Future<bool> adminReplySupportTicketCallable({
    required String ticketId,
    required String message,
    String visibility = 'public',
  }) async =>
      true;

  @override
  Future<bool> adminEscalateSupportTicketCallable({
    required String ticketId,
  }) async =>
      true;

  @override
  Future<void> updateDriverStatus({
    required AdminDriverRecord driver,
    required String status,
  }) async {}

  @override
  Future<void> updatePricingConfig({
    required List<AdminCityPricing> cities,
    required double commissionRate,
    required int weeklySubscriptionNgn,
    required int monthlySubscriptionNgn,
  }) async {}

  @override
  Future<void> updateRiderStatus({
    required String riderId,
    required String status,
  }) async {}

  @override
  Future<void> updateSubscriptionStatus({
    required AdminSubscriptionRecord subscription,
    required String status,
  }) async {}

  @override
  Future<void> updateWithdrawal({
    required AdminWithdrawalRecord withdrawal,
    required String status,
    String payoutReference = '',
    String note = '',
  }) async {}

  @override
  Future<void> reviewVerificationCase({
    required AdminVerificationCase verificationCase,
    required String action,
    required String reviewedBy,
    String note = '',
  }) async {}

  @override
  Future<void> reviewSubscriptionRequest({
    required AdminSubscriptionRecord subscription,
    required bool approve,
  }) async {}

  @override
  Future<String> fetchSubscriptionProofUrl({required String driverId}) async =>
      'https://example.test/subscription-proof';

  @override
  Future<void> adminSuspendAccount({
    required String uid,
    required String role,
    required String reason,
  }) async {}

  @override
  Future<void> adminWarnAccount({
    required String uid,
    required String role,
    required String reason,
    String message = '',
  }) async {}

  @override
  Future<void> adminDeleteAccount({
    required String uid,
    required String role,
  }) async {}

  @override
  Future<void> adminFlagUserForSupportContact({
    required String uid,
    required String role,
    required String note,
    String priority = 'normal',
  }) async {}

  @override
  Future<void> adminApproveDriverVerification({
    required String driverId,
  }) async {}
}

final AdminPanelSnapshot _emptySnapshot = AdminPanelSnapshot(
  fetchedAt: DateTime(2026, 4, 12, 10, 30),
  metrics: const AdminDashboardMetrics(
    totalRiders: 0,
    incompleteRiderRegistrations: 0,
    pendingOnboarding: 0,
    totalMerchants: 0,
    totalDrivers: 0,
    activeDriversOnline: 0,
    ongoingTrips: 0,
    completedTrips: 0,
    cancelledTrips: 0,
    todaysRevenue: 0,
    totalPlatformRevenue: 0,
    totalDriverPayouts: 0,
    pendingWithdrawals: 0,
    subscriptionDriversCount: 0,
    commissionDriversCount: 0,
    totalGrossBookings: 0,
    totalCommissionsEarned: 0,
    subscriptionRevenue: 0,
  ),
  riders: <AdminRiderRecord>[],
  drivers: <AdminDriverRecord>[],
  trips: <AdminTripRecord>[],
  withdrawals: <AdminWithdrawalRecord>[],
  subscriptions: <AdminSubscriptionRecord>[],
  verificationCases: <AdminVerificationCase>[],
  supportIssues: <AdminSupportIssueRecord>[],
  pricingConfig: AdminPricingConfig(
    cities: <AdminCityPricing>[
      const AdminCityPricing(
        city: 'Lagos',
        baseFareNgn: 800,
        perKmNgn: 140,
        perMinuteNgn: 18,
        minimumFareNgn: 1300,
        enabled: true,
      ),
      const AdminCityPricing(
        city: 'Abuja',
        baseFareNgn: 600,
        perKmNgn: 115,
        perMinuteNgn: 12,
        minimumFareNgn: 1200,
        enabled: true,
      ),
    ],
    commissionRate: 0.10,
    weeklySubscriptionNgn: 7000,
    monthlySubscriptionNgn: 25000,
    loadedFromBackend: true,
    lastUpdated: DateTime(2026, 4, 12, 10, 30),
    rawData: <String, dynamic>{},
  ),
  settings: const AdminOperationalSettings(
    withdrawalNoticeText:
        'Withdrawals above ₦300,000 may take 2–3 working days. Withdrawals below ₦300,000 are typically processed within 48 hours. Withdrawals are processed by NexRide to the driver bank details on file.',
    cityEnablement: <String, bool>{
      'Lagos': true,
      'Abuja': true,
    },
    driverVerificationRequired: true,
    activeServiceTypes: <String>['ride'],
    offRouteToleranceMeters: 200,
    adminEmail: 'admin@nexride.africa',
    rawData: <String, dynamic>{},
  ),
  tripTrends: <AdminTrendPoint>[],
  revenueTrends: <AdminTrendPoint>[],
  cityPerformance: <AdminTrendPoint>[],
  driverGrowth: <AdminTrendPoint>[],
  adoptionBreakdown: <AdminTrendPoint>[],
  dailyFinance: <AdminRevenueSlice>[],
  weeklyFinance: <AdminRevenueSlice>[],
  monthlyFinance: <AdminRevenueSlice>[],
  cityFinance: <AdminRevenueSlice>[],
  liveDataSections: <String, bool>{
    'riders': true,
    'drivers': true,
    'trips': true,
    'finance': true,
    'pricing': true,
  },
);

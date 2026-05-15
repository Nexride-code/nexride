import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexride_driver/admin/admin_config.dart';
import 'package:nexride_driver/admin/admin_rbac.dart';
import 'package:nexride_driver/admin/models/admin_models.dart';
import 'package:nexride_driver/admin/screens/admin_gate_screen.dart';
import 'package:nexride_driver/admin/screens/admin_login_screen.dart';
import 'package:nexride_driver/admin/screens/admin_panel_screen.dart';
import 'package:nexride_driver/admin/services/admin_auth_service.dart';
import 'package:nexride_driver/admin/services/admin_data_service.dart';

void main() {
  late FakeAdminDataService dataService;
  final adminSession = AdminSession(
    uid: 'admin_uid_001',
    email: 'admin@nexride.africa',
    displayName: 'Ops Admin',
    accessMode: 'database_role',
    adminRole: 'super_admin',
    permissions: permissionsForAdminRole('super_admin'),
  );

  setUp(() {
    dataService = FakeAdminDataService(_sampleSnapshot);
  });

  testWidgets('/admin redirects non-admin users to /admin/login', (
    WidgetTester tester,
  ) async {
    _setDesktopViewport(tester);
    addTearDown(() => _resetViewport(tester));

    await tester.pumpWidget(
      _buildTestApp(
        authService: FakeAdminAuthService(null),
        dataService: dataService,
        initialRoute: AdminRoutePaths.admin,
      ),
    );

    await _pumpRouteTransition(tester);

    expect(find.text('Admin sign in'), findsOneWidget);
    expect(
      find.textContaining('Admin authentication is required'),
      findsOneWidget,
    );
  });

  testWidgets(
    '/admin/login shows form immediately; continue opens dashboard when admin',
    (WidgetTester tester) async {
    _setDesktopViewport(tester);
    addTearDown(() => _resetViewport(tester));

    await tester.pumpWidget(
      _buildTestApp(
        authService: FakeAdminAuthService(adminSession),
        dataService: dataService,
        initialRoute: AdminRoutePaths.adminLogin,
      ),
    );

    await _pumpRouteTransition(tester);

    expect(find.text('Admin sign in'), findsOneWidget);
    expect(find.text('Continue to dashboard'), findsOneWidget);
    await tester.tap(find.text('Continue to dashboard'));
    await _pumpRouteTransition(tester);

    expect(find.text('NexRide Control Center'), findsOneWidget);
    expect(find.text('Dashboard'), findsWidgets);
  });

  testWidgets('admin panel smoke test opens every section', (
    WidgetTester tester,
  ) async {
    _setDesktopViewport(tester);
    addTearDown(() => _resetViewport(tester));

    await tester.pumpWidget(
      MaterialApp(
        home: AdminPanelScreen(
          session: adminSession,
          dataService: dataService,
          authService: FakeAdminAuthService(adminSession),
          enableRealtimeBadgeListeners: false,
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('NexRide Control Center'), findsOneWidget);

    final sections = <String, String>{
      'Riders': 'Riders management',
      'Drivers': 'Drivers management',
      'Trips': 'Live operations unavailable',
      'Finance': 'Finance and revenue',
      'Withdrawals': 'Driver withdrawals',
      'Pricing': 'Pricing management',
      'Subscriptions': 'No pending subscription requests',
      'Verification': 'Verification center',
      'Support': 'Support tickets',
      'Settings': 'Settings and configuration',
    };

    for (final entry in sections.entries) {
      final navItem = find.widgetWithText(InkWell, entry.key).first;
      await tester.ensureVisible(navItem);
      await tester.tap(navItem);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text(entry.value), findsOneWidget);
    }

    // Support uses the callable-backed inbox inside the admin shell.
    expect(find.widgetWithText(InkWell, 'Support'), findsOneWidget);
  });

  testWidgets('riders section keeps cached data when paginated refresh fails', (
    WidgetTester tester,
  ) async {
    _setDesktopViewport(tester);
    addTearDown(() => _resetViewport(tester));

    await tester.pumpWidget(
      MaterialApp(
        home: AdminPanelScreen(
          session: adminSession,
          dataService: CachedFailureAdminDataService(_sampleSnapshot),
          authService: FakeAdminAuthService(adminSession),
          initialSection: AdminSection.riders,
          snapshotTimeout: const Duration(milliseconds: 20),
          enableRealtimeBadgeListeners: false,
        ),
      ),
    );

    await _pumpRouteTransition(tester);

    expect(find.text('Riders management'), findsOneWidget);
    expect(find.textContaining('Ada'), findsWidgets);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Refresh'));
    await _pumpRouteTransition(tester);

    expect(find.text('Unable to refresh riders'), findsOneWidget);
    expect(find.textContaining('timed out'), findsOneWidget);
  });

  testWidgets(
    'riders section shows paginated retry state when riders page fails',
    (WidgetTester tester) async {
    _setDesktopViewport(tester);
    addTearDown(() => _resetViewport(tester));

    await tester.pumpWidget(
      MaterialApp(
        home: AdminPanelScreen(
          session: adminSession,
          dataService: FailureAdminDataService(),
          authService: FakeAdminAuthService(adminSession),
          initialSection: AdminSection.riders,
          snapshotTimeout: const Duration(milliseconds: 20),
          enableRealtimeBadgeListeners: false,
        ),
      ),
    );

    await _pumpRouteTransition(tester);

    expect(find.text('Unable to load riders right now'), findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, 'Retry'), findsOneWidget);
  });

  testWidgets(
    'riders section shows empty state when paginated page returns no rows',
    (WidgetTester tester) async {
    _setDesktopViewport(tester);
    addTearDown(() => _resetViewport(tester));

    await tester.pumpWidget(
      MaterialApp(
        home: AdminPanelScreen(
          session: adminSession,
          dataService: EmptyRidersPaginatedFakeAdminDataService(),
          authService: FakeAdminAuthService(adminSession),
          initialSection: AdminSection.riders,
          snapshotTimeout: const Duration(milliseconds: 20),
          enableRealtimeBadgeListeners: false,
        ),
      ),
    );

    await _pumpRouteTransition(tester);

    expect(find.text('No rider records yet'), findsOneWidget);
  });

  testWidgets('compact admin shell menu opens drawer without crashing', (
    WidgetTester tester,
  ) async {
    _setCompactViewport(tester);
    addTearDown(() => _resetViewport(tester));

    await tester.pumpWidget(
      MaterialApp(
        home: AdminPanelScreen(
          session: adminSession,
          dataService: dataService,
          authService: FakeAdminAuthService(adminSession),
          enableRealtimeBadgeListeners: false,
        ),
      ),
    );

    await tester.pumpAndSettle();

    final Finder scaffoldFinder = find.byType(Scaffold);
    expect(scaffoldFinder, findsWidgets);
    final ScaffoldState scaffoldState =
        tester.state<ScaffoldState>(scaffoldFinder.first);
    expect(scaffoldState.isDrawerOpen, isFalse);

    await tester.tap(find.byIcon(Icons.menu_rounded).first);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(scaffoldState.isDrawerOpen, isTrue);
  });
}

Future<void> _pumpRouteTransition(WidgetTester tester) async {
  try {
    await tester.pumpAndSettle(const Duration(seconds: 2));
  } catch (_) {
    for (var index = 0; index < 12; index++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }
}

void _setDesktopViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1600, 1200);
  tester.view.devicePixelRatio = 1.0;
}

void _setCompactViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1200);
  tester.view.devicePixelRatio = 1.0;
}

void _resetViewport(WidgetTester tester) {
  tester.view.resetPhysicalSize();
  tester.view.resetDevicePixelRatio();
}

Widget _buildTestApp({
  required FakeAdminAuthService authService,
  required FakeAdminDataService dataService,
  required String initialRoute,
}) {
  return MaterialApp(
    initialRoute: initialRoute,
    onGenerateRoute: (RouteSettings settings) {
      switch (settings.name) {
        case AdminRoutePaths.admin:
          return MaterialPageRoute<void>(
            builder: (_) => AdminGateScreen(
              authService: authService,
              dataService: dataService,
              enableRealtimeBadgeListeners: false,
            ),
            settings: settings,
          );
        case AdminRoutePaths.adminLogin:
          return MaterialPageRoute<void>(
            builder: (_) => AdminLoginScreen(
              authService: authService,
              inlineMessage: settings.arguments as String?,
              dashboardRoute: AdminRoutePaths.admin,
            ),
            settings: settings,
          );
        default:
          return MaterialPageRoute<void>(
            builder: (_) => const SizedBox.shrink(),
          );
      }
    },
  );
}

class FakeAdminAuthService extends AdminAuthService {
  FakeAdminAuthService(this.session) : super();

  final AdminSession? session;

  @override
  bool get hasAuthenticatedUser => session != null;

  @override
  String? get authenticatedUid => session?.uid;

  @override
  String get authenticatedEmail => session?.email ?? '';

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
  Future<void> signOut() async {}
}

class FakeAdminDataService extends AdminDataService {
  FakeAdminDataService(this.snapshot);

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
        'ride_id': '',
        'createdByUserId': 'user_test',
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

class CachedFailureAdminDataService extends AdminDataService {
  CachedFailureAdminDataService(this.snapshot);

  final AdminPanelSnapshot snapshot;
  int _ridersPageInvocationCount = 0;

  @override
  AdminPanelSnapshot? get cachedSnapshot => snapshot;

  @override
  Future<AdminPanelSnapshot> fetchSnapshot({
    String adminEmail = '',
    String adminUid = '',
  }) async {
    throw TimeoutException('admin data request timed out');
  }

  /// First paginated load succeeds (hydrates UI); later loads fail like a broken refresh.
  @override
  Future<AdminRidersPageResult> fetchRidersPageForAdmin({
    String? cursor,
    int limit = 50,
    AdminListQuery? query,
  }) async {
    _ridersPageInvocationCount++;
    if (_ridersPageInvocationCount == 1) {
      return AdminRidersPageResult(
        riders: snapshot.riders,
        nextCursor: null,
        hasMore: false,
      );
    }
    throw TimeoutException('admin data request timed out');
  }
}

class FailureAdminDataService extends AdminDataService {
  @override
  AdminPanelSnapshot? get cachedSnapshot => null;

  @override
  Future<AdminPanelSnapshot> fetchSnapshot({
    String adminEmail = '',
    String adminUid = '',
  }) async {
    throw TimeoutException('admin data request timed out');
  }

  @override
  Future<AdminRidersPageResult> fetchRidersPageForAdmin({
    String? cursor,
    int limit = 50,
    AdminListQuery? query,
  }) async {
    throw TimeoutException('paginated riders load failed');
  }
}

/// Paginated riders returns an empty page (no dependency on full snapshot).
class EmptyRidersPaginatedFakeAdminDataService extends FakeAdminDataService {
  EmptyRidersPaginatedFakeAdminDataService() : super(_sampleSnapshot);

  @override
  Future<AdminRidersPageResult> fetchRidersPageForAdmin({
    String? cursor,
    int limit = 50,
    AdminListQuery? query,
  }) async {
    return const AdminRidersPageResult(
      riders: <AdminRiderRecord>[],
      nextCursor: null,
      hasMore: false,
    );
  }
}

final AdminPanelSnapshot _sampleSnapshot = AdminPanelSnapshot(
  fetchedAt: DateTime(2026, 4, 12, 10, 30),
  metrics: const AdminDashboardMetrics(
    totalRiders: 1240,
    incompleteRiderRegistrations: 0,
    pendingOnboarding: 0,
    totalMerchants: 42,
    totalDrivers: 286,
    activeDriversOnline: 41,
    ongoingTrips: 17,
    completedTrips: 9286,
    cancelledTrips: 514,
    todaysRevenue: 185400,
    totalPlatformRevenue: 9625400,
    totalDriverPayouts: 72421000,
    pendingWithdrawals: 845000,
    subscriptionDriversCount: 94,
    commissionDriversCount: 192,
    totalGrossBookings: 82046400,
    totalCommissionsEarned: 7105400,
    subscriptionRevenue: 2520000,
  ),
  riders: <AdminRiderRecord>[
    AdminRiderRecord(
      id: 'rider_001',
      name: 'Ada Rider',
      phone: '+234800000001',
      email: 'ada.rider@nexride.africa',
      city: 'Lagos',
      status: 'active',
      verificationStatus: 'verified',
      riskStatus: 'clear',
      paymentStatus: 'clear',
      profileCompleted: true,
      onboardingCompleted: null,
      createdAt: DateTime(2026, 3, 1),
      lastActiveAt: DateTime(2026, 4, 12, 9, 45),
      walletBalance: 12500,
      tripSummary: const AdminTripSummary(
        totalTrips: 42,
        completedTrips: 39,
        cancelledTrips: 3,
      ),
      rating: 4.8,
      ratingCount: 31,
      outstandingFeesNgn: 0,
      rawData: const <String, dynamic>{},
    ),
  ],
  drivers: <AdminDriverRecord>[
    AdminDriverRecord(
      id: 'driver_001',
      name: 'Samuel Driver',
      phone: '+234800000002',
      email: 'samuel.driver@nexride.africa',
      city: 'Abuja',
      stateOrRegion: 'abuja',
      status: 'active',
      accountStatus: 'active',
      isOnline: true,
      verificationStatus: 'approved',
      vehicleName: 'Toyota Camry',
      plateNumber: 'ABC-123NX',
      tripCount: 325,
      completedTripCount: 318,
      grossEarnings: 3520000,
      netEarnings: 3344000,
      walletBalance: 87500,
      totalWithdrawn: 1290000,
      pendingWithdrawals: 120000,
      monetizationModel: 'subscription',
      subscriptionPlanType: 'monthly',
      subscriptionStatus: 'active',
      subscriptionActive: true,
      createdAt: DateTime(2026, 1, 15),
      updatedAt: DateTime(2026, 4, 12, 8, 10),
      serviceTypes: const <String>['ride'],
      rawData: const <String, dynamic>{},
    ),
  ],
  trips: <AdminTripRecord>[
    AdminTripRecord(
      id: 'trip_001',
      source: 'rtdb',
      status: 'completed',
      city: 'Lagos',
      serviceType: 'ride',
      riderId: 'rider_001',
      riderName: 'Ada Rider',
      riderPhone: '+234800000001',
      driverId: 'driver_001',
      driverName: 'Samuel Driver',
      driverPhone: '+234800000002',
      pickupAddress: 'Lekki Phase 1, Lagos',
      destinationAddress: 'Victoria Island, Lagos',
      paymentMethod: 'Cash',
      fareAmount: 4200,
      distanceKm: 12.4,
      durationMinutes: 26,
      commissionAmount: 0,
      driverPayout: 4200,
      appliedMonetizationModel: 'subscription',
      settlementStatus: 'completed',
      cancellationReason: '',
      createdAt: DateTime(2026, 4, 12, 8, 0),
      acceptedAt: DateTime(2026, 4, 12, 8, 3),
      arrivedAt: DateTime(2026, 4, 12, 8, 10),
      startedAt: DateTime(2026, 4, 12, 8, 12),
      completedAt: DateTime(2026, 4, 12, 8, 38),
      cancelledAt: null,
      routeLog: const <String, dynamic>{
        'checkpoints': <String, dynamic>{'cp_1': true},
        'settlement': <String, dynamic>{'settlementStatus': 'trip_completed'},
      },
      rawData: const <String, dynamic>{},
    ),
  ],
  withdrawals: <AdminWithdrawalRecord>[
    AdminWithdrawalRecord(
      id: 'withdraw_001',
      entityType: 'driver',
      driverId: 'driver_001',
      merchantId: '',
      driverName: 'Samuel Driver',
      amount: 120000,
      status: 'pending',
      requestDate: DateTime(2026, 4, 11, 14, 20),
      processedDate: null,
      bankName: 'Example Bank (fixture)',
      accountName: 'Samuel Driver',
      accountNumber: '0000000001',
      hasPayoutDestination: true,
      payoutReference: '',
      notes: 'Awaiting finance review',
      sourcePaths: const <String>['withdraw_requests/withdraw_001'],
      rawData: const <String, dynamic>{},
    ),
  ],
  subscriptions: <AdminSubscriptionRecord>[
    AdminSubscriptionRecord(
      driverId: 'driver_001',
      driverName: 'Samuel Driver',
      city: 'Abuja',
      planType: 'monthly',
      status: 'active',
      paymentStatus: 'paid',
      startDate: DateTime(2026, 4, 1),
      endDate: DateTime(2026, 5, 1),
      isActive: true,
      pendingApproval: false,
      requestedAt: null,
      paymentReference: '',
      hasProof: false,
      amountNgn: 15000,
      rawData: const <String, dynamic>{},
    ),
  ],
  verificationCases: <AdminVerificationCase>[
    AdminVerificationCase(
      driverId: 'driver_001',
      driverName: 'Samuel Driver',
      phone: '+234800000002',
      email: 'samuel.driver@nexride.africa',
      businessModel: 'subscription',
      status: 'approved',
      overallStatus: 'approved',
      submittedAt: DateTime(2026, 3, 22),
      reviewedAt: DateTime(2026, 3, 24),
      reviewedBy: 'ops@nexride.africa',
      failureReason: '',
      documents: const <String, dynamic>{
        'drivers_license': <String, dynamic>{
          'label': 'Driver License',
          'status': 'approved',
          'fileUrl': '',
        },
      },
      rawData: const <String, dynamic>{},
    ),
  ],
  supportIssues: <AdminSupportIssueRecord>[
    AdminSupportIssueRecord(
      id: 'issue_001',
      kind: 'trip_dispute',
      status: 'pending',
      reason: 'Fare dispute',
      summary: 'Rider disputed the final fare after dropoff.',
      rideId: 'trip_001',
      riderId: 'rider_001',
      driverId: 'driver_001',
      city: 'Lagos',
      createdAt: DateTime(2026, 4, 12, 9, 0),
      updatedAt: DateTime(2026, 4, 12, 9, 5),
      rawData: const <String, dynamic>{},
    ),
  ],
  pricingConfig: const AdminPricingConfig(
    cities: <AdminCityPricing>[
      AdminCityPricing(
        city: 'Lagos',
        baseFareNgn: 800,
        perKmNgn: 140,
        perMinuteNgn: 18,
        minimumFareNgn: 1300,
        enabled: true,
      ),
      AdminCityPricing(
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
    lastUpdated: null,
    rawData: <String, dynamic>{},
  ),
  settings: const AdminOperationalSettings(
    withdrawalNoticeText:
        'Withdrawals above ₦300,000 may take 2–3 working days. Withdrawals below ₦300,000 are typically processed within 48 hours. Withdrawals are processed by NexRide to the driver bank details on file.',
    cityEnablement: <String, bool>{
      'lagos': true,
      'abuja': true,
    },
    driverVerificationRequired: false,
    activeServiceTypes: <String>['ride'],
    offRouteToleranceMeters: 250,
    adminEmail: 'admin@nexride.africa',
    rawData: <String, dynamic>{},
  ),
  tripTrends: const <AdminTrendPoint>[
    AdminTrendPoint(
        label: 'Mon', value: 122, secondaryValue: 108, tertiaryValue: 7),
    AdminTrendPoint(
        label: 'Tue', value: 138, secondaryValue: 118, tertiaryValue: 9),
    AdminTrendPoint(
        label: 'Wed', value: 149, secondaryValue: 132, tertiaryValue: 8),
  ],
  revenueTrends: const <AdminTrendPoint>[
    AdminTrendPoint(
        label: 'Mon',
        value: 182000,
        secondaryValue: 28000,
        tertiaryValue: 154000),
    AdminTrendPoint(
        label: 'Tue',
        value: 196000,
        secondaryValue: 30500,
        tertiaryValue: 165500),
    AdminTrendPoint(
        label: 'Wed',
        value: 215000,
        secondaryValue: 34000,
        tertiaryValue: 181000),
  ],
  cityPerformance: const <AdminTrendPoint>[
    AdminTrendPoint(label: 'Lagos', value: 4200000, secondaryValue: 680),
    AdminTrendPoint(label: 'Abuja', value: 2800000, secondaryValue: 430),
  ],
  driverGrowth: const <AdminTrendPoint>[
    AdminTrendPoint(label: '3/4', value: 18),
    AdminTrendPoint(label: '3/11', value: 25),
    AdminTrendPoint(label: '3/18', value: 22),
  ],
  adoptionBreakdown: const <AdminTrendPoint>[
    AdminTrendPoint(label: 'Subscription', value: 94),
    AdminTrendPoint(label: 'Commission', value: 192),
  ],
  dailyFinance: const <AdminRevenueSlice>[
    AdminRevenueSlice(
      label: '4/10',
      grossBookings: 260000,
      commissionRevenue: 32000,
      subscriptionRevenue: 25000,
      driverPayouts: 203000,
      pendingPayouts: 120000,
    ),
  ],
  weeklyFinance: const <AdminRevenueSlice>[
    AdminRevenueSlice(
      label: 'Wk 4/7',
      grossBookings: 1520000,
      commissionRevenue: 184000,
      subscriptionRevenue: 175000,
      driverPayouts: 1161000,
      pendingPayouts: 340000,
    ),
  ],
  monthlyFinance: const <AdminRevenueSlice>[
    AdminRevenueSlice(
      label: 'Apr 2026',
      grossBookings: 6200000,
      commissionRevenue: 724000,
      subscriptionRevenue: 525000,
      driverPayouts: 4951000,
      pendingPayouts: 845000,
    ),
  ],
  cityFinance: const <AdminRevenueSlice>[
    AdminRevenueSlice(
      label: 'Lagos',
      grossBookings: 4200000,
      commissionRevenue: 504000,
      subscriptionRevenue: 275000,
      driverPayouts: 3421000,
      pendingPayouts: 520000,
    ),
    AdminRevenueSlice(
      label: 'Abuja',
      grossBookings: 2800000,
      commissionRevenue: 220000,
      subscriptionRevenue: 250000,
      driverPayouts: 2150000,
      pendingPayouts: 325000,
    ),
  ],
  liveDataSections: const <String, bool>{
    'riders': true,
    'drivers': true,
    'trips': true,
    'wallets': true,
    'withdrawals': true,
    'verification': true,
    'support': true,
    'pricing': true,
  },
);

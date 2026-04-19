import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexride_driver/admin/admin_config.dart';
import 'package:nexride_driver/admin/models/admin_models.dart';
import 'package:nexride_driver/admin/screens/admin_gate_screen.dart';
import 'package:nexride_driver/admin/screens/admin_panel_screen.dart';
import 'package:nexride_driver/admin/services/admin_auth_service.dart';
import 'package:nexride_driver/admin/services/admin_data_service.dart';

void main() {
  late FakeAdminDataService dataService;
  const adminSession = AdminSession(
    uid: 'admin_uid_001',
    email: 'admin@nexride.com',
    displayName: 'Ops Admin',
    accessMode: 'database_role',
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

  testWidgets('/admin/login redirects signed-in admins to /admin', (
    WidgetTester tester,
  ) async {
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
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('NexRide Control Center'), findsOneWidget);

    final sections = <String, String>{
      'Riders': 'Riders management',
      'Drivers': 'Drivers management',
      'Trips': 'Trips management',
      'Finance': 'Finance and revenue',
      'Withdrawals': 'Driver withdrawals',
      'Pricing': 'Pricing management',
      'Subscriptions': 'Subscriptions management',
      'Verification': 'Verification and compliance',
      'Support': 'Support and issue visibility',
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
  });

  testWidgets('riders section keeps cached data when refresh fails', (
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
        ),
      ),
    );

    await _pumpRouteTransition(tester);

    expect(find.text('Riders management'), findsOneWidget);
    expect(find.text('Unable to refresh riders'), findsOneWidget);
    expect(find.textContaining('timed out'), findsOneWidget);
  });

  testWidgets('riders section shows retry state when no snapshot loads', (
    WidgetTester tester,
  ) async {
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
        ),
      ),
    );

    await _pumpRouteTransition(tester);

    expect(find.text('Unable to load riders right now'), findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, 'Retry'), findsOneWidget);
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
        ),
      ),
    );

    await tester.pumpAndSettle();

    final scaffoldState = tester.state<ScaffoldState>(find.byType(Scaffold));
    expect(scaffoldState.isDrawerOpen, isFalse);

    await tester.tap(find.byIcon(Icons.menu_rounded));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(scaffoldState.isDrawerOpen, isTrue);
  });
}

Future<void> _pumpRouteTransition(WidgetTester tester) async {
  for (var index = 0; index < 8; index++) {
    await tester.pump(const Duration(milliseconds: 100));
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
              mode: AdminGateMode.dashboard,
              authService: authService,
              dataService: dataService,
            ),
            settings: settings,
          );
        case AdminRoutePaths.adminLogin:
          return MaterialPageRoute<void>(
            builder: (_) => AdminGateScreen(
              mode: AdminGateMode.login,
              authService: authService,
              dataService: dataService,
              inlineMessage: settings.arguments as String?,
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
  FakeAdminAuthService(this.session);

  final AdminSession? session;

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
}

class CachedFailureAdminDataService extends AdminDataService {
  CachedFailureAdminDataService(this.snapshot);

  final AdminPanelSnapshot snapshot;

  @override
  AdminPanelSnapshot? get cachedSnapshot => snapshot;

  @override
  Future<AdminPanelSnapshot> fetchSnapshot({
    String adminEmail = '',
    String adminUid = '',
  }) async {
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
}

final AdminPanelSnapshot _sampleSnapshot = AdminPanelSnapshot(
  fetchedAt: DateTime(2026, 4, 12, 10, 30),
  metrics: const AdminDashboardMetrics(
    totalRiders: 1240,
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
      email: 'ada.rider@nexride.com',
      city: 'Lagos',
      status: 'active',
      verificationStatus: 'verified',
      riskStatus: 'clear',
      paymentStatus: 'clear',
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
      email: 'samuel.driver@nexride.com',
      city: 'Abuja',
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
      serviceTypes: const <String>['ride', 'dispatch_delivery'],
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
      driverId: 'driver_001',
      driverName: 'Samuel Driver',
      amount: 120000,
      status: 'pending',
      requestDate: DateTime(2026, 4, 11, 14, 20),
      processedDate: null,
      bankName: 'GTBank',
      accountName: 'Samuel Driver',
      accountNumber: '0123456789',
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
      rawData: const <String, dynamic>{},
    ),
  ],
  verificationCases: <AdminVerificationCase>[
    AdminVerificationCase(
      driverId: 'driver_001',
      driverName: 'Samuel Driver',
      phone: '+234800000002',
      email: 'samuel.driver@nexride.com',
      businessModel: 'subscription',
      status: 'approved',
      overallStatus: 'approved',
      submittedAt: DateTime(2026, 3, 22),
      reviewedAt: DateTime(2026, 3, 24),
      reviewedBy: 'ops@nexride.com',
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
        'Withdrawals above ₦300,000 may take 2–3 working days. Withdrawals below ₦300,000 are typically processed within 48 hours. Withdrawals are processed directly by NEXRIDE DYNAMIC JOURNEY LTD.',
    cityEnablement: <String, bool>{
      'lagos': true,
      'abuja': true,
    },
    driverVerificationRequired: false,
    activeServiceTypes: <String>['ride', 'dispatch_delivery'],
    offRouteToleranceMeters: 250,
    adminEmail: 'admin@nexride.com',
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

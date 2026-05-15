import 'package:flutter/foundation.dart';

class AdminMetricCardData {
  const AdminMetricCardData({
    required this.label,
    required this.value,
    required this.caption,
  });

  final String label;
  final String value;
  final String caption;
}

class AdminTrendPoint {
  const AdminTrendPoint({
    required this.label,
    required this.value,
    this.secondaryValue = 0,
    this.tertiaryValue = 0,
  });

  final String label;
  final double value;
  final double secondaryValue;
  final double tertiaryValue;
}

class AdminRevenueSlice {
  const AdminRevenueSlice({
    required this.label,
    required this.grossBookings,
    required this.commissionRevenue,
    required this.subscriptionRevenue,
    required this.driverPayouts,
    required this.pendingPayouts,
  });

  final String label;
  final double grossBookings;
  final double commissionRevenue;
  final double subscriptionRevenue;
  final double driverPayouts;
  final double pendingPayouts;
}

class AdminDashboardMetrics {
  const AdminDashboardMetrics({
    required this.totalRiders,
    required this.incompleteRiderRegistrations,
    required this.pendingOnboarding,
    required this.totalMerchants,
    required this.totalDrivers,
    required this.activeDriversOnline,
    required this.ongoingTrips,
    required this.completedTrips,
    required this.cancelledTrips,
    required this.todaysRevenue,
    required this.totalPlatformRevenue,
    required this.totalDriverPayouts,
    required this.pendingWithdrawals,
    required this.subscriptionDriversCount,
    required this.commissionDriversCount,
    required this.totalGrossBookings,
    required this.totalCommissionsEarned,
    required this.subscriptionRevenue,
  });

  final int totalRiders;
  /// Classified rider-eligible accounts missing minimum profile fields (directory scan / samples).
  final int incompleteRiderRegistrations;
  /// Accounts with a completed profile but onboarding still marked incomplete when known.
  final int pendingOnboarding;
  final int totalMerchants;
  final int totalDrivers;
  final int activeDriversOnline;
  final int ongoingTrips;
  final int completedTrips;
  final int cancelledTrips;
  final double todaysRevenue;
  final double totalPlatformRevenue;
  final double totalDriverPayouts;
  final double pendingWithdrawals;
  final int subscriptionDriversCount;
  final int commissionDriversCount;
  final double totalGrossBookings;
  final double totalCommissionsEarned;
  final double subscriptionRevenue;
}

class AdminTripSummary {
  const AdminTripSummary({
    required this.totalTrips,
    required this.completedTrips,
    required this.cancelledTrips,
  });

  final int totalTrips;
  final int completedTrips;
  final int cancelledTrips;
}

class AdminRiderRecord {
  const AdminRiderRecord({
    required this.id,
    required this.name,
    required this.phone,
    required this.email,
    required this.city,
    required this.status,
    required this.verificationStatus,
    required this.riskStatus,
    required this.paymentStatus,
    required this.profileCompleted,
    this.onboardingCompleted,
    required this.createdAt,
    required this.lastActiveAt,
    required this.walletBalance,
    required this.tripSummary,
    required this.rating,
    required this.ratingCount,
    required this.outstandingFeesNgn,
    required this.rawData,
  });

  final String id;
  final String name;
  final String phone;
  final String email;
  final String city;
  final String status;
  final String verificationStatus;
  final String riskStatus;
  final String paymentStatus;
  final bool profileCompleted;
  final bool? onboardingCompleted;
  final DateTime? createdAt;
  final DateTime? lastActiveAt;
  final double walletBalance;
  final AdminTripSummary tripSummary;
  final double rating;
  final int ratingCount;
  final int outstandingFeesNgn;
  final Map<String, dynamic> rawData;
}

class AdminDriverRecord {
  const AdminDriverRecord({
    required this.id,
    required this.name,
    required this.phone,
    required this.email,
    required this.city,
    required this.stateOrRegion,
    required this.accountStatus,
    required this.status,
    required this.isOnline,
    required this.verificationStatus,
    required this.vehicleName,
    required this.plateNumber,
    required this.tripCount,
    required this.completedTripCount,
    required this.grossEarnings,
    required this.netEarnings,
    required this.walletBalance,
    required this.totalWithdrawn,
    required this.pendingWithdrawals,
    required this.monetizationModel,
    required this.subscriptionPlanType,
    required this.subscriptionStatus,
    required this.subscriptionActive,
    required this.createdAt,
    required this.updatedAt,
    required this.serviceTypes,
    required this.rawData,
  });

  final String id;
  final String name;
  final String phone;
  final String email;
  final String city;
  final String stateOrRegion;
  final String accountStatus;
  final String status;
  final bool isOnline;
  final String verificationStatus;
  final String vehicleName;
  final String plateNumber;
  final int tripCount;
  final int completedTripCount;
  final double grossEarnings;
  final double netEarnings;
  final double walletBalance;
  final double totalWithdrawn;
  final double pendingWithdrawals;
  final String monetizationModel;
  final String subscriptionPlanType;
  final String subscriptionStatus;
  final bool subscriptionActive;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final List<String> serviceTypes;
  final Map<String, dynamic> rawData;

  AdminDriverRecord copyWith({
    String? accountStatus,
    String? verificationStatus,
    Map<String, dynamic>? rawData,
  }) {
    return AdminDriverRecord(
      id: id,
      name: name,
      phone: phone,
      email: email,
      city: city,
      stateOrRegion: stateOrRegion,
      accountStatus: accountStatus ?? this.accountStatus,
      status: status,
      isOnline: isOnline,
      verificationStatus: verificationStatus ?? this.verificationStatus,
      vehicleName: vehicleName,
      plateNumber: plateNumber,
      tripCount: tripCount,
      completedTripCount: completedTripCount,
      grossEarnings: grossEarnings,
      netEarnings: netEarnings,
      walletBalance: walletBalance,
      totalWithdrawn: totalWithdrawn,
      pendingWithdrawals: pendingWithdrawals,
      monetizationModel: monetizationModel,
      subscriptionPlanType: subscriptionPlanType,
      subscriptionStatus: subscriptionStatus,
      subscriptionActive: subscriptionActive,
      createdAt: createdAt,
      updatedAt: updatedAt,
      serviceTypes: serviceTypes,
      rawData: rawData ?? this.rawData,
    );
  }
}

/// One page of drivers from [adminListDriversPage] (or a legacy single-shot fetch).
class AdminDriversPageResult {
  const AdminDriversPageResult({
    required this.drivers,
    required this.nextCursor,
    required this.hasMore,
  });

  final List<AdminDriverRecord> drivers;
  final String? nextCursor;
  final bool hasMore;
}

/// Optional filters for paginated admin list HTTPS callables (drivers, riders, …).
@immutable
class AdminListQuery {
  const AdminListQuery({
    this.search = '',
    this.city = '',
    this.stateOrRegion = '',
    this.status = '',
    this.verificationStatus = '',
    this.createdFromMs = 0,
    this.createdToMs = 0,
    this.monetizationModel = '',
    this.profileCompleteness = '',
  });

  final String search;
  final String city;
  final String stateOrRegion;
  final String status;
  final String verificationStatus;
  final int createdFromMs;
  final int createdToMs;
  final String monetizationModel;
  /// Callable `profileCompleteness`: `completed` | `incomplete` | `all` (empty = server default).
  final String profileCompleteness;

  Map<String, dynamic> toCallablePayload() {
    final Map<String, dynamic> payload = <String, dynamic>{};

    if (search.trim().isNotEmpty) {
      payload['search'] = search.trim();
    }
    if (city.trim().isNotEmpty && city.trim().toLowerCase() != 'all') {
      payload['city'] = city.trim();
    }
    if (stateOrRegion.trim().isNotEmpty &&
        stateOrRegion.trim().toLowerCase() != 'all') {
      payload['stateOrRegion'] = stateOrRegion.trim();
    }
    if (status.trim().isNotEmpty && status.trim().toLowerCase() != 'all') {
      payload['status'] = status.trim();
    }
    if (verificationStatus.trim().isNotEmpty &&
        verificationStatus.trim().toLowerCase() != 'all') {
      payload['verificationStatus'] = verificationStatus.trim();
    }
    if (monetizationModel.trim().isNotEmpty &&
        monetizationModel.trim().toLowerCase() != 'all') {
      payload['monetizationModel'] = monetizationModel.trim();
    }
    if (createdFromMs > 0) {
      payload['createdFrom'] = createdFromMs;
    }
    if (createdToMs > 0) {
      payload['createdTo'] = createdToMs;
    }
    final String pc = profileCompleteness.trim().toLowerCase();
    if (pc.isNotEmpty) {
      payload['profileCompleteness'] = pc;
    }

    return payload;
  }
}

class AdminRidersPageResult {
  const AdminRidersPageResult({
    required this.riders,
    required this.nextCursor,
    required this.hasMore,
  });

  final List<AdminRiderRecord> riders;
  final String? nextCursor;
  final bool hasMore;
}

class AdminTripRecord {
  const AdminTripRecord({
    required this.id,
    required this.source,
    required this.status,
    required this.city,
    required this.serviceType,
    required this.riderId,
    required this.riderName,
    required this.riderPhone,
    required this.driverId,
    required this.driverName,
    required this.driverPhone,
    required this.pickupAddress,
    required this.destinationAddress,
    required this.paymentMethod,
    required this.fareAmount,
    required this.distanceKm,
    required this.durationMinutes,
    required this.commissionAmount,
    required this.driverPayout,
    required this.appliedMonetizationModel,
    required this.settlementStatus,
    required this.cancellationReason,
    required this.createdAt,
    required this.acceptedAt,
    required this.arrivedAt,
    required this.startedAt,
    required this.completedAt,
    required this.cancelledAt,
    required this.routeLog,
    required this.rawData,
  });

  final String id;
  final String source;
  final String status;
  final String city;
  final String serviceType;
  final String riderId;
  final String riderName;
  final String riderPhone;
  final String driverId;
  final String driverName;
  final String driverPhone;
  final String pickupAddress;
  final String destinationAddress;
  final String paymentMethod;
  final double fareAmount;
  final double distanceKm;
  final double durationMinutes;
  final double commissionAmount;
  final double driverPayout;
  final String appliedMonetizationModel;
  final String settlementStatus;
  final String cancellationReason;
  final DateTime? createdAt;
  final DateTime? acceptedAt;
  final DateTime? arrivedAt;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final DateTime? cancelledAt;
  final Map<String, dynamic> routeLog;
  final Map<String, dynamic> rawData;

  /// Built from [adminListTripsPage] slim row (no route logs / polylines).
  factory AdminTripRecord.fromAdminTripsPageRow(
    String id,
    Map<String, dynamic> m,
  ) {
    DateTime? fromMs(dynamic v) {
      if (v is! num || v <= 0) return null;
      return DateTime.fromMillisecondsSinceEpoch(v.toInt());
    }

    String s(dynamic v) => v == null ? '' : v.toString().trim();

    return AdminTripRecord(
      id: id,
      source: 'ride_request',
      status: () {
        final st = s(m['status']);
        return st.isNotEmpty ? st : s(m['trip_state']);
      }(),
      city: s(m['city']),
      serviceType: s(m['service_type']),
      riderId: s(m['rider_id']),
      riderName: s(m['rider_name']),
      riderPhone: '',
      driverId: s(m['driver_id']),
      driverName: s(m['driver_name']),
      driverPhone: '',
      pickupAddress: s(m['pickup_hint']),
      destinationAddress: s(m['dropoff_hint']),
      paymentMethod: '',
      fareAmount: (m['fare'] as num?)?.toDouble() ?? 0,
      distanceKm: 0,
      durationMinutes: 0,
      commissionAmount: 0,
      driverPayout: 0,
      appliedMonetizationModel: '',
      settlementStatus: '',
      cancellationReason: '',
      createdAt: fromMs(m['created_at']),
      acceptedAt: null,
      arrivedAt: null,
      startedAt: null,
      completedAt: null,
      cancelledAt: null,
      routeLog: const <String, dynamic>{},
      rawData: Map<String, dynamic>.from(m),
    );
  }
}

class AdminWithdrawalRecord {
  const AdminWithdrawalRecord({
    required this.id,
    required this.entityType,
    required this.driverId,
    required this.merchantId,
    required this.driverName,
    required this.amount,
    required this.status,
    required this.requestDate,
    required this.processedDate,
    required this.bankName,
    required this.accountName,
    required this.accountNumber,
    required this.hasPayoutDestination,
    required this.payoutReference,
    required this.notes,
    required this.sourcePaths,
    required this.rawData,
  });

  final String id;
  /// `driver` or `merchant` (withdraw_requests.entity_type).
  final String entityType;
  final String driverId;
  final String merchantId;
  final String driverName;
  final double amount;
  final String status;
  final DateTime? requestDate;
  final DateTime? processedDate;
  final String bankName;
  final String accountName;
  final String accountNumber;
  /// False when payout bank fields are missing on the withdrawal row (driver).
  final bool hasPayoutDestination;
  final String payoutReference;
  final String notes;
  final List<String> sourcePaths;
  final Map<String, dynamic> rawData;

  factory AdminWithdrawalRecord.fromAdminListPageEntry(
    String id,
    Map<String, dynamic> raw,
  ) {
    DateTime? fromMs(dynamic v) {
      if (v is! num || v <= 0) return null;
      return DateTime.fromMillisecondsSinceEpoch(v.toInt());
    }

    final String entity =
        (raw['entity_type']?.toString() ?? raw['entityType']?.toString() ?? 'driver')
            .trim()
            .toLowerCase();
    final String bank = (raw['bank_name']?.toString() ?? '').trim();
    final String acct = (raw['account_number']?.toString() ?? '').trim();
    final String holder = (raw['account_holder_name']?.toString() ?? '').trim();
    final bool hasDest = raw['has_destination'] == true ||
        (bank.isNotEmpty && acct.isNotEmpty && holder.isNotEmpty);

    return AdminWithdrawalRecord(
      id: id,
      entityType: entity.isEmpty ? 'driver' : entity,
      driverId: raw['driver_id']?.toString() ?? '',
      merchantId: raw['merchant_id']?.toString() ?? '',
      driverName: raw['driver_name']?.toString() ?? '',
      amount: (raw['amount'] as num?)?.toDouble() ?? 0,
      status: (raw['status']?.toString() ?? 'pending').toLowerCase(),
      requestDate: fromMs(raw['requestedAt'] ?? raw['requested_at']),
      processedDate: fromMs(raw['updated_at'] ?? raw['updatedAt']),
      bankName: bank,
      accountName: holder,
      accountNumber: acct,
      hasPayoutDestination: entity == 'merchant' ? true : hasDest,
      payoutReference: '',
      notes: '',
      sourcePaths: const <String>[],
      rawData: Map<String, dynamic>.from(raw),
    );
  }
}

class AdminWithdrawalsPageResult {
  const AdminWithdrawalsPageResult({
    required this.withdrawals,
    required this.nextCursor,
    required this.hasMore,
  });

  final List<AdminWithdrawalRecord> withdrawals;
  final String? nextCursor;
  final bool hasMore;
}

/// Slim row from [adminListSupportTicketsPage].
class AdminSupportTicketListItem {
  const AdminSupportTicketListItem({
    required this.id,
    required this.status,
    required this.subject,
    required this.rideId,
    required this.createdByUserId,
    required this.updatedAtMs,
    required this.createdAtMs,
    required this.raw,
  });

  final String id;
  final String status;
  final String subject;
  final String rideId;
  final String createdByUserId;
  final int updatedAtMs;
  final int createdAtMs;
  final Map<String, dynamic> raw;
}

class AdminSupportTicketsPageResult {
  const AdminSupportTicketsPageResult({
    required this.tickets,
    required this.nextCursor,
    required this.hasMore,
  });

  final List<AdminSupportTicketListItem> tickets;
  final String? nextCursor;
  final bool hasMore;
}

class AdminTripsPageResult {
  const AdminTripsPageResult({
    required this.trips,
    required this.nextCursor,
    required this.hasMore,
  });

  final List<AdminTripRecord> trips;
  final String? nextCursor;
  final bool hasMore;
}

class AdminSubscriptionRecord {
  const AdminSubscriptionRecord({
    required this.driverId,
    required this.driverName,
    required this.city,
    required this.planType,
    required this.status,
    required this.paymentStatus,
    required this.startDate,
    required this.endDate,
    required this.isActive,
    required this.pendingApproval,
    required this.requestedAt,
    required this.paymentReference,
    required this.hasProof,
    required this.amountNgn,
    required this.rawData,
  });

  final String driverId;
  final String driverName;
  final String city;
  final String planType;
  final String status;
  final String paymentStatus;
  final DateTime? startDate;
  final DateTime? endDate;
  final bool isActive;
  final bool pendingApproval;
  final DateTime? requestedAt;
  final String paymentReference;
  /// True when a subscription proof URL exists in RTDB; URL is fetched on demand via callable only.
  final bool hasProof;
  final int amountNgn;
  final Map<String, dynamic> rawData;
}

class AdminVerificationCase {
  const AdminVerificationCase({
    required this.driverId,
    required this.driverName,
    required this.phone,
    required this.email,
    required this.businessModel,
    required this.status,
    required this.overallStatus,
    required this.submittedAt,
    required this.reviewedAt,
    required this.reviewedBy,
    required this.failureReason,
    required this.documents,
    required this.rawData,
  });

  final String driverId;
  final String driverName;
  final String phone;
  final String email;
  final String businessModel;
  final String status;
  final String overallStatus;
  final DateTime? submittedAt;
  final DateTime? reviewedAt;
  final String reviewedBy;
  final String failureReason;
  final Map<String, dynamic> documents;
  final Map<String, dynamic> rawData;
}

class AdminSupportIssueRecord {
  const AdminSupportIssueRecord({
    required this.id,
    required this.kind,
    required this.status,
    required this.reason,
    required this.summary,
    required this.rideId,
    required this.riderId,
    required this.driverId,
    required this.city,
    required this.createdAt,
    required this.updatedAt,
    required this.rawData,
  });

  final String id;
  final String kind;
  final String status;
  final String reason;
  final String summary;
  final String rideId;
  final String riderId;
  final String driverId;
  final String city;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final Map<String, dynamic> rawData;
}

class AdminCityPricing {
  const AdminCityPricing({
    required this.city,
    required this.baseFareNgn,
    required this.perKmNgn,
    required this.perMinuteNgn,
    required this.minimumFareNgn,
    required this.enabled,
  });

  final String city;
  final int baseFareNgn;
  final int perKmNgn;
  final int perMinuteNgn;
  final int minimumFareNgn;
  final bool enabled;
}

class AdminPricingConfig {
  const AdminPricingConfig({
    required this.cities,
    required this.commissionRate,
    required this.weeklySubscriptionNgn,
    required this.monthlySubscriptionNgn,
    required this.loadedFromBackend,
    required this.lastUpdated,
    required this.rawData,
  });

  final List<AdminCityPricing> cities;
  final double commissionRate;
  final int weeklySubscriptionNgn;
  final int monthlySubscriptionNgn;
  final bool loadedFromBackend;
  final DateTime? lastUpdated;
  final Map<String, dynamic> rawData;
}

class AdminOperationalSettings {
  const AdminOperationalSettings({
    required this.withdrawalNoticeText,
    required this.cityEnablement,
    required this.driverVerificationRequired,
    required this.activeServiceTypes,
    required this.offRouteToleranceMeters,
    required this.adminEmail,
    required this.rawData,
  });

  final String withdrawalNoticeText;
  final Map<String, bool> cityEnablement;
  final bool driverVerificationRequired;
  final List<String> activeServiceTypes;
  final int offRouteToleranceMeters;
  final String adminEmail;
  final Map<String, dynamic> rawData;
}

/// **Legacy monolith** — aggregates dashboard lists, pricing, subscriptions, and
/// settings in one object for compatibility while admin sections migrate off
/// [AdminDataService.fetchSnapshot].
///
/// **Do not add new fields or new snapshot consumers.** Prefer narrow DTOs per
/// section (see `lib/admin/docs/SNAPSHOT_MIGRATION.md` and Phase 2B split plan).
class AdminPanelSnapshot {
  const AdminPanelSnapshot({
    required this.fetchedAt,
    required this.metrics,
    required this.riders,
    required this.drivers,
    required this.trips,
    required this.withdrawals,
    required this.subscriptions,
    required this.verificationCases,
    required this.supportIssues,
    required this.pricingConfig,
    required this.settings,
    required this.tripTrends,
    required this.revenueTrends,
    required this.cityPerformance,
    required this.driverGrowth,
    required this.adoptionBreakdown,
    required this.dailyFinance,
    required this.weeklyFinance,
    required this.monthlyFinance,
    required this.cityFinance,
    required this.liveDataSections,
  });

  final DateTime fetchedAt;
  final AdminDashboardMetrics metrics;
  final List<AdminRiderRecord> riders;
  final List<AdminDriverRecord> drivers;
  final List<AdminTripRecord> trips;
  final List<AdminWithdrawalRecord> withdrawals;
  final List<AdminSubscriptionRecord> subscriptions;
  final List<AdminVerificationCase> verificationCases;
  final List<AdminSupportIssueRecord> supportIssues;
  final AdminPricingConfig pricingConfig;
  final AdminOperationalSettings settings;
  final List<AdminTrendPoint> tripTrends;
  final List<AdminTrendPoint> revenueTrends;
  final List<AdminTrendPoint> cityPerformance;
  final List<AdminTrendPoint> driverGrowth;
  final List<AdminTrendPoint> adoptionBreakdown;
  final List<AdminRevenueSlice> dailyFinance;
  final List<AdminRevenueSlice> weeklyFinance;
  final List<AdminRevenueSlice> monthlyFinance;
  final List<AdminRevenueSlice> cityFinance;
  final Map<String, bool> liveDataSections;

  AdminPanelSnapshot copyWith({
    List<AdminDriverRecord>? drivers,
    List<AdminRiderRecord>? riders,
  }) {
    return AdminPanelSnapshot(
      fetchedAt: fetchedAt,
      metrics: metrics,
      riders: riders ?? this.riders,
      drivers: drivers ?? this.drivers,
      trips: trips,
      withdrawals: withdrawals,
      subscriptions: subscriptions,
      verificationCases: verificationCases,
      supportIssues: supportIssues,
      pricingConfig: pricingConfig,
      settings: settings,
      tripTrends: tripTrends,
      revenueTrends: revenueTrends,
      cityPerformance: cityPerformance,
      driverGrowth: driverGrowth,
      adoptionBreakdown: adoptionBreakdown,
      dailyFinance: dailyFinance,
      weeklyFinance: weeklyFinance,
      monthlyFinance: monthlyFinance,
      cityFinance: cityFinance,
      liveDataSections: liveDataSections,
    );
  }
}

@immutable
class AdminSession {
  const AdminSession({
    required this.uid,
    required this.email,
    required this.displayName,
    required this.accessMode,
    this.mustChangePassword = false,
    this.adminRole = 'super_admin',
    this.permissions = const <String>{},
  });

  final String uid;
  final String email;
  final String displayName;
  final String accessMode;

  /// True when the user's account is flagged with `temporaryPassword=true`
  /// (custom claim or RTDB `/account_security/{uid}`). Gated routes use
  /// this to force-redirect the operator to the change-password screen.
  final bool mustChangePassword;

  /// Resolved NexRide admin role (`super_admin`, `finance_admin`, …).
  final String adminRole;

  /// Client-side mirror of backend permissions for UI gating only.
  final Set<String> permissions;

  bool hasPermission(String permission) => permissions.contains(permission);

  AdminSession copyWith({
    bool? mustChangePassword,
    String? adminRole,
    Set<String>? permissions,
  }) {
    return AdminSession(
      uid: uid,
      email: email,
      displayName: displayName,
      accessMode: accessMode,
      mustChangePassword: mustChangePassword ?? this.mustChangePassword,
      adminRole: adminRole ?? this.adminRole,
      permissions: permissions ?? this.permissions,
    );
  }
}

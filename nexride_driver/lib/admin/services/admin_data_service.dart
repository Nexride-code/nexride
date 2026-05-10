import 'dart:async';
import 'dart:convert';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_database/firebase_database.dart' as rtdb;
import 'package:flutter/foundation.dart';

import '../../config/driver_app_config.dart';
import '../../services/driver_finance_service.dart';
import '../../support/driver_profile_support.dart';
import '../models/admin_models.dart';

class AdminDataService {
  AdminDataService({
    rtdb.FirebaseDatabase? database,
  }) : _database = database;

  static const Duration _sourceTimeout = Duration(seconds: 8);
  static AdminPanelSnapshot? _cachedSnapshot;

  final rtdb.FirebaseDatabase? _database;

  rtdb.FirebaseDatabase get database =>
      _database ?? rtdb.FirebaseDatabase.instance;
  AdminPanelSnapshot? get cachedSnapshot => _cachedSnapshot;

  rtdb.DatabaseReference get _rootRef => database.ref();

  static const Map<String, Map<String, dynamic>> _defaultPricingConfig =
      <String, Map<String, dynamic>>{
    'lagos': <String, dynamic>{
      'city': 'Lagos',
      'baseFareNgn': 800,
      'perKmNgn': 140,
      'perMinuteNgn': 18,
      'minimumFareNgn': 1400,
      'enabled': true,
    },
    'abuja': <String, dynamic>{
      'city': 'Abuja',
      'baseFareNgn': 600,
      'perKmNgn': 115,
      'perMinuteNgn': 12,
      'minimumFareNgn': 1350,
      'enabled': true,
    },
  };

  Future<AdminPanelSnapshot> fetchSnapshot({
    String adminEmail = '',
    String adminUid = '',
  }) async {
    debugPrint(
      '[AdminData] fetchSnapshot start adminUid=$adminUid adminEmail=$adminEmail',
    );
    final results = await Future.wait<Map<String, dynamic>>(
      <Future<Map<String, dynamic>>>[
        _safeMapAt(
          'users',
          adminUid: adminUid,
          adminEmail: adminEmail,
        ),
        _safeMapAt(
          'drivers',
          adminUid: adminUid,
          adminEmail: adminEmail,
        ),
        _safeMapAt(
          'ride_requests',
          adminUid: adminUid,
          adminEmail: adminEmail,
        ),
        _safeMapAt(
          'wallets',
          adminUid: adminUid,
          adminEmail: adminEmail,
        ),
        _safeMapAt(
          'withdraw_requests',
          adminUid: adminUid,
          adminEmail: adminEmail,
        ),
        _safeMapAt(
          'driver_verifications',
          adminUid: adminUid,
          adminEmail: adminEmail,
        ),
        _safeMapAt(
          'driver_documents',
          adminUid: adminUid,
          adminEmail: adminEmail,
        ),
        _safeMapAt(
          'trip_settlement_hooks',
          adminUid: adminUid,
          adminEmail: adminEmail,
        ),
        _safeMapAt(
          'driver_business_models',
          adminUid: adminUid,
          adminEmail: adminEmail,
        ),
        _safeMapAt(
          'rider_reputation',
          adminUid: adminUid,
          adminEmail: adminEmail,
        ),
        _safeMapAt(
          'rider_risk_flags',
          adminUid: adminUid,
          adminEmail: adminEmail,
        ),
        _safeMapAt(
          'rider_payment_flags',
          adminUid: adminUid,
          adminEmail: adminEmail,
        ),
        _safeMapAt(
          'rider_reports',
          adminUid: adminUid,
          adminEmail: adminEmail,
        ),
        _safeMapAt(
          'trip_disputes',
          adminUid: adminUid,
          adminEmail: adminEmail,
        ),
        _safeMapAt(
          'trip_route_logs',
          adminUid: adminUid,
          adminEmail: adminEmail,
        ),
        _safeMapAt(
          'app_config',
          adminUid: adminUid,
          adminEmail: adminEmail,
        ),
      ],
      eagerError: true,
    );

    final usersData = results[0];
    var driversData = results[1];
    var driversFetchSource = 'rtdb';
    if (driversData.isEmpty) {
      debugPrint(
        '[AdminData] /drivers RTDB map empty (rules or network); trying adminFetchDriversTree',
      );
      final serverDrivers = await _fetchDriversTreeViaCallable();
      if (serverDrivers.isNotEmpty) {
        driversData = serverDrivers;
        driversFetchSource = 'callable_adminFetchDriversTree';
      }
    }
    final rideRequestsData = results[2];
    final walletsData = results[3];
    final withdrawalsData = results[4];
    final driverVerificationsData = results[5];
    final driverDocumentsData = results[6];
    final settlementHooksData = results[7];
    final driverBusinessModelsData = results[8];
    final riderReputationData = results[9];
    final riderRiskFlagsData = results[10];
    final riderPaymentFlagsData = results[11];
    final riderReportsData = results[12];
    final tripDisputesData = results[13];
    final tripRouteLogsData = results[14];
    final appConfigData = results[15];

    final pricingConfig = _buildPricingConfig(appConfigData);
    final settings = _buildOperationalSettings(
      appConfigData: appConfigData,
      pricingConfig: pricingConfig,
      adminEmail: adminEmail,
    );

    final trips = _buildTrips(
      rtdbTrips: rideRequestsData,
      routeLogs: tripRouteLogsData,
      settlementHooks: settlementHooksData,
      driversData: driversData,
      driverBusinessModels: driverBusinessModelsData,
    );

    final withdrawals = _buildWithdrawals(
      withdrawalsData: withdrawalsData,
      driversData: driversData,
    );

    final riderTripStats = _computeRiderTripStats(trips);
    final driverTripStats = _computeDriverTripStats(trips);

    final riders = _buildRiders(
      usersData: usersData,
      riderReputationData: riderReputationData,
      riderRiskFlagsData: riderRiskFlagsData,
      riderPaymentFlagsData: riderPaymentFlagsData,
      riderTripStats: riderTripStats,
    );

    final drivers = _buildDrivers(
      driversData: driversData,
      walletsData: walletsData,
      driverBusinessModelsData: driverBusinessModelsData,
      driverTripStats: driverTripStats,
      withdrawals: withdrawals,
    );

    final subscriptions = _buildSubscriptions(
      driversData: driversData,
      driverBusinessModelsData: driverBusinessModelsData,
    );
    try {
      _debugPrintSubscriptionRaw(
        _subscriptionRawPayload(
          driversFetchSource: driversFetchSource,
          driversData: driversData,
          subscriptions: subscriptions,
        ),
      );
    } catch (error, stackTrace) {
      debugPrint('[AdminData] subscription raw log failed: $error');
      debugPrintStack(
        label: '[AdminData] subscription raw log stack',
        stackTrace: stackTrace,
      );
    }

    final verificationCases = _buildVerificationCases(
      driversData: driversData,
      driverVerificationsData: driverVerificationsData,
      driverDocumentsData: driverDocumentsData,
    );

    final supportIssues = _buildSupportIssues(
      riderReportsData: riderReportsData,
      tripDisputesData: tripDisputesData,
      trips: trips,
    );

    final metrics = _buildDashboardMetrics(
      riders: riders,
      drivers: drivers,
      trips: trips,
      withdrawals: withdrawals,
      subscriptions: subscriptions,
    );

    final snapshot = AdminPanelSnapshot(
      fetchedAt: DateTime.now(),
      metrics: metrics,
      riders: riders,
      drivers: drivers,
      trips: trips,
      withdrawals: withdrawals,
      subscriptions: subscriptions,
      verificationCases: verificationCases,
      supportIssues: supportIssues,
      pricingConfig: pricingConfig,
      settings: settings,
      tripTrends: _buildTripTrends(trips),
      revenueTrends: _buildRevenueTrends(trips, subscriptions),
      cityPerformance: _buildCityPerformance(trips),
      driverGrowth: _buildDriverGrowth(drivers),
      adoptionBreakdown: _buildAdoptionBreakdown(drivers),
      dailyFinance: _buildDailyFinanceSlices(
        trips: trips,
        withdrawals: withdrawals,
        subscriptions: subscriptions,
      ),
      weeklyFinance: _buildWeeklyFinanceSlices(
        trips: trips,
        withdrawals: withdrawals,
        subscriptions: subscriptions,
      ),
      monthlyFinance: _buildMonthlyFinanceSlices(
        trips: trips,
        withdrawals: withdrawals,
        subscriptions: subscriptions,
      ),
      cityFinance: _buildCityFinanceSlices(
        trips: trips,
        withdrawals: withdrawals,
        subscriptions: subscriptions,
      ),
      liveDataSections: <String, bool>{
        'riders': usersData.isNotEmpty,
        'drivers': driversData.isNotEmpty,
        'trips': rideRequestsData.isNotEmpty,
        'wallets': walletsData.isNotEmpty,
        'withdrawals': withdrawalsData.isNotEmpty,
        'verification': driverVerificationsData.isNotEmpty,
        'support': riderReportsData.isNotEmpty || tripDisputesData.isNotEmpty,
        'pricing': pricingConfig.loadedFromBackend,
      },
    );
    debugPrint(
      '[AdminData] fetchSnapshot success riders=${snapshot.riders.length} drivers=${snapshot.drivers.length} trips=${snapshot.trips.length} withdrawals=${snapshot.withdrawals.length}',
    );
    _cachedSnapshot = snapshot;
    return snapshot;
  }

  Future<void> updateRiderStatus({
    required String riderId,
    required String status,
  }) async {
    await _rootRef.child('users/$riderId').update(<String, dynamic>{
      'status': status,
      'updatedAt': rtdb.ServerValue.timestamp,
      'trustSummary/accountStatus': status,
    });
  }

  Future<void> updateDriverStatus({
    required AdminDriverRecord driver,
    required String status,
  }) async {
    final normalizedAccountStatus = _normalizedAdminDriverAccountStatus(status);
    final shouldForceOffline = normalizedAccountStatus == 'suspended' ||
        normalizedAccountStatus == 'deactivated';
    final nextOperationalStatus = switch (normalizedAccountStatus) {
      'suspended' => 'suspended',
      'deactivated' => 'inactive',
      _ => _reactivatedDriverOperationalStatus(driver),
    };
    await _rootRef.child('drivers/${driver.id}').update(<String, dynamic>{
      'status': nextOperationalStatus,
      'accountStatus': normalizedAccountStatus,
      'account_status': normalizedAccountStatus,
      'updated_at': rtdb.ServerValue.timestamp,
      if (shouldForceOffline) ...<String, dynamic>{
        'isOnline': false,
        'isAvailable': false,
        'available': false,
        'online_session_started_at': null,
      },
    });
  }

  String _normalizedAdminDriverAccountStatus(String rawStatus) {
    final normalized = rawStatus.trim().toLowerCase();
    return switch (normalized) {
      'suspended' => 'suspended',
      'inactive' || 'deactivated' => 'deactivated',
      _ => 'active',
    };
  }

  String _reactivatedDriverOperationalStatus(AdminDriverRecord driver) {
    final normalizedOperationalStatus = driver.status.trim().toLowerCase();
    if (normalizedOperationalStatus.isEmpty ||
        normalizedOperationalStatus == 'inactive' ||
        normalizedOperationalStatus == 'deactivated' ||
        normalizedOperationalStatus == 'suspended') {
      return driver.isOnline ? 'idle' : 'offline';
    }
    return normalizedOperationalStatus;
  }

  Future<void> updateWithdrawal({
    required AdminWithdrawalRecord withdrawal,
    required String status,
    String payoutReference = '',
    String note = '',
  }) async {
    final updates = <String, dynamic>{};
    final normalizedStatus = status.trim().toLowerCase();
    final reference = payoutReference.trim();
    final noteValue = note.trim();
    final sourcePaths = withdrawal.sourcePaths.isNotEmpty
        ? withdrawal.sourcePaths
        : <String>['withdraw_requests/${withdrawal.id}'];

    for (final path in sourcePaths) {
      updates['$path/status'] = normalizedStatus;
      updates['$path/updatedAt'] = rtdb.ServerValue.timestamp;
      updates['$path/updated_at'] = rtdb.ServerValue.timestamp;
      if (normalizedStatus == 'processing' || normalizedStatus == 'paid') {
        updates['$path/processedAt'] = rtdb.ServerValue.timestamp;
      }
      if (reference.isNotEmpty) {
        updates['$path/payoutReference'] = reference;
        updates['$path/payout_reference'] = reference;
      }
      if (noteValue.isNotEmpty) {
        updates['$path/note'] = noteValue;
        updates['$path/adminNote'] = noteValue;
      }
    }

    await _rootRef.update(updates);
  }

  Future<void> reviewVerificationCase({
    required AdminVerificationCase verificationCase,
    required String action,
    required String reviewedBy,
    String note = '',
  }) async {
    final normalized = normalizedDriverVerification(verificationCase.rawData);
    final currentDocuments = _map(normalized['documents']);
    final nextDocuments = <String, dynamic>{};
    final actionValue = action.trim().toLowerCase();

    for (final entry in currentDocuments.entries) {
      final document = _map(entry.value);
      final status = _text(document['status']).toLowerCase();
      final nextStatus = switch (actionValue) {
        'approve' => status == 'missing' ? 'missing' : 'approved',
        'reject' => status == 'missing' ? 'missing' : 'rejected',
        'resubmit' => status == 'missing' ? 'missing' : 'rejected',
        _ => status,
      };

      nextDocuments[entry.key] = <String, dynamic>{
        ...document,
        'status': nextStatus,
        'reviewNote': note.trim(),
        'reviewedAt': rtdb.ServerValue.timestamp,
        'reviewedBy': reviewedBy.trim(),
        'failureReason': actionValue == 'reject' || actionValue == 'resubmit'
            ? (note.trim().isNotEmpty
                ? note.trim()
                : actionValue == 'resubmit'
                    ? 'resubmission_required'
                    : 'rejected_by_admin')
            : '',
        'updatedAt': rtdb.ServerValue.timestamp,
        'result': actionValue == 'approve'
            ? 'approved'
            : actionValue == 'reject'
                ? 'rejected'
                : actionValue == 'resubmit'
                    ? 'resubmission_required'
                    : document['result'],
      };
    }

    final nextVerification = normalizedDriverVerification(
      <String, dynamic>{
        ...normalized,
        'documents': nextDocuments,
        'lastReviewedAt': rtdb.ServerValue.timestamp,
        'reviewedBy': reviewedBy.trim(),
        'updatedAt': rtdb.ServerValue.timestamp,
      },
    );

    final auditRef = _rootRef.child('verification_audits').push();
    final updates = <String, dynamic>{
      'drivers/${verificationCase.driverId}/verification': nextVerification,
      'drivers/${verificationCase.driverId}/updated_at':
          rtdb.ServerValue.timestamp,
      'driver_verifications/${verificationCase.driverId}': <String, dynamic>{
        ...verificationCase.rawData,
        ...nextVerification,
        'driverId': verificationCase.driverId,
        'driverName': verificationCase.driverName,
        'phone': verificationCase.phone,
        'email': verificationCase.email,
        'reviewedBy': reviewedBy.trim(),
        'reviewedAt': rtdb.ServerValue.timestamp,
        'updatedAt': rtdb.ServerValue.timestamp,
      },
      'verification_audits/${auditRef.key}': <String, dynamic>{
        'auditId': auditRef.key,
        'driverId': verificationCase.driverId,
        'action': switch (actionValue) {
          'approve' => 'verification_approved',
          'reject' => 'verification_rejected',
          'resubmit' => 'verification_resubmission_requested',
          _ => 'verification_review_updated',
        },
        'status': nextVerification['status'],
        'result': nextVerification['result'],
        'failureReason': note.trim(),
        'reviewedBy': reviewedBy.trim(),
        'reviewedAt': rtdb.ServerValue.timestamp,
        'createdAt': rtdb.ServerValue.timestamp,
        'updatedAt': rtdb.ServerValue.timestamp,
      },
    };

    for (final entry in nextDocuments.entries) {
      updates['driver_documents/${verificationCase.driverId}/${entry.key}'] =
          <String, dynamic>{
        ..._map(entry.value),
        'driverId': verificationCase.driverId,
        'driverName': verificationCase.driverName,
      };
    }

    await _rootRef.update(updates);
  }

  Future<void> updatePricingConfig({
    required List<AdminCityPricing> cities,
    required double commissionRate,
    required int weeklySubscriptionNgn,
    required int monthlySubscriptionNgn,
  }) async {
    final normalizedCities = <String, dynamic>{
      for (final city in cities)
        city.city.toLowerCase(): <String, dynamic>{
          'city': city.city,
          'baseFareNgn': city.baseFareNgn,
          'perKmNgn': city.perKmNgn,
          'perMinuteNgn': city.perMinuteNgn,
          'minimumFareNgn': city.minimumFareNgn,
          'enabled': city.enabled,
        },
    };
    final pricingSnapshot = <String, dynamic>{
      'commissionRate': commissionRate,
      'weeklySubscriptionNgn': weeklySubscriptionNgn,
      'monthlySubscriptionNgn': monthlySubscriptionNgn,
      'updatedAt': rtdb.ServerValue.timestamp,
    };
    final updates = <String, dynamic>{
      'app_config/pricing': <String, dynamic>{
        'cities': normalizedCities,
        ...pricingSnapshot,
      },
      'app_config/city_enablement': <String, dynamic>{
        for (final city in cities) city.city.toLowerCase(): city.enabled,
      },
    };

    final driverSnapshot = await _rootRef.child('drivers').get();
    final driversData = _map(driverSnapshot.value);
    for (final entry in driversData.entries) {
      final driverId = entry.key;
      final driverProfile = _map(entry.value);
      final nextBusinessModel = normalizedDriverBusinessModel(
        <String, dynamic>{
          ..._map(
            driverProfile['businessModel'] ?? driverProfile['business_model'],
          ),
          'pricingSnapshot': pricingSnapshot,
          'updatedAt': rtdb.ServerValue.timestamp,
        },
      );
      updates['drivers/$driverId/businessModel'] = nextBusinessModel;
      updates['drivers/$driverId/updated_at'] = rtdb.ServerValue.timestamp;
      updates['driver_business_models/$driverId'] =
          buildDriverBusinessModelAdminPayload(
        driverId: driverId,
        driverProfile: driverProfile,
        businessModel: nextBusinessModel,
      );
    }

    await _rootRef.update(updates);
  }

  Future<void> updateSubscriptionStatus({
    required AdminSubscriptionRecord subscription,
    required String status,
  }) async {
    final driverPath = 'drivers/${subscription.driverId}/businessModel';
    final currentSnapshot = await _rootRef.child(driverPath).get();
    final currentBusinessModel =
        normalizedDriverBusinessModel(currentSnapshot.value);
    final nextBusinessModel = normalizedDriverBusinessModel(
      <String, dynamic>{
        ...currentBusinessModel,
        'selectedModel': 'subscription',
        'commissionExempt': status == 'active',
        'commission_exempt': status == 'active',
        'subscription': <String, dynamic>{
          ..._map(currentBusinessModel['subscription']),
          'status': status,
          'updatedAt': rtdb.ServerValue.timestamp,
        },
      },
    );

    final driverSnapshot =
        await _rootRef.child('drivers/${subscription.driverId}').get();
    final driverProfile = _map(driverSnapshot.value);

    await _rootRef.update(<String, dynamic>{
      driverPath: nextBusinessModel,
      'drivers/${subscription.driverId}/updated_at': rtdb.ServerValue.timestamp,
      'driver_business_models/${subscription.driverId}':
          buildDriverBusinessModelAdminPayload(
        driverId: subscription.driverId,
        driverProfile: driverProfile,
        businessModel: nextBusinessModel,
      ),
    });
  }

  Future<void> reviewSubscriptionRequest({
    required AdminSubscriptionRecord subscription,
    required bool approve,
  }) async {
    debugPrint(
      '[ADMIN_REVIEW_SUBSCRIPTION] callable=adminReviewSubscriptionRequest '
      'approve=$approve driverId=${subscription.driverId} action=${approve ? 'approve' : 'reject'}',
    );
    final callable = FirebaseFunctions.instanceFor(
      region: 'us-central1',
    ).httpsCallable(
      'adminReviewSubscriptionRequest',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
    );
    final result = await callable.call(<String, dynamic>{
      // `subscription.driverId` is the `drivers/{uid}` key (same as driver Firebase Auth UID).
      'driverId': subscription.driverId,
      'action': approve ? 'approve' : 'reject',
    });
    final data = _map(result.data);
    if (data['success'] != true) {
      throw StateError(
        'Subscription review failed: ${_firstText(<dynamic>[data['reason']], fallback: 'unknown_error')}',
      );
    }
  }

  Future<String> fetchSubscriptionProofUrl({required String driverId}) async {
    final callable = FirebaseFunctions.instanceFor(
      region: 'us-central1',
    ).httpsCallable(
      'adminFetchSubscriptionProofUrl',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
    );
    final result = await callable.call(<String, dynamic>{
      'driverId': driverId,
    });
    final data = _map(result.data);
    if (data['success'] != true) {
      throw StateError(
        'Proof URL unavailable: ${_firstText(<dynamic>[data['reason']], fallback: 'unknown_error')}',
      );
    }
    return _text(data['proofUrl']);
  }

  Future<void> adminSuspendAccount({
    required String uid,
    required String role,
    required String reason,
  }) async {
    final callable = FirebaseFunctions.instanceFor(
      region: 'us-central1',
    ).httpsCallable(
      'adminSuspendAccount',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
    );
    final result = await callable.call(<String, dynamic>{
      'uid': uid,
      'role': role,
      'reason': reason,
    });
    final data = _map(result.data);
    if (data['success'] != true) {
      throw StateError(
        'Suspend failed: ${_firstText(<dynamic>[data['reason']], fallback: 'unknown_error')}',
      );
    }
  }

  Future<void> adminReviewRiderFirestoreIdentity({
    required String riderId,
    required bool approve,
    String rejectionReason = '',
  }) async {
    final callable = FirebaseFunctions.instanceFor(
      region: 'us-central1',
    ).httpsCallable(
      'adminReviewRiderFirestoreIdentity',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
    );
    final payload = <String, dynamic>{
      'riderId': riderId,
      'decision': approve ? 'approved' : 'rejected',
      if (!approve && rejectionReason.trim().length >= 8)
        'rejectionReason': rejectionReason.trim(),
    };
    final result = await callable.call(payload);
    final data = _map(result.data);
    if (data['success'] != true) {
      throw StateError(
        'Identity review failed: ${_firstText(<dynamic>[data['reason']], fallback: 'unknown_error')}',
      );
    }
  }

  Future<void> adminWarnAccount({
    required String uid,
    required String role,
    required String reason,
    String message = '',
  }) async {
    final callable = FirebaseFunctions.instanceFor(
      region: 'us-central1',
    ).httpsCallable(
      'adminWarnAccount',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
    );
    final result = await callable.call(<String, dynamic>{
      'uid': uid,
      'role': role,
      'reason': reason,
      'message': message,
    });
    final data = _map(result.data);
    if (data['success'] != true) {
      throw StateError(
        'Warn failed: ${_firstText(<dynamic>[data['reason']], fallback: 'unknown_error')}',
      );
    }
  }

  Future<void> adminDeleteAccount({
    required String uid,
    required String role,
  }) async {
    final callable = FirebaseFunctions.instanceFor(
      region: 'us-central1',
    ).httpsCallable(
      'adminDeleteAccount',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 45)),
    );
    final result = await callable.call(<String, dynamic>{
      'uid': uid,
      'role': role,
    });
    final data = _map(result.data);
    if (data['success'] != true) {
      throw StateError(
        'Delete failed: ${_firstText(<dynamic>[data['reason']], fallback: 'unknown_error')}',
      );
    }
  }

  Future<void> adminApproveDriverVerification({
    required String driverId,
  }) async {
    final callable = FirebaseFunctions.instanceFor(
      region: 'us-central1',
    ).httpsCallable(
      'adminApproveDriverVerification',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
    );
    final result = await callable.call(<String, dynamic>{
      'driverId': driverId,
    });
    final data = _map(result.data);
    if (data['success'] != true) {
      throw StateError(
        'Approve verification failed: ${_firstText(<dynamic>[data['reason']], fallback: 'unknown_error')}',
      );
    }
  }

  Future<Map<String, dynamic>> _fetchDriversTreeViaCallable() async {
    try {
      final callable = FirebaseFunctions.instanceFor(
        region: 'us-central1',
      ).httpsCallable(
        'adminFetchDriversTree',
        options: HttpsCallableOptions(
          timeout: const Duration(seconds: 45),
        ),
      );
      final result = await callable.call(<String, dynamic>{});
      final data = _map(result.data);
      if (data['success'] != true) {
        debugPrint('[AdminData] adminFetchDriversTree rejected: $data');
        return const <String, dynamic>{};
      }
      return _map(data['drivers']);
    } catch (error, stackTrace) {
      debugPrint('[AdminData] adminFetchDriversTree error=$error');
      debugPrintStack(
        label: '[AdminData] adminFetchDriversTree stack',
        stackTrace: stackTrace,
      );
      return const <String, dynamic>{};
    }
  }

  /// Safe logging only (no `dart:js_interop` — avoids browser crashes).
  void _debugPrintSubscriptionRaw(Map<String, Object?> payload) {
    try {
      debugPrint('[SUBSCRIPTION_RAW_DATA] ${jsonEncode(payload)}');
    } catch (error, stackTrace) {
      debugPrint(
        '[SUBSCRIPTION_RAW_DATA] jsonEncode failed: $error payload=$payload',
      );
      debugPrintStack(
        label: '[SUBSCRIPTION_RAW_DATA] stack',
        stackTrace: stackTrace,
      );
    }
  }

  Map<String, Object?> _subscriptionRawPayload({
    required String driversFetchSource,
    required Map<String, dynamic> driversData,
    required List<AdminSubscriptionRecord> subscriptions,
  }) {
    final slices = <String, Object?>{};
    driversData.forEach((String uid, dynamic entryValue) {
      final driver = _map(entryValue);
      final bm = normalizedDriverBusinessModel(driver['businessModel']);
      final sub = _map(bm['subscription']);
      final hasProofUrl =
          '${driver['subscription_proof_url'] ?? ''}'.trim().isNotEmpty;
      slices[uid] = <String, Object?>{
        'subscription_pending': driver['subscription_pending'],
        'subscription_status': driver['subscription_status'],
        'subscription_type': driver['subscription_type'],
        'subscription_amount': driver['subscription_amount'],
        'has_proof_url': hasProofUrl,
        'nested_subscription_status': sub['status'],
      };
    });
    final pendingRows =
        subscriptions.where((AdminSubscriptionRecord r) => r.pendingApproval).toList();
    return <String, Object?>{
      'driversFetchSource': driversFetchSource,
      'driverRootCount': driversData.length,
      'subscriptionRowCount': subscriptions.length,
      'pendingApprovalRowCount': pendingRows.length,
      'driverSubscriptionSlices': slices,
      'pendingRows': pendingRows
          .map(
            (AdminSubscriptionRecord r) => <String, Object?>{
              'driverId': r.driverId,
              'driverName': r.driverName,
              'planType': r.planType,
              'amountNgn': r.amountNgn,
              'pendingApproval': r.pendingApproval,
              'hasProof': r.hasProof,
            },
          )
          .toList(growable: false),
    };
  }

  Future<Map<String, dynamic>> _safeMapAt(
    String path, {
    required String adminUid,
    required String adminEmail,
    bool critical = false,
  }) async {
    debugPrint(
      '[AdminData] query start source=rtdb path=$path adminUid=$adminUid adminEmail=$adminEmail critical=$critical',
    );
    try {
      final snapshot = await _rootRef.child(path).get().timeout(_sourceTimeout);
      final mapped = _map(snapshot.value);
      debugPrint(
        '[AdminData] query success source=rtdb path=$path records=${mapped.length}',
      );
      return mapped;
    } on TimeoutException catch (error, stackTrace) {
      debugPrint(
          '[AdminData] query timeout source=rtdb path=$path error=$error');
      debugPrintStack(
        label: '[AdminData] query timeout stack',
        stackTrace: stackTrace,
      );
      if (critical) {
        throw AdminDataSourceException(
          path: path,
          reason: 'timeout',
          cause: error,
        );
      }
      return const <String, dynamic>{};
    } catch (error, stackTrace) {
      final permissionDenied = _isPermissionDenied(error);
      debugPrint(
        '[AdminData] query failure source=rtdb path=$path permissionDenied=$permissionDenied error=$error',
      );
      debugPrintStack(
        label: '[AdminData] query failure stack',
        stackTrace: stackTrace,
      );
      if (critical) {
        throw AdminDataSourceException(
          path: path,
          reason: permissionDenied ? 'permission' : 'error',
          cause: error,
        );
      }
      return const <String, dynamic>{};
    }
  }

  List<AdminTripRecord> _buildTrips({
    required Map<String, dynamic> rtdbTrips,
    required Map<String, dynamic> routeLogs,
    required Map<String, dynamic> settlementHooks,
    required Map<String, dynamic> driversData,
    required Map<String, dynamic> driverBusinessModels,
  }) {
    final tripIds = <String>{
      ...rtdbTrips.keys,
      ...routeLogs.keys,
      ...settlementHooks.keys,
    };

    final trips = <AdminTripRecord>[];
    for (final tripId in tripIds) {
      final rtdbTrip = _map(rtdbTrips[tripId]);
      final routeLog = _map(routeLogs[tripId]);
      final settlementHook = _map(settlementHooks[tripId]);
      final settlement = _map(settlementHook['settlement']);
      final settlementContext =
          settlement.isNotEmpty ? settlement : settlementHook;
      final merged = <String, dynamic>{
        ...rtdbTrip,
        if (settlementContext.isNotEmpty) 'settlement': settlementContext,
        if (routeLog.isNotEmpty) 'routeLog': routeLog,
      };
      final mergedSettlement = _map(merged['settlement']);

      final riderId = _firstText(<dynamic>[
        merged['rider_id'],
        merged['riderId'],
        settlementContext['riderId'],
      ]);
      final driverId = _firstText(<dynamic>[
        merged['driver_id'],
        merged['driverId'],
        settlementContext['driverId'],
      ]);
      final driverData = _map(driversData[driverId]);
      final settlementBusinessModel = _map(
        settlementContext['businessModelSnapshot'] ??
            mergedSettlement['businessModelSnapshot'],
      );
      final businessModel = settlementBusinessModel.isNotEmpty
          ? normalizedDriverBusinessModel(settlementBusinessModel)
          : normalizedDriverBusinessModel(
              driverData['businessModel'] ??
                  _map(driverBusinessModels[driverId])['businessModel'],
            );
      final fareAmount = _firstPositiveDouble(<dynamic>[
        settlementContext['grossFareNgn'],
        settlementContext['grossFare'],
        merged['fare'],
        merged['grossFare'],
        merged['gross_fare'],
        settlementHook['fareEstimateNgn'],
      ]);
      final settlementBreakdown = calculateDriverTripSettlement(
        grossFare: fareAmount,
        businessModel: businessModel,
      );
      final commissionAmount = _firstAvailableDoubleOrNull(<dynamic>[
        settlementContext['commissionAmountNgn'],
        settlementContext['commissionAmount'],
        settlementContext['commission'],
        mergedSettlement['commissionAmountNgn'],
        mergedSettlement['commissionAmount'],
        mergedSettlement['commission'],
        merged['commissionAmount'],
        merged['commission_amount'],
        merged['commission'],
      ]);
      final payoutAmount = _firstAvailableDoubleOrNull(<dynamic>[
        settlementContext['driverPayoutNgn'],
        settlementContext['driverPayout'],
        settlementContext['netEarningNgn'],
        settlementContext['netEarning'],
        mergedSettlement['driverPayoutNgn'],
        mergedSettlement['driverPayout'],
        mergedSettlement['netEarningNgn'],
        mergedSettlement['netEarning'],
        merged['driverPayout'],
        merged['driver_payout'],
        merged['netEarning'],
      ]);
      final normalizedStatus = _normalizeTripStatus(
        _firstText(<dynamic>[
          merged['status'],
          settlementContext['completionState'],
          routeLog['status'],
        ]),
      );
      final settlementStatus = _normalizeTripSettlementStatus(
        tripStatus: normalizedStatus,
        rawSettlementStatus: _firstText(<dynamic>[
          settlementContext['settlementStatus'],
          mergedSettlement['settlementStatus'],
          settlementContext['completionState'],
          merged['settlementStatus'],
        ]),
        settlementContext: settlementContext,
        mergedSettlement: mergedSettlement,
        commissionAmount: commissionAmount,
        payoutAmount: payoutAmount,
      );
      final hasValidMonetizedSettlement = _tripHasValidMonetizedSettlement(
        tripStatus: normalizedStatus,
        settlementStatus: settlementStatus,
      );
      final cancellationReason = normalizedStatus == 'cancelled'
          ? _tripCancellationReason(
              trip: merged,
              routeLog: routeLog,
            )
          : '';

      trips.add(
        AdminTripRecord(
          id: tripId,
          source: rtdbTrip.isNotEmpty ? 'rtdb' : 'derived',
          status: normalizedStatus,
          city: _resolveTripCity(merged),
          serviceType: _normalizeServiceType(
            _firstText(<dynamic>[
              merged['service_type'],
              merged['serviceType'],
              settlementContext['serviceType'],
            ]),
          ),
          riderId: riderId,
          riderName: _firstText(<dynamic>[
            merged['rider_name'],
            merged['riderName'],
          ], fallback: 'Rider'),
          riderPhone: _firstText(<dynamic>[
            merged['rider_phone'],
            merged['riderPhone'],
            merged['phone'],
          ]),
          driverId: driverId,
          driverName: _firstText(<dynamic>[
            merged['driver_name'],
            merged['driverName'],
            driverData['name'],
          ], fallback: 'Unassigned'),
          driverPhone: _firstText(<dynamic>[
            merged['driver_phone'],
            merged['driverPhone'],
            driverData['phone'],
          ]),
          pickupAddress: _firstText(<dynamic>[
            merged['pickup_address'],
            merged['pickupAddress'],
            merged['pickup'],
          ]),
          destinationAddress: _firstText(<dynamic>[
            merged['destination_address'],
            merged['destinationAddress'],
            merged['final_destination_address'],
            merged['destination'],
          ]),
          paymentMethod: _paymentMethodLabel(
            _firstText(<dynamic>[
              merged['payment_method'],
              merged['paymentMethod'],
              mergedSettlement['paymentMethod'],
              settlementContext['paymentMethod'],
            ]),
          ),
          fareAmount: fareAmount,
          distanceKm: _resolveDistanceKm(merged),
          durationMinutes: _resolveDurationMinutes(merged),
          commissionAmount: hasValidMonetizedSettlement
              ? (commissionAmount ?? settlementBreakdown.commissionAmount)
              : 0,
          driverPayout: hasValidMonetizedSettlement
              ? (payoutAmount ?? settlementBreakdown.netPayout)
              : 0,
          appliedMonetizationModel: hasValidMonetizedSettlement
              ? _firstText(<dynamic>[
                  settlementContext['appliedModel'],
                  mergedSettlement['appliedModel'],
                  settlementBreakdown.appliedModel,
                ])
              : '',
          settlementStatus: settlementStatus,
          cancellationReason: cancellationReason,
          createdAt: _dateFromCandidates(<dynamic>[
            merged['requested_at'],
            merged['created_at'],
            merged['createdAt'],
          ]),
          acceptedAt: _dateFromCandidates(<dynamic>[
            merged['accepted_at'],
            merged['acceptedAt'],
          ]),
          arrivedAt: _dateFromCandidates(<dynamic>[
            merged['arrived_at'],
            merged['arrivedAt'],
          ]),
          startedAt: _dateFromCandidates(<dynamic>[
            merged['trip_started_at'],
            merged['started_at'],
            merged['startedAt'],
          ]),
          completedAt: _dateFromCandidates(<dynamic>[
            merged['trip_completed_at'],
            merged['completed_at'],
            merged['completedAt'],
          ]),
          cancelledAt: _dateFromCandidates(<dynamic>[
            merged['cancelled_effective_at'],
            merged['cancelled_at'],
            merged['canceled_at'],
            merged['cancelledAt'],
            merged['cancelled_recorded_at'],
          ]),
          routeLog: routeLog,
          rawData: merged,
        ),
      );
    }

    trips.sort(
      (AdminTripRecord a, AdminTripRecord b) =>
          (b.createdAt?.millisecondsSinceEpoch ?? 0)
              .compareTo(a.createdAt?.millisecondsSinceEpoch ?? 0),
    );
    return trips;
  }

  List<AdminWithdrawalRecord> _buildWithdrawals({
    required Map<String, dynamic> withdrawalsData,
    required Map<String, dynamic> driversData,
  }) {
    final records = <_WithdrawalAccumulator>{};
    _walkWithdrawals(
      data: withdrawalsData,
      currentPath: 'withdraw_requests',
      onRecord: (String path, Map<String, dynamic> record) {
        final driverId = _firstText(<dynamic>[
          record['driverId'],
          record['driver_id'],
          path.split('/').length >= 3 ? path.split('/')[1] : '',
        ]);
        final recordId = _firstText(<dynamic>[
          record['withdrawalId'],
          record['id'],
          path.split('/').last,
        ]);
        records.add(
          _WithdrawalAccumulator(
            id: recordId,
            driverId: driverId,
            path: path,
            rawData: record,
          ),
        );
      },
    );

    final merged = <String, _WithdrawalAccumulator>{};
    for (final accumulator in records) {
      final key = '${accumulator.driverId}_${accumulator.id}';
      final existing = merged[key];
      if (existing == null) {
        merged[key] = accumulator;
      } else {
        existing.sourcePaths.addAll(accumulator.sourcePaths);
        existing.rawData.addAll(accumulator.rawData);
      }
    }

    final withdrawals = merged.values.map((accumulator) {
      final raw = accumulator.rawData;
      final driverData = _map(driversData[accumulator.driverId]);
      return AdminWithdrawalRecord(
        id: accumulator.id,
        driverId: accumulator.driverId,
        driverName: _firstText(<dynamic>[
          raw['driverName'],
          raw['driver_name'],
          driverData['name'],
        ], fallback: 'Driver'),
        amount: _firstPositiveDouble(<dynamic>[raw['amount']]),
        status: _normalizeWithdrawalStatus(_text(raw['status'])),
        requestDate: _dateFromCandidates(<dynamic>[
          raw['requestedAt'],
          raw['requestDate'],
          raw['createdAt'],
          raw['created_at'],
        ]),
        processedDate: _dateFromCandidates(<dynamic>[
          raw['processedAt'],
          raw['updatedAt'],
          raw['updated_at'],
        ]),
        bankName: _firstText(<dynamic>[
          _map(raw['withdrawalAccount'])['bankName'],
          _map(raw['bankDetails'])['bankName'],
          raw['bankName'],
        ]),
        accountName: _firstText(<dynamic>[
          _map(raw['withdrawalAccount'])['accountName'],
          _map(raw['bankDetails'])['accountName'],
          raw['accountName'],
        ]),
        accountNumber: _firstText(<dynamic>[
          _map(raw['withdrawalAccount'])['accountNumber'],
          _map(raw['bankDetails'])['accountNumber'],
          raw['accountNumber'],
        ]),
        payoutReference: _firstText(<dynamic>[
          raw['payoutReference'],
          raw['payout_reference'],
          raw['reference'],
        ]),
        notes: _firstText(<dynamic>[
          raw['note'],
          raw['adminNote'],
          raw['message'],
        ]),
        sourcePaths: accumulator.sourcePaths.toList(growable: false),
        rawData: raw,
      );
    }).toList()
      ..sort(
        (AdminWithdrawalRecord a, AdminWithdrawalRecord b) =>
            (b.requestDate?.millisecondsSinceEpoch ?? 0)
                .compareTo(a.requestDate?.millisecondsSinceEpoch ?? 0),
      );

    return withdrawals;
  }

  List<AdminRiderRecord> _buildRiders({
    required Map<String, dynamic> usersData,
    required Map<String, dynamic> riderReputationData,
    required Map<String, dynamic> riderRiskFlagsData,
    required Map<String, dynamic> riderPaymentFlagsData,
    required Map<String, AdminTripSummary> riderTripStats,
  }) {
    final riders = <AdminRiderRecord>[];

    for (final entry in usersData.entries) {
      try {
        final id = entry.key;
        final user = _map(entry.value);
        final trustSummary = _map(user['trustSummary']);
        final reputation = _map(riderReputationData[id]);
        final riskFlags = _map(riderRiskFlagsData[id]);
        final paymentFlags = _map(riderPaymentFlagsData[id]);
        riders.add(
          AdminRiderRecord(
            id: id,
            name: _firstText(<dynamic>[user['name']], fallback: 'Rider'),
            phone: _firstText(<dynamic>[user['phone']]),
            email: _firstText(<dynamic>[user['email']]),
            city: _firstText(<dynamic>[
              user['city'],
              user['homeCity'],
            ]),
            status: _firstText(<dynamic>[
              user['status'],
              trustSummary['accountStatus'],
            ], fallback: 'active'),
            verificationStatus: _firstText(<dynamic>[
              _map(user['verification'])['overallStatus'],
              trustSummary['verificationStatus'],
            ], fallback: 'unverified'),
            riskStatus: _firstText(<dynamic>[
              riskFlags['status'],
              trustSummary['riskStatus'],
            ], fallback: 'clear'),
            paymentStatus: _firstText(<dynamic>[
              paymentFlags['status'],
              trustSummary['paymentStatus'],
            ], fallback: 'clear'),
            createdAt: _dateFromCandidates(<dynamic>[
              user['createdAt'],
              user['created_at'],
            ]),
            lastActiveAt: _dateFromCandidates(<dynamic>[
              user['lastActive'],
              user['updatedAt'],
              user['last_active'],
            ]),
            walletBalance: _firstPositiveDouble(<dynamic>[
              _map(user['wallet'])['balance'],
              user['walletBalance'],
            ]),
            tripSummary: riderTripStats[id] ??
                const AdminTripSummary(
                  totalTrips: 0,
                  completedTrips: 0,
                  cancelledTrips: 0,
                ),
            rating: _firstPositiveDouble(<dynamic>[
              reputation['averageRating'],
              trustSummary['rating'],
            ]),
            ratingCount: _firstInt(<dynamic>[
              reputation['ratingCount'],
              trustSummary['ratingCount'],
            ]),
            outstandingFeesNgn: _firstInt(<dynamic>[
              paymentFlags['outstandingCancellationFeesNgn'],
              trustSummary['outstandingCancellationFeesNgn'],
            ]),
            rawData: user,
          ),
        );
      } catch (error, stackTrace) {
        debugPrint(
          '[AdminData] rider parse failed riderId=${entry.key} error=$error',
        );
        debugPrintStack(
          label: '[AdminData] rider parse stack',
          stackTrace: stackTrace,
        );
      }
    }

    riders.sort(
      (AdminRiderRecord a, AdminRiderRecord b) =>
          (b.createdAt?.millisecondsSinceEpoch ?? 0)
              .compareTo(a.createdAt?.millisecondsSinceEpoch ?? 0),
    );
    return riders;
  }

  List<AdminDriverRecord> _buildDrivers({
    required Map<String, dynamic> driversData,
    required Map<String, dynamic> walletsData,
    required Map<String, dynamic> driverBusinessModelsData,
    required Map<String, _DriverTripStats> driverTripStats,
    required List<AdminWithdrawalRecord> withdrawals,
  }) {
    final withdrawalsByDriver = <String, List<AdminWithdrawalRecord>>{};
    for (final withdrawal in withdrawals) {
      withdrawalsByDriver
          .putIfAbsent(withdrawal.driverId, () => <AdminWithdrawalRecord>[])
          .add(withdrawal);
    }

    final drivers = <AdminDriverRecord>[];
    for (final entry in driversData.entries) {
      final id = entry.key;
      final driver = _map(entry.value);
      final wallet = _map(walletsData[id]);
      final businessModel = normalizedDriverBusinessModel(
        driver['businessModel'] ??
            _map(driverBusinessModelsData[id])['businessModel'],
      );
      final verification = normalizedDriverVerification(driver['verification']);
      final tripStats = driverTripStats[id] ?? _DriverTripStats();
      final driverWithdrawals =
          withdrawalsByDriver[id] ?? const <AdminWithdrawalRecord>[];
      final totalWithdrawn = driverWithdrawals
          .where((AdminWithdrawalRecord item) => item.status == 'paid')
          .fold<double>(
              0, (double sum, AdminWithdrawalRecord item) => sum + item.amount);
      final pendingWithdrawalTotal = driverWithdrawals
          .where(
            (AdminWithdrawalRecord item) =>
                item.status == 'pending' || item.status == 'processing',
          )
          .fold<double>(
              0, (double sum, AdminWithdrawalRecord item) => sum + item.amount);
      final subscription = _map(businessModel['subscription']);

      drivers.add(
        AdminDriverRecord(
          id: id,
          name: _firstText(<dynamic>[driver['name']], fallback: 'Driver'),
          phone: _firstText(<dynamic>[driver['phone']]),
          email: _firstText(<dynamic>[driver['email']]),
          city: _firstText(<dynamic>[driver['city']]),
          accountStatus: _normalizedAdminDriverAccountStatus(
            _firstText(<dynamic>[
              driver['accountStatus'],
              driver['account_status'],
              driver['status'],
            ], fallback: 'active'),
          ),
          status: _firstText(<dynamic>[driver['status']], fallback: 'offline'),
          isOnline: driver['isOnline'] == true,
          verificationStatus: _text(verification['overallStatus']).isNotEmpty
              ? _text(verification['overallStatus'])
              : 'incomplete',
          vehicleName: _firstText(<dynamic>[
            driver['car'],
            _map(driver['vehicle'])['model'],
          ]),
          plateNumber: _firstText(<dynamic>[
            driver['plate'],
            _map(driver['vehicle'])['plate'],
          ]),
          tripCount: tripStats.totalTrips,
          completedTripCount: tripStats.completedTrips,
          grossEarnings: tripStats.grossBookings,
          netEarnings: tripStats.driverPayouts,
          walletBalance: _firstPositiveDouble(<dynamic>[
            wallet['balance'],
            wallet['currentBalance'],
            driver['walletBalance'],
          ]),
          totalWithdrawn: totalWithdrawn,
          pendingWithdrawals: pendingWithdrawalTotal,
          monetizationModel: driverEffectiveMonetizationModel(businessModel),
          subscriptionPlanType: _firstText(<dynamic>[
            subscription['planType'],
          ], fallback: 'monthly'),
          subscriptionStatus: _firstText(<dynamic>[
            subscription['status'],
          ], fallback: 'setup_required'),
          subscriptionActive: driverSubscriptionIsActive(businessModel),
          createdAt: _dateFromCandidates(<dynamic>[
            driver['created_at'],
            driver['createdAt'],
          ]),
          updatedAt: _dateFromCandidates(<dynamic>[
            driver['updated_at'],
            driver['updatedAt'],
          ]),
          serviceTypes:
              _stringList(driver['serviceTypes'] ?? driver['service_types']),
          rawData: driver,
        ),
      );
    }

    drivers.sort(
      (AdminDriverRecord a, AdminDriverRecord b) =>
          (b.createdAt?.millisecondsSinceEpoch ?? 0)
              .compareTo(a.createdAt?.millisecondsSinceEpoch ?? 0),
    );
    return drivers;
  }

  List<AdminSubscriptionRecord> _buildSubscriptions({
    required Map<String, dynamic> driversData,
    required Map<String, dynamic> driverBusinessModelsData,
  }) {
    final subscriptions = <AdminSubscriptionRecord>[];

    for (final entry in driversData.entries) {
      final driverId = entry.key;
      final driver = _map(entry.value);
      final businessModel = normalizedDriverBusinessModel(
        driver['businessModel'] ??
            _map(driverBusinessModelsData[driverId])['businessModel'],
      );
      final subscription = _map(businessModel['subscription']);
      final selectedModel = _text(businessModel['selectedModel']);
      final status = _text(subscription['status']);
      final rootSubStatus =
          _text(driver['subscription_status']).toLowerCase().trim();
      final hasProof =
          '${driver['subscription_proof_url'] ?? ''}'.trim().isNotEmpty;
      final pendingApproval = _boolish(driver['subscription_pending']) ||
          status == 'pending_approval' ||
          rootSubStatus == 'pending' ||
          rootSubStatus == 'pending_review' ||
          hasProof;
      final requestedAt = _dateFromCandidates(<dynamic>[
        driver['subscription_requested_at'],
      ]);
      final paymentReference = _firstText(<dynamic>[
        driver['subscription_payment_reference'],
      ]);
      final planNormalized = _normalizedSubscriptionPlanKind(
        subscription: subscription,
        driver: driver,
      );
      final amountNgn = _firstInt(<dynamic>[
        driver['subscription_amount'],
        planNormalized == 'weekly'
            ? DriverBusinessConfig.weeklySubscriptionPriceNgn
            : DriverBusinessConfig.monthlySubscriptionPriceNgn,
      ]);

      if (selectedModel != 'subscription' &&
          !pendingApproval &&
          !hasProof &&
          _text(driver['subscription_payment_reference']).isEmpty &&
          (status.isEmpty ||
              status == 'setup_required' ||
              status == 'not_started')) {
        continue;
      }

      subscriptions.add(
        AdminSubscriptionRecord(
          driverId: driverId,
          driverName: _firstText(<dynamic>[driver['name']], fallback: 'Driver'),
          city: _firstText(<dynamic>[driver['city']]),
          planType: planNormalized,
          status: status.isNotEmpty ? status : 'setup_required',
          paymentStatus: _firstText(<dynamic>[
            subscription['paymentStatus'],
          ], fallback: 'not_started'),
          startDate: _dateFromCandidates(<dynamic>[
            subscription['startDate'],
            subscription['startedAt'],
            subscription['createdAt'],
          ]),
          endDate: _dateFromCandidates(<dynamic>[
            subscription['validUntil'],
            subscription['expiresAt'],
            subscription['renewalDate'],
            driver['subscription_expires_at'],
          ]),
          isActive: driverSubscriptionIsActive(businessModel),
          pendingApproval: pendingApproval,
          requestedAt: requestedAt,
          paymentReference: paymentReference,
          hasProof: hasProof,
          amountNgn: amountNgn,
          rawData: <String, dynamic>{
            ...subscription,
            'driverId': driverId,
            'driverName': driver['name'],
          },
        ),
      );
      debugPrint(
        '[AdminData][Subscriptions] driverId=$driverId pending=$pendingApproval '
        'status=${_text(driver['subscription_status'])} plan=${_text(driver['subscription_type'])} '
        'hasProof=$hasProof reference=${paymentReference.isNotEmpty}',
      );
    }

    subscriptions.sort(
      (AdminSubscriptionRecord a, AdminSubscriptionRecord b) =>
          (b.startDate?.millisecondsSinceEpoch ?? 0)
              .compareTo(a.startDate?.millisecondsSinceEpoch ?? 0),
    );
    return subscriptions;
  }

  List<AdminVerificationCase> _buildVerificationCases({
    required Map<String, dynamic> driversData,
    required Map<String, dynamic> driverVerificationsData,
    required Map<String, dynamic> driverDocumentsData,
  }) {
    final verificationIds = <String>{
      ...driversData.keys,
      ...driverVerificationsData.keys,
      ...driverDocumentsData.keys,
    };
    final cases = <AdminVerificationCase>[];

    for (final driverId in verificationIds) {
      final driver = _map(driversData[driverId]);
      final aggregateRecord = _map(driverVerificationsData[driverId]);
      final documents = _map(driverDocumentsData[driverId]);
      final verification = normalizedDriverVerification(
        aggregateRecord.isNotEmpty
            ? <String, dynamic>{
                ...aggregateRecord,
                if (aggregateRecord['documents'] == null &&
                    documents.isNotEmpty)
                  'documents': documents,
              }
            : <String, dynamic>{
                ..._map(driver['verification']),
                if (documents.isNotEmpty) 'documents': documents,
              },
      );

      final hasMeaningfulVerification = ((verification['submittedCount'] is int
                  ? verification['submittedCount'] as int
                  : 0) >
              0) ||
          _text(verification['status']).isNotEmpty;
      if (!hasMeaningfulVerification && driver.isEmpty) {
        continue;
      }

      cases.add(
        AdminVerificationCase(
          driverId: driverId,
          driverName: _firstText(<dynamic>[
            aggregateRecord['driverName'],
            driver['name'],
          ], fallback: 'Driver'),
          phone: _firstText(<dynamic>[
            aggregateRecord['phone'],
            driver['phone'],
          ]),
          email: _firstText(<dynamic>[
            aggregateRecord['email'],
            driver['email'],
          ]),
          businessModel: _firstText(<dynamic>[
            aggregateRecord['businessModel'],
            normalizedDriverBusinessModel(
                driver['businessModel'])['selectedModel'],
          ], fallback: 'commission'),
          status: _text(verification['status']).isNotEmpty
              ? _text(verification['status'])
              : 'missing',
          overallStatus: _text(verification['overallStatus']).isNotEmpty
              ? _text(verification['overallStatus'])
              : 'incomplete',
          submittedAt: _dateFromCandidates(<dynamic>[
            aggregateRecord['submittedAt'],
            verification['lastSubmittedAt'],
          ]),
          reviewedAt: _dateFromCandidates(<dynamic>[
            aggregateRecord['reviewedAt'],
            verification['lastReviewedAt'],
          ]),
          reviewedBy: _firstText(<dynamic>[
            aggregateRecord['reviewedBy'],
            verification['reviewedBy'],
          ]),
          failureReason: _firstText(<dynamic>[
            aggregateRecord['failureReason'],
            verification['failureReason'],
          ]),
          documents: _map(verification['documents']),
          rawData: verification,
        ),
      );
    }

    cases.sort(
      (AdminVerificationCase a, AdminVerificationCase b) =>
          (b.submittedAt?.millisecondsSinceEpoch ?? 0)
              .compareTo(a.submittedAt?.millisecondsSinceEpoch ?? 0),
    );
    return cases;
  }

  List<AdminSupportIssueRecord> _buildSupportIssues({
    required Map<String, dynamic> riderReportsData,
    required Map<String, dynamic> tripDisputesData,
    required List<AdminTripRecord> trips,
  }) {
    final tripById = <String, AdminTripRecord>{
      for (final trip in trips) trip.id: trip,
    };
    final issues = <AdminSupportIssueRecord>[];

    for (final entry in riderReportsData.entries) {
      final record = _map(entry.value);
      final trip = tripById[_firstText(<dynamic>[record['rideId']])];
      issues.add(
        AdminSupportIssueRecord(
          id: entry.key,
          kind: 'rider_report',
          status: _firstText(<dynamic>[record['status']], fallback: 'pending'),
          reason: _firstText(<dynamic>[record['reason']], fallback: 'Report'),
          summary: _firstText(<dynamic>[record['message']],
              fallback: 'Issue reported for manual review.'),
          rideId: _firstText(<dynamic>[record['rideId']]),
          riderId: _firstText(<dynamic>[record['riderId']]),
          driverId: _firstText(<dynamic>[record['driverId']]),
          city: _firstText(<dynamic>[record['city'], trip?.city]),
          createdAt: _dateFromCandidates(<dynamic>[record['createdAt']]),
          updatedAt: _dateFromCandidates(<dynamic>[record['updatedAt']]),
          rawData: record,
        ),
      );
    }

    for (final entry in tripDisputesData.entries) {
      final record = _map(entry.value);
      final trip = tripById[_firstText(<dynamic>[record['rideId']])];
      issues.add(
        AdminSupportIssueRecord(
          id: entry.key,
          kind: 'trip_dispute',
          status: _firstText(<dynamic>[record['status']], fallback: 'pending'),
          reason: _firstText(<dynamic>[
            record['reason'],
            record['title'],
          ], fallback: 'Trip dispute'),
          summary: _firstText(<dynamic>[
            record['message'],
            record['note'],
          ], fallback: 'Dispute raised for this trip.'),
          rideId: _firstText(<dynamic>[record['rideId']]),
          riderId: _firstText(<dynamic>[record['riderId']]),
          driverId: _firstText(<dynamic>[record['driverId']]),
          city: _firstText(<dynamic>[record['city'], trip?.city]),
          createdAt: _dateFromCandidates(<dynamic>[record['createdAt']]),
          updatedAt: _dateFromCandidates(<dynamic>[record['updatedAt']]),
          rawData: record,
        ),
      );
    }

    issues.sort(
      (AdminSupportIssueRecord a, AdminSupportIssueRecord b) =>
          (b.createdAt?.millisecondsSinceEpoch ?? 0)
              .compareTo(a.createdAt?.millisecondsSinceEpoch ?? 0),
    );
    return issues;
  }

  AdminPricingConfig _buildPricingConfig(Map<String, dynamic> appConfigData) {
    final pricing = _map(appConfigData['pricing']);
    final pricingCities = _map(pricing['cities']);
    final mergedCities = <String, Map<String, dynamic>>{
      for (final entry in _defaultPricingConfig.entries)
        entry.key: <String, dynamic>{...entry.value},
    };

    for (final entry in pricingCities.entries) {
      mergedCities[entry.key.toLowerCase()] = <String, dynamic>{
        ...mergedCities[entry.key.toLowerCase()] ?? const <String, dynamic>{},
        ..._map(entry.value),
      };
    }

    final cities = mergedCities.values
        .map(
          (Map<String, dynamic> city) => AdminCityPricing(
            city: _titleCase(
                _text(city['city']).isNotEmpty ? _text(city['city']) : 'City'),
            baseFareNgn:
                _firstInt(<dynamic>[city['baseFareNgn'], city['base_fare']]),
            perKmNgn: _firstInt(<dynamic>[city['perKmNgn'], city['per_km']]),
            perMinuteNgn: _firstInt(<dynamic>[
              city['perMinuteNgn'],
              city['per_minute'],
            ]),
            minimumFareNgn: _firstInt(<dynamic>[
              city['minimumFareNgn'],
              city['minimum_fare'],
            ]),
            enabled: city['enabled'] != false,
          ),
        )
        .toList()
      ..sort(
          (AdminCityPricing a, AdminCityPricing b) => a.city.compareTo(b.city));

    return AdminPricingConfig(
      cities: cities,
      commissionRate: _firstPositiveDouble(<dynamic>[
        pricing['commissionRate'],
        pricing['commission_rate'],
        DriverBusinessConfig.commissionRate,
      ]),
      weeklySubscriptionNgn: _firstInt(<dynamic>[
        pricing['weeklySubscriptionNgn'],
        pricing['weekly_subscription_ngn'],
        DriverBusinessConfig.weeklySubscriptionPriceNgn,
      ]),
      monthlySubscriptionNgn: _firstInt(<dynamic>[
        pricing['monthlySubscriptionNgn'],
        pricing['monthly_subscription_ngn'],
        DriverBusinessConfig.monthlySubscriptionPriceNgn,
      ]),
      loadedFromBackend: pricing.isNotEmpty,
      lastUpdated: _dateFromCandidates(<dynamic>[pricing['updatedAt']]),
      rawData: pricing,
    );
  }

  AdminOperationalSettings _buildOperationalSettings({
    required Map<String, dynamic> appConfigData,
    required AdminPricingConfig pricingConfig,
    required String adminEmail,
  }) {
    final riderTrustRules = _map(appConfigData['rider_trust_rules']);
    final cityEnablementConfig = _map(appConfigData['city_enablement']);
    final withdrawalConfig = _map(appConfigData['withdrawals']);
    final cityEnablement = <String, bool>{
      for (final city in pricingConfig.cities)
        city.city.toLowerCase():
            cityEnablementConfig[city.city.toLowerCase()] != false &&
                city.enabled,
    };

    return AdminOperationalSettings(
      withdrawalNoticeText: _firstText(<dynamic>[
        withdrawalConfig['noticeText'],
        withdrawalConfig['notice_text'],
      ], fallback: DriverFinanceService.payoutNoticeText),
      cityEnablement: cityEnablement,
      driverVerificationRequired:
          appConfigData['driverVerificationRequired'] == true ||
              DriverFeatureFlags.driverVerificationRequired,
      activeServiceTypes: DriverFeatureFlags.activeRequestServiceTypes.toList()
        ..sort(),
      offRouteToleranceMeters: _firstInt(<dynamic>[
        riderTrustRules['offRouteToleranceMeters'],
        250,
      ]),
      adminEmail: adminEmail,
      rawData: appConfigData,
    );
  }

  AdminDashboardMetrics _buildDashboardMetrics({
    required List<AdminRiderRecord> riders,
    required List<AdminDriverRecord> drivers,
    required List<AdminTripRecord> trips,
    required List<AdminWithdrawalRecord> withdrawals,
    required List<AdminSubscriptionRecord> subscriptions,
  }) {
    final today = DateTime.now();
    final totalGrossBookings = trips
        .where((AdminTripRecord trip) => trip.status == 'completed')
        .fold<double>(
            0, (double sum, AdminTripRecord trip) => sum + trip.fareAmount);
    final totalCommissions = trips
        .where((AdminTripRecord trip) => trip.status == 'completed')
        .fold<double>(0,
            (double sum, AdminTripRecord trip) => sum + trip.commissionAmount);
    final totalDriverPayouts = trips
        .where((AdminTripRecord trip) => trip.status == 'completed')
        .fold<double>(
            0, (double sum, AdminTripRecord trip) => sum + trip.driverPayout);
    final subscriptionRevenue = subscriptions.fold<double>(0, (
      double sum,
      AdminSubscriptionRecord record,
    ) {
      if (record.paymentStatus != 'paid' &&
          record.status != 'active' &&
          record.status != 'expired') {
        return sum;
      }
      return sum +
          (record.planType == 'weekly'
              ? DriverBusinessConfig.weeklySubscriptionPriceNgn
              : DriverBusinessConfig.monthlySubscriptionPriceNgn);
    });
    final todaysPlatformRevenue = trips
            .where(
              (AdminTripRecord trip) =>
                  trip.status == 'completed' &&
                  _isSameDay(trip.completedAt, today),
            )
            .fold<double>(
                0,
                (double sum, AdminTripRecord trip) =>
                    sum + trip.commissionAmount) +
        subscriptions
            .where((AdminSubscriptionRecord record) =>
                _isSameDay(record.startDate, today))
            .fold<double>(
              0,
              (double sum, AdminSubscriptionRecord record) =>
                  sum +
                  (record.planType == 'weekly'
                      ? DriverBusinessConfig.weeklySubscriptionPriceNgn
                      : DriverBusinessConfig.monthlySubscriptionPriceNgn),
            );
    final pendingWithdrawals = withdrawals
        .where(
          (AdminWithdrawalRecord item) =>
              item.status == 'pending' || item.status == 'processing',
        )
        .fold<double>(
            0, (double sum, AdminWithdrawalRecord item) => sum + item.amount);

    return AdminDashboardMetrics(
      totalRiders: riders.length,
      totalDrivers: drivers.length,
      activeDriversOnline:
          drivers.where((AdminDriverRecord driver) => driver.isOnline).length,
      ongoingTrips: trips
          .where(
            (AdminTripRecord trip) => <String>{
              'assigned',
              'accepted',
              'arrived',
              'started',
            }.contains(trip.status),
          )
          .length,
      completedTrips: trips
          .where((AdminTripRecord trip) => trip.status == 'completed')
          .length,
      cancelledTrips: trips
          .where((AdminTripRecord trip) => trip.status == 'cancelled')
          .length,
      todaysRevenue: todaysPlatformRevenue,
      totalPlatformRevenue: totalCommissions + subscriptionRevenue,
      totalDriverPayouts: totalDriverPayouts,
      pendingWithdrawals: pendingWithdrawals,
      subscriptionDriversCount: drivers
          .where((AdminDriverRecord driver) =>
              driver.monetizationModel == 'subscription')
          .length,
      commissionDriversCount: drivers
          .where((AdminDriverRecord driver) =>
              driver.monetizationModel != 'subscription')
          .length,
      totalGrossBookings: totalGrossBookings,
      totalCommissionsEarned: totalCommissions,
      subscriptionRevenue: subscriptionRevenue,
    );
  }

  List<AdminTrendPoint> _buildTripTrends(List<AdminTripRecord> trips) {
    final now = DateTime.now();
    final points = <AdminTrendPoint>[];
    for (var offset = 6; offset >= 0; offset--) {
      final date = DateTime(now.year, now.month, now.day)
          .subtract(Duration(days: offset));
      final dayTrips = trips
          .where((AdminTripRecord trip) => _isSameDay(trip.createdAt, date));
      points.add(
        AdminTrendPoint(
          label: _weekdayLabel(date.weekday),
          value: dayTrips.length.toDouble(),
          secondaryValue: dayTrips
              .where((AdminTripRecord trip) => trip.status == 'completed')
              .length
              .toDouble(),
          tertiaryValue: dayTrips
              .where((AdminTripRecord trip) => trip.status == 'cancelled')
              .length
              .toDouble(),
        ),
      );
    }
    return points;
  }

  List<AdminTrendPoint> _buildRevenueTrends(
    List<AdminTripRecord> trips,
    List<AdminSubscriptionRecord> subscriptions,
  ) {
    final now = DateTime.now();
    final points = <AdminTrendPoint>[];
    for (var offset = 6; offset >= 0; offset--) {
      final date = DateTime(now.year, now.month, now.day)
          .subtract(Duration(days: offset));
      final dayTrips = trips.where(
        (AdminTripRecord trip) =>
            trip.status == 'completed' && _isSameDay(trip.completedAt, date),
      );
      final daySubscriptionRevenue = subscriptions
          .where((AdminSubscriptionRecord record) =>
              _isSameDay(record.startDate, date))
          .fold<double>(
            0,
            (double sum, AdminSubscriptionRecord record) =>
                sum +
                (record.planType == 'weekly'
                    ? DriverBusinessConfig.weeklySubscriptionPriceNgn
                    : DriverBusinessConfig.monthlySubscriptionPriceNgn),
          );
      points.add(
        AdminTrendPoint(
          label: _weekdayLabel(date.weekday),
          value: dayTrips.fold<double>(
              0, (double sum, AdminTripRecord trip) => sum + trip.fareAmount),
          secondaryValue: dayTrips.fold<double>(
                0,
                (double sum, AdminTripRecord trip) =>
                    sum + trip.commissionAmount,
              ) +
              daySubscriptionRevenue,
          tertiaryValue: dayTrips.fold<double>(
            0,
            (double sum, AdminTripRecord trip) => sum + trip.driverPayout,
          ),
        ),
      );
    }
    return points;
  }

  List<AdminTrendPoint> _buildCityPerformance(List<AdminTripRecord> trips) {
    final buckets = <String, _CityStats>{};
    for (final trip
        in trips.where((AdminTripRecord trip) => trip.status == 'completed')) {
      final city = trip.city.isNotEmpty ? trip.city : 'Unassigned';
      final bucket = buckets.putIfAbsent(city, () => _CityStats());
      bucket.completedTrips += 1;
      bucket.grossBookings += trip.fareAmount;
    }

    final sorted = buckets.entries.toList()
      ..sort(
        (MapEntry<String, _CityStats> a, MapEntry<String, _CityStats> b) =>
            b.value.grossBookings.compareTo(a.value.grossBookings),
      );
    return sorted
        .take(6)
        .map(
          (MapEntry<String, _CityStats> entry) => AdminTrendPoint(
            label: entry.key,
            value: entry.value.grossBookings,
            secondaryValue: entry.value.completedTrips.toDouble(),
          ),
        )
        .toList();
  }

  List<AdminTrendPoint> _buildDriverGrowth(List<AdminDriverRecord> drivers) {
    final now = DateTime.now();
    final points = <AdminTrendPoint>[];
    for (var offset = 5; offset >= 0; offset--) {
      final startOfWeek = DateTime(now.year, now.month, now.day)
          .subtract(Duration(days: now.weekday - 1))
          .subtract(Duration(days: offset * 7));
      final endOfWeek = startOfWeek.add(const Duration(days: 7));
      final count = drivers.where((AdminDriverRecord driver) {
        final createdAt = driver.createdAt;
        return createdAt != null &&
            !createdAt.isBefore(startOfWeek) &&
            createdAt.isBefore(endOfWeek);
      }).length;
      points.add(
        AdminTrendPoint(
          label: '${startOfWeek.month}/${startOfWeek.day}',
          value: count.toDouble(),
        ),
      );
    }
    return points;
  }

  List<AdminTrendPoint> _buildAdoptionBreakdown(
      List<AdminDriverRecord> drivers) {
    final subscriptionCount = drivers
        .where((AdminDriverRecord driver) =>
            driver.monetizationModel == 'subscription')
        .length;
    final commissionCount = drivers.length - subscriptionCount;
    return <AdminTrendPoint>[
      AdminTrendPoint(
          label: 'Subscription', value: subscriptionCount.toDouble()),
      AdminTrendPoint(label: 'Commission', value: commissionCount.toDouble()),
    ];
  }

  List<AdminRevenueSlice> _buildDailyFinanceSlices({
    required List<AdminTripRecord> trips,
    required List<AdminWithdrawalRecord> withdrawals,
    required List<AdminSubscriptionRecord> subscriptions,
  }) {
    final now = DateTime.now();
    return <AdminRevenueSlice>[
      for (var offset = 6; offset >= 0; offset--)
        _buildPeriodFinanceSlice(
          labelDate: DateTime(now.year, now.month, now.day)
              .subtract(Duration(days: offset)),
          trips: trips,
          withdrawals: withdrawals,
          subscriptions: subscriptions,
          granularity: _FinanceGranularity.day,
        ),
    ];
  }

  List<AdminRevenueSlice> _buildWeeklyFinanceSlices({
    required List<AdminTripRecord> trips,
    required List<AdminWithdrawalRecord> withdrawals,
    required List<AdminSubscriptionRecord> subscriptions,
  }) {
    final now = DateTime.now();
    return <AdminRevenueSlice>[
      for (var offset = 5; offset >= 0; offset--)
        _buildPeriodFinanceSlice(
          labelDate: DateTime(now.year, now.month, now.day)
              .subtract(Duration(days: now.weekday - 1))
              .subtract(Duration(days: offset * 7)),
          trips: trips,
          withdrawals: withdrawals,
          subscriptions: subscriptions,
          granularity: _FinanceGranularity.week,
        ),
    ];
  }

  List<AdminRevenueSlice> _buildMonthlyFinanceSlices({
    required List<AdminTripRecord> trips,
    required List<AdminWithdrawalRecord> withdrawals,
    required List<AdminSubscriptionRecord> subscriptions,
  }) {
    final now = DateTime.now();
    return <AdminRevenueSlice>[
      for (var offset = 5; offset >= 0; offset--)
        _buildPeriodFinanceSlice(
          labelDate: DateTime(now.year, now.month - offset, 1),
          trips: trips,
          withdrawals: withdrawals,
          subscriptions: subscriptions,
          granularity: _FinanceGranularity.month,
        ),
    ];
  }

  List<AdminRevenueSlice> _buildCityFinanceSlices({
    required List<AdminTripRecord> trips,
    required List<AdminWithdrawalRecord> withdrawals,
    required List<AdminSubscriptionRecord> subscriptions,
  }) {
    final cityKeys = trips
        .map((AdminTripRecord trip) => trip.city)
        .where((String city) => city.isNotEmpty)
        .toSet()
        .toList()
      ..sort();

    final slices = <AdminRevenueSlice>[];
    for (final city in cityKeys) {
      final cityTrips =
          trips.where((AdminTripRecord trip) => trip.city == city);
      final cityDriverIds =
          cityTrips.map((AdminTripRecord trip) => trip.driverId).toSet();
      final cityWithdrawals = withdrawals.where(
        (AdminWithdrawalRecord withdrawal) =>
            cityDriverIds.contains(withdrawal.driverId),
      );
      final citySubscriptions = subscriptions.where(
        (AdminSubscriptionRecord record) => record.city == city,
      );
      slices.add(
        AdminRevenueSlice(
          label: city,
          grossBookings: cityTrips.fold<double>(
              0, (double sum, AdminTripRecord trip) => sum + trip.fareAmount),
          commissionRevenue: cityTrips.fold<double>(
              0,
              (double sum, AdminTripRecord trip) =>
                  sum + trip.commissionAmount),
          subscriptionRevenue: citySubscriptions.fold<double>(
            0,
            (double sum, AdminSubscriptionRecord record) =>
                sum +
                (record.planType == 'weekly'
                    ? DriverBusinessConfig.weeklySubscriptionPriceNgn
                    : DriverBusinessConfig.monthlySubscriptionPriceNgn),
          ),
          driverPayouts: cityTrips.fold<double>(
              0, (double sum, AdminTripRecord trip) => sum + trip.driverPayout),
          pendingPayouts: cityWithdrawals
              .where(
                (AdminWithdrawalRecord item) =>
                    item.status == 'pending' || item.status == 'processing',
              )
              .fold<double>(
                  0,
                  (double sum, AdminWithdrawalRecord item) =>
                      sum + item.amount),
        ),
      );
    }
    slices.sort((AdminRevenueSlice a, AdminRevenueSlice b) =>
        b.grossBookings.compareTo(a.grossBookings));
    return slices.take(6).toList();
  }

  AdminRevenueSlice _buildPeriodFinanceSlice({
    required DateTime labelDate,
    required List<AdminTripRecord> trips,
    required List<AdminWithdrawalRecord> withdrawals,
    required List<AdminSubscriptionRecord> subscriptions,
    required _FinanceGranularity granularity,
  }) {
    final label = switch (granularity) {
      _FinanceGranularity.day => '${labelDate.month}/${labelDate.day}',
      _FinanceGranularity.week => 'Wk ${labelDate.month}/${labelDate.day}',
      _FinanceGranularity.month =>
        '${_monthShort(labelDate.month)} ${labelDate.year}',
    };

    bool dateMatches(DateTime? value) {
      if (value == null) {
        return false;
      }
      return switch (granularity) {
        _FinanceGranularity.day => value.year == labelDate.year &&
            value.month == labelDate.month &&
            value.day == labelDate.day,
        _FinanceGranularity.week => !value.isBefore(labelDate) &&
            value.isBefore(labelDate.add(const Duration(days: 7))),
        _FinanceGranularity.month =>
          value.year == labelDate.year && value.month == labelDate.month,
      };
    }

    final periodTrips = trips.where(
      (AdminTripRecord trip) =>
          trip.status == 'completed' && dateMatches(trip.completedAt),
    );
    final periodWithdrawals = withdrawals.where(
      (AdminWithdrawalRecord withdrawal) =>
          dateMatches(withdrawal.requestDate) &&
          (withdrawal.status == 'pending' || withdrawal.status == 'processing'),
    );
    final periodSubscriptions = subscriptions.where(
      (AdminSubscriptionRecord subscription) =>
          dateMatches(subscription.startDate),
    );

    return AdminRevenueSlice(
      label: label,
      grossBookings: periodTrips.fold<double>(
          0, (double sum, AdminTripRecord trip) => sum + trip.fareAmount),
      commissionRevenue: periodTrips.fold<double>(
          0, (double sum, AdminTripRecord trip) => sum + trip.commissionAmount),
      subscriptionRevenue: periodSubscriptions.fold<double>(
        0,
        (double sum, AdminSubscriptionRecord record) =>
            sum +
            (record.planType == 'weekly'
                ? DriverBusinessConfig.weeklySubscriptionPriceNgn
                : DriverBusinessConfig.monthlySubscriptionPriceNgn),
      ),
      driverPayouts: periodTrips.fold<double>(
          0, (double sum, AdminTripRecord trip) => sum + trip.driverPayout),
      pendingPayouts: periodWithdrawals.fold<double>(
          0, (double sum, AdminWithdrawalRecord item) => sum + item.amount),
    );
  }

  Map<String, AdminTripSummary> _computeRiderTripStats(
      List<AdminTripRecord> trips) {
    final stats = <String, _TripSummaryAccumulator>{};
    for (final trip in trips) {
      if (trip.riderId.isEmpty) {
        continue;
      }
      final item =
          stats.putIfAbsent(trip.riderId, () => _TripSummaryAccumulator());
      item.totalTrips += 1;
      if (trip.status == 'completed') {
        item.completedTrips += 1;
      }
      if (trip.status == 'cancelled') {
        item.cancelledTrips += 1;
      }
    }
    return <String, AdminTripSummary>{
      for (final entry in stats.entries)
        entry.key: AdminTripSummary(
          totalTrips: entry.value.totalTrips,
          completedTrips: entry.value.completedTrips,
          cancelledTrips: entry.value.cancelledTrips,
        ),
    };
  }

  Map<String, _DriverTripStats> _computeDriverTripStats(
      List<AdminTripRecord> trips) {
    final stats = <String, _DriverTripStats>{};
    for (final trip in trips) {
      if (trip.driverId.isEmpty) {
        continue;
      }
      final item = stats.putIfAbsent(trip.driverId, () => _DriverTripStats());
      item.totalTrips += 1;
      if (trip.status == 'completed') {
        item.completedTrips += 1;
        item.grossBookings += trip.fareAmount;
        item.driverPayouts += trip.driverPayout;
      }
    }
    return stats;
  }

  void _walkWithdrawals({
    required Map<String, dynamic> data,
    required String currentPath,
    required void Function(String path, Map<String, dynamic> record) onRecord,
  }) {
    if (data.isEmpty) {
      return;
    }
    if (_looksLikeWithdrawalRecord(data)) {
      onRecord(currentPath, data);
      return;
    }

    for (final entry in data.entries) {
      if (entry.value is! Map) {
        continue;
      }
      _walkWithdrawals(
        data: _map(entry.value),
        currentPath: '$currentPath/${entry.key}',
        onRecord: onRecord,
      );
    }
  }

  bool _looksLikeWithdrawalRecord(Map<String, dynamic> record) {
    return record.keys.any(
      (String key) => <String>{
        'withdrawalId',
        'amount',
        'status',
        'driverId',
        'driver_id',
      }.contains(key),
    );
  }

  Map<String, dynamic> _map(dynamic value) {
    if (value is Map) {
      return value.map<String, dynamic>(
        (dynamic key, dynamic entry) => MapEntry(key.toString(), entry),
      );
    }
    return <String, dynamic>{};
  }

  List<String> _stringList(dynamic value) {
    if (value is List) {
      return value
          .map((dynamic entry) => entry.toString().trim())
          .where((String entry) => entry.isNotEmpty)
          .toList();
    }
    return const <String>[];
  }

  String _text(dynamic value) => value?.toString().trim() ?? '';

  String _firstText(List<dynamic> values, {String fallback = ''}) {
    for (final value in values) {
      final resolved = _text(value);
      if (resolved.isNotEmpty) {
        return resolved;
      }
    }
    return fallback;
  }

  int _firstInt(List<dynamic> values) {
    for (final value in values) {
      if (value is int) {
        return value;
      }
      if (value is num) {
        return value.toInt();
      }
      final parsed = int.tryParse(_text(value));
      if (parsed != null) {
        return parsed;
      }
    }
    return 0;
  }

  double _firstPositiveDouble(List<dynamic> values) {
    for (final value in values) {
      final parsed = _doubleValue(value);
      if (parsed > 0) {
        return parsed;
      }
    }
    return 0;
  }

  double? _firstAvailableDoubleOrNull(List<dynamic> values) {
    for (final value in values) {
      if (value == null) {
        continue;
      }
      if (value is String && value.trim().isEmpty) {
        continue;
      }
      final parsed = _doubleOrNull(value);
      if (parsed != null) {
        return parsed;
      }
    }
    return null;
  }

  double _doubleValue(dynamic value) {
    return _doubleOrNull(value) ?? 0;
  }

  double? _doubleOrNull(dynamic value) {
    if (value is double) {
      return value;
    }
    if (value is int) {
      return value.toDouble();
    }
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(_text(value));
  }

  DateTime? _dateFromCandidates(List<dynamic> values) {
    for (final value in values) {
      final resolved = _dateFromValue(value);
      if (resolved != null) {
        return resolved;
      }
    }
    return null;
  }

  DateTime? _dateFromValue(dynamic value) {
    if (value == null) {
      return null;
    }
    try {
      final dynamic ts = value;
      final asDate = ts.toDate();
      if (asDate is DateTime) {
        return asDate.toLocal();
      }
    } catch (_) {}
    if (value is DateTime) {
      return value.toLocal();
    }
    if (value is int) {
      return DateTime.fromMillisecondsSinceEpoch(value).toLocal();
    }
    if (value is double) {
      return DateTime.fromMillisecondsSinceEpoch(value.round()).toLocal();
    }
    final asText = _text(value);
    final asInt = int.tryParse(asText);
    if (asInt != null) {
      return DateTime.fromMillisecondsSinceEpoch(asInt).toLocal();
    }
    return DateTime.tryParse(asText)?.toLocal();
  }

  String _normalizeSettlementStatus(String status) {
    return switch (status.trim().toLowerCase()) {
      'completed' || 'trip_completed' => 'completed',
      'payment_review' => 'payment_review',
      'failed' => 'failed',
      'reversed' || 'reversal' || 'trip_reversed' => 'reversed',
      '' || 'none' || 'not_applicable' || 'cancelled' || 'canceled' => 'none',
      _ => status.trim().toLowerCase(),
    };
  }

  bool _tripHasSettlementArtifacts({
    required Map<String, dynamic> settlementContext,
    required Map<String, dynamic> mergedSettlement,
    required double? commissionAmount,
    required double? payoutAmount,
  }) {
    return settlementContext.isNotEmpty ||
        mergedSettlement.isNotEmpty ||
        (commissionAmount ?? 0) > 0 ||
        (payoutAmount ?? 0) > 0;
  }

  String _normalizeTripSettlementStatus({
    required String tripStatus,
    required String rawSettlementStatus,
    required Map<String, dynamic> settlementContext,
    required Map<String, dynamic> mergedSettlement,
    required double? commissionAmount,
    required double? payoutAmount,
  }) {
    final normalizedSettlementStatus =
        _normalizeSettlementStatus(rawSettlementStatus);
    if (tripStatus == 'completed') {
      if (normalizedSettlementStatus == 'payment_review' ||
          normalizedSettlementStatus == 'failed') {
        return normalizedSettlementStatus;
      }
      return 'completed';
    }

    if (tripStatus == 'cancelled') {
      if (normalizedSettlementStatus == 'reversed' ||
          normalizedSettlementStatus == 'none') {
        return normalizedSettlementStatus;
      }
      return _tripHasSettlementArtifacts(
        settlementContext: settlementContext,
        mergedSettlement: mergedSettlement,
        commissionAmount: commissionAmount,
        payoutAmount: payoutAmount,
      )
          ? 'reversed'
          : 'none';
    }

    return normalizedSettlementStatus;
  }

  bool _tripHasValidMonetizedSettlement({
    required String tripStatus,
    required String settlementStatus,
  }) {
    if (tripStatus != 'completed') {
      return false;
    }

    return settlementStatus == 'completed' ||
        settlementStatus == 'payment_review';
  }

  String _normalizeCancellationReason(String value) {
    return switch (value.trim().toLowerCase()) {
      'rider_cancel' ||
      'rider_cancelled' ||
      'user_cancelled' =>
        'user_cancelled',
      'driver_cancel' || 'driver_cancelled' => 'driver_cancelled',
      'driver_start_timeout' ||
      'assignment_timeout' ||
      'timeout' ||
      'system_start_timeout' =>
        'timeout',
      'no_route_logs' ||
      'system_invalid_trip_no_route_logs' ||
      'system_route_log_timeout' =>
        'no_route_logs',
      'system_search_timeout' => 'no_drivers_available',
      'driver_offline' ||
      'driver_status_offline' ||
      'driver_session_lost' =>
        'driver_offline',
      'no_drivers_available' => 'no_drivers_available',
      _ => value.trim().toLowerCase(),
    };
  }

  String _tripCancellationReason({
    required Map<String, dynamic> trip,
    required Map<String, dynamic> routeLog,
  }) {
    return _normalizeCancellationReason(
      _firstText(<dynamic>[
        trip['cancel_reason'],
        trip['cancelReason'],
        trip['trip_invalid_reason'],
        trip['cancel_source'],
        routeLog['cancel_reason'],
        routeLog['cancelReason'],
      ]),
    );
  }

  String _normalizeTripStatus(String status) {
    return switch (status.trim().toLowerCase()) {
      'searching' || 'requested' || 'pending' => 'requested',
      'driver_found' || 'assigned' => 'assigned',
      'accepted' => 'accepted',
      'arrived' || 'arriving' => 'arrived',
      'on_trip' || 'trip_started' || 'started' => 'started',
      'completed' ||
      'trip_completed' ||
      'completed_with_payment_issue' =>
        'completed',
      'cancelled' || 'canceled' || 'declined' => 'cancelled',
      _ => status.trim().toLowerCase().isEmpty
          ? 'requested'
          : status.trim().toLowerCase(),
    };
  }

  String _normalizeWithdrawalStatus(String status) {
    return switch (status.trim().toLowerCase()) {
      'pending' || 'requested' || 'submitted' => 'pending',
      'processing' || 'in_progress' => 'processing',
      'paid' || 'processed' || 'completed' || 'success' => 'paid',
      'failed' || 'rejected' || 'cancelled' => 'failed',
      _ => status.trim().toLowerCase().isEmpty
          ? 'pending'
          : status.trim().toLowerCase(),
    };
  }

  String _normalizeServiceType(String value) {
    final normalized = value.trim().toLowerCase();
    return switch (normalized) {
      '' => 'ride',
      'dispatch_delivery' => 'dispatch_delivery',
      'groceries_mart' => 'groceries_mart',
      'restaurants_food' => 'restaurants_food',
      _ => 'ride',
    };
  }

  String _resolveTripCity(Map<String, dynamic> trip) {
    return _firstText(<dynamic>[
      trip['city'],
      trip['pickup_city'],
      trip['pickupCity'],
      trip['driver_city'],
      trip['rider_city'],
      _inferCityFromText(_firstText(<dynamic>[
        trip['pickup_address'],
        trip['destination_address'],
      ])),
    ]);
  }

  String _inferCityFromText(String value) {
    final normalized = value.toLowerCase();
    if (normalized.contains('lagos')) {
      return 'Lagos';
    }
    if (normalized.contains('abuja')) {
      return 'Abuja';
    }
    return '';
  }

  double _resolveDistanceKm(Map<String, dynamic> trip) {
    final distanceKm = _firstPositiveDouble(<dynamic>[
      trip['distance_km'],
      trip['distanceKm'],
      trip['estimatedDistanceKm'],
    ]);
    if (distanceKm > 0) {
      return distanceKm;
    }
    final meters = _firstPositiveDouble(<dynamic>[
      trip['distance_meters'],
      trip['distanceMeters'],
    ]);
    if (meters > 0) {
      return meters / 1000;
    }
    return 0;
  }

  double _resolveDurationMinutes(Map<String, dynamic> trip) {
    final minutes = _firstPositiveDouble(<dynamic>[
      trip['duration_minutes'],
      trip['durationMinutes'],
      trip['estimatedDurationMinutes'],
    ]);
    if (minutes > 0) {
      return minutes;
    }
    final seconds = _firstPositiveDouble(<dynamic>[
      trip['duration_seconds'],
      trip['durationSeconds'],
    ]);
    if (seconds > 0) {
      return seconds / 60;
    }
    return 0;
  }

  String _paymentMethodLabel(String value) {
    final normalized = value.trim().toLowerCase();
    return switch (normalized) {
      'cash' => 'In-app',
      'card' => 'Card',
      'flutterwave' => 'Flutterwave',
      'bank_transfer' => 'Bank transfer',
      '' => 'Unspecified',
      _ => _titleCase(normalized.replaceAll('_', ' ')),
    };
  }

  String _titleCase(String value) {
    if (value.trim().isEmpty) {
      return '';
    }
    return value
        .split(' ')
        .where((String part) => part.isNotEmpty)
        .map(
          (String part) =>
              '${part[0].toUpperCase()}${part.substring(1).toLowerCase()}',
        )
        .join(' ');
  }

  bool _isSameDay(DateTime? a, DateTime b) {
    return a != null &&
        a.year == b.year &&
        a.month == b.month &&
        a.day == b.day;
  }

  String _weekdayLabel(int weekday) {
    return switch (weekday) {
      DateTime.monday => 'Mon',
      DateTime.tuesday => 'Tue',
      DateTime.wednesday => 'Wed',
      DateTime.thursday => 'Thu',
      DateTime.friday => 'Fri',
      DateTime.saturday => 'Sat',
      _ => 'Sun',
    };
  }

  String _monthShort(int month) {
    return switch (month) {
      1 => 'Jan',
      2 => 'Feb',
      3 => 'Mar',
      4 => 'Apr',
      5 => 'May',
      6 => 'Jun',
      7 => 'Jul',
      8 => 'Aug',
      9 => 'Sep',
      10 => 'Oct',
      11 => 'Nov',
      _ => 'Dec',
    };
  }

  bool _isPermissionDenied(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('permission-denied') ||
        message.contains('permission denied');
  }

  String _normalizedSubscriptionPlanKind({
    required Map<String, dynamic> subscription,
    required Map<String, dynamic> driver,
  }) {
    final raw = _firstText(<dynamic>[
      subscription['planType'],
      driver['subscription_type'],
    ], fallback: 'monthly');
    final lower = raw.toLowerCase().trim();
    return lower == 'weekly' || lower.contains('week')
        ? 'weekly'
        : 'monthly';
  }

  bool _boolish(dynamic value) {
    if (value is bool) {
      return value;
    }
    final normalized = _text(value).toLowerCase();
    return normalized == 'true' || normalized == '1' || normalized == 'yes';
  }
}

class AdminDataSourceException implements Exception {
  const AdminDataSourceException({
    required this.path,
    required this.reason,
    this.cause,
  });

  final String path;
  final String reason;
  final Object? cause;

  @override
  String toString() {
    return 'Admin data source "$path" failed ($reason). ${cause ?? ''}'.trim();
  }
}

enum _FinanceGranularity { day, week, month }

class _TripSummaryAccumulator {
  int totalTrips = 0;
  int completedTrips = 0;
  int cancelledTrips = 0;
}

class _DriverTripStats {
  int totalTrips = 0;
  int completedTrips = 0;
  double grossBookings = 0;
  double driverPayouts = 0;
}

class _CityStats {
  int completedTrips = 0;
  double grossBookings = 0;
}

class _WithdrawalAccumulator {
  _WithdrawalAccumulator({
    required this.id,
    required this.driverId,
    required String path,
    required Map<String, dynamic> rawData,
  })  : sourcePaths = <String>{path},
        rawData = Map<String, dynamic>.from(rawData);

  final String id;
  final String driverId;
  final Set<String> sourcePaths;
  final Map<String, dynamic> rawData;

  @override
  bool operator ==(Object other) {
    return other is _WithdrawalAccumulator &&
        other.id == id &&
        other.driverId == driverId;
  }

  @override
  int get hashCode => Object.hash(id, driverId);
}

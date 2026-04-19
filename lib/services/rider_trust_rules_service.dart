import 'package:firebase_database/firebase_database.dart' as rtdb;

import '../config/rider_app_config.dart';
import '../support/rider_trust_support.dart';
import '../support/startup_rtdb_support.dart';

class RiderTrustAccessDecision {
  const RiderTrustAccessDecision({
    required this.canRequestTrips,
    required this.canUseCash,
    required this.restrictionCode,
    required this.message,
  });

  final bool canRequestTrips;
  final bool canUseCash;
  final String restrictionCode;
  final String message;

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'canRequestTrips': canRequestTrips,
      'canUseCash': canUseCash,
      'restrictionCode': restrictionCode,
      'message': message,
    };
  }
}

class RiderTrustRulesService {
  const RiderTrustRulesService();

  rtdb.DatabaseReference get _rootRef => rtdb.FirebaseDatabase.instance.ref();

  static const Map<String, dynamic> _defaultRules = <String, dynamic>{
    'cancellationFeeNgn': kDefaultCancellationFeeNgn,
    'backToBackCancellationThreshold': 5,
    'watchlistCancellationThreshold': 3,
    'unpaidCancellationFeeBlocksTripRequests': true,
    'cashRequiresVerifiedIdentity': false,
    'nonPaymentRestrictionThreshold': 2,
    'seriousSafetyWatchlistThreshold': 1,
    'seriousSafetySuspensionThreshold': 2,
    'offRouteToleranceMeters': 250,
    'offRouteStrikeThreshold': 3,
    'telemetryCheckpointMinDistanceMeters': 120,
    'telemetryCheckpointMinSeconds': 45,
  };

  static Map<String, dynamic> get defaultRules =>
      Map<String, dynamic>.from(_defaultRules);

  Future<Map<String, dynamic>> fetchRules() async {
    final snapshot = await runOptionalStartupRead<rtdb.DataSnapshot>(
      source: 'rider_trust_rules.fetch_rules',
      path: 'app_config/rider_trust_rules',
      action: () => _rootRef.child('app_config/rider_trust_rules').get(),
    );
    if (snapshot == null || !snapshot.exists || snapshot.value is! Map) {
      return defaultRules;
    }

    try {
      final merged = <String, dynamic>{
        ..._defaultRules,
        ...Map<String, dynamic>.from(snapshot.value as Map),
      };
      return merged;
    } catch (_) {
      return defaultRules;
    }
  }

  RiderTrustAccessDecision evaluateAccess({
    required Map<String, dynamic> verification,
    required Map<String, dynamic> riskFlags,
    required Map<String, dynamic> paymentFlags,
    required Map<String, dynamic> rules,
  }) {
    final verificationStatus =
        verification['overallStatus']?.toString() ?? 'unverified';
    final riskStatus = riskFlags['status']?.toString() ?? 'clear';
    final outstandingFees =
        paymentFlags['outstandingCancellationFeesNgn'] is num
        ? (paymentFlags['outstandingCancellationFeesNgn'] as num).toInt()
        : int.tryParse(
                paymentFlags['outstandingCancellationFeesNgn']?.toString() ??
                    '',
              ) ??
              0;

    final cashRequiresVerified = rules['cashRequiresVerifiedIdentity'] == true;
    final verified = verificationStatus == 'verified';
    final canUseCash =
        !RiderFeatureFlags.disableCashTripPayments &&
        paymentFlags['cashAllowed'] != false &&
        (!cashRequiresVerified || verified);
    final restrictionsEnabled = RiderFeatureFlags.enableRiderRestrictions;

    if (!restrictionsEnabled) {
      if (!canUseCash) {
        return const RiderTrustAccessDecision(
          canRequestTrips: true,
          canUseCash: false,
          restrictionCode: 'cash_restricted',
          message:
              'Cash payment access is restricted for this account right now.',
        );
      }
      return const RiderTrustAccessDecision(
        canRequestTrips: true,
        canUseCash: true,
        restrictionCode: '',
        message: '',
      );
    }

    if (riskStatus == 'blacklisted') {
      return const RiderTrustAccessDecision(
        canRequestTrips: false,
        canUseCash: false,
        restrictionCode: 'blacklisted_account',
        message:
            'Your rider account is blacklisted and cannot request trips right now.',
      );
    }

    if (riskStatus == 'suspended') {
      return const RiderTrustAccessDecision(
        canRequestTrips: false,
        canUseCash: false,
        restrictionCode: 'suspended_account',
        message:
            'Your rider account is temporarily suspended while trust and safety checks are reviewed.',
      );
    }

    if (RiderFeatureFlags.enableCancellationFeeBlocking &&
        outstandingFees > 0 &&
        rules['unpaidCancellationFeeBlocksTripRequests'] == true) {
      return RiderTrustAccessDecision(
        canRequestTrips: false,
        canUseCash: false,
        restrictionCode: 'unpaid_cancellation_fee',
        message:
            'You have an outstanding cancellation fee of NGN $outstandingFees. Clear it before requesting another trip.',
      );
    }

    if (riskStatus == 'restricted') {
      return const RiderTrustAccessDecision(
        canRequestTrips: false,
        canUseCash: false,
        restrictionCode: 'restricted_account',
        message:
            'Your rider account has temporary restrictions while recent activity is reviewed.',
      );
    }

    if (riskStatus == 'watchlist') {
      return RiderTrustAccessDecision(
        canRequestTrips: true,
        canUseCash: canUseCash,
        restrictionCode: 'watchlist',
        message:
            'Your account is on a watchlist. Please avoid repeated cancellations or payment issues.',
      );
    }

    if (!canUseCash) {
      return const RiderTrustAccessDecision(
        canRequestTrips: true,
        canUseCash: false,
        restrictionCode: 'cash_restricted',
        message:
            'Cash payment access is restricted for this account right now.',
      );
    }

    return const RiderTrustAccessDecision(
      canRequestTrips: true,
      canUseCash: true,
      restrictionCode: '',
      message: '',
    );
  }

  Future<RiderTrustAccessDecision> evaluateForRider(String riderId) async {
    final rules = await fetchRules();
    final userSnapshot = await runOptionalStartupRead<rtdb.DataSnapshot>(
      source: 'rider_trust_rules.evaluate.user',
      path: 'users/$riderId',
      action: () => _rootRef.child('users/$riderId').get(),
    );
    final riskSnapshot = await runOptionalStartupRead<rtdb.DataSnapshot>(
      source: 'rider_trust_rules.evaluate.risk_flags',
      path: 'rider_risk_flags/$riderId',
      action: () => _rootRef.child('rider_risk_flags/$riderId').get(),
    );
    final paymentSnapshot = await runOptionalStartupRead<rtdb.DataSnapshot>(
      source: 'rider_trust_rules.evaluate.payment_flags',
      path: 'rider_payment_flags/$riderId',
      action: () => _rootRef.child('rider_payment_flags/$riderId').get(),
    );

    final userProfile = userSnapshot?.value is Map
        ? Map<String, dynamic>.from(userSnapshot!.value as Map)
        : <String, dynamic>{};
    final verification = buildRiderVerificationDefaults(
      userProfile['verification'],
    );
    final riskFlags = buildRiderRiskFlagsDefaults(riskSnapshot?.value);
    final paymentFlags = buildRiderPaymentFlagsDefaults(
      paymentSnapshot?.value,
      cancellationFeeNgn: _asRuleInt(
        rules['cancellationFeeNgn'],
        kDefaultCancellationFeeNgn,
      ),
    );

    return evaluateAccess(
      verification: verification,
      riskFlags: riskFlags,
      paymentFlags: paymentFlags,
      rules: rules,
    );
  }

  Future<void> recordRideCancellation({
    required String riderId,
    required String rideId,
    required String serviceType,
    required String statusBeforeCancel,
    String? driverId,
  }) async {
    final rules = await fetchRules();
    final snapshots =
        await Future.wait<rtdb.DataSnapshot>(<Future<rtdb.DataSnapshot>>[
          _rootRef.child('users/$riderId').get(),
          _rootRef.child('rider_risk_flags/$riderId').get(),
          _rootRef.child('rider_payment_flags/$riderId').get(),
          _rootRef.child('rider_reputation/$riderId').get(),
        ]);

    final userProfile = snapshots[0].value is Map
        ? Map<String, dynamic>.from(snapshots[0].value as Map)
        : <String, dynamic>{};
    final verification = buildRiderVerificationDefaults(
      userProfile['verification'],
    );
    final riskFlags = buildRiderRiskFlagsDefaults(snapshots[1].value);
    final paymentFlags = buildRiderPaymentFlagsDefaults(
      snapshots[2].value,
      cancellationFeeNgn: _asRuleInt(
        rules['cancellationFeeNgn'],
        kDefaultCancellationFeeNgn,
      ),
    );
    final reputation = buildRiderReputationDefaults(snapshots[3].value);

    final cancellationFee = _asRuleInt(
      rules['cancellationFeeNgn'],
      kDefaultCancellationFeeNgn,
    );
    final threshold = _asRuleInt(rules['backToBackCancellationThreshold'], 5);
    final watchlistThreshold = _asRuleInt(
      rules['watchlistCancellationThreshold'],
      3,
    );
    final assignedDriver =
        (driverId?.trim().isNotEmpty ?? false) && driverId != 'waiting';
    final chargeFee =
        assignedDriver ||
        statusBeforeCancel == 'accepted' ||
        statusBeforeCancel == 'arrived';
    final noShow = statusBeforeCancel == 'arrived';

    final nextRisk = <String, dynamic>{
      ...riskFlags,
      'riderId': riderId,
      'backToBackCancellations':
          (riskFlags['backToBackCancellations'] as int) + 1,
      'totalCancellations': (riskFlags['totalCancellations'] as int) + 1,
      'noShowCount': (riskFlags['noShowCount'] as int) + (noShow ? 1 : 0),
      'updatedAt': rtdb.ServerValue.timestamp,
    };
    final nextPayment = <String, dynamic>{
      ...paymentFlags,
      'riderId': riderId,
      'outstandingCancellationFeesNgn':
          (paymentFlags['outstandingCancellationFeesNgn'] as int) +
          (chargeFee ? cancellationFee : 0),
      'unpaidCancellationCount':
          (paymentFlags['unpaidCancellationCount'] as int) +
          (chargeFee ? 1 : 0),
      'lastFeeAppliedAt': chargeFee
          ? rtdb.ServerValue.timestamp
          : paymentFlags['lastFeeAppliedAt'],
      'updatedAt': rtdb.ServerValue.timestamp,
    };
    final nextReputation = <String, dynamic>{
      ...reputation,
      'riderId': riderId,
      'cancellationCount': (reputation['cancellationCount'] as int) + 1,
      'backToBackCancellations':
          (reputation['backToBackCancellations'] as int) + 1,
      'noShowCount': (reputation['noShowCount'] as int) + (noShow ? 1 : 0),
      'updatedAt': rtdb.ServerValue.timestamp,
    };

    nextRisk['activeFlags'] = _upsertFlag(
      existing: nextRisk['activeFlags'] as List<dynamic>,
      code: chargeFee ? 'unpaid_cancellation_fee' : 'rider_cancellation',
      severity: chargeFee ? 'restricted' : 'watchlist',
      message: chargeFee
          ? 'Outstanding cancellation fee recorded for ride $rideId.'
          : 'Cancellation recorded for ride $rideId.',
    );

    if ((nextRisk['backToBackCancellations'] as int) >= threshold) {
      nextRisk['activeFlags'] = _upsertFlag(
        existing: nextRisk['activeFlags'] as List<dynamic>,
        code: 'excessive_cancellation_pattern',
        severity: 'watchlist',
        message: 'Back-to-back cancellations passed the configured threshold.',
      );
    } else if ((nextRisk['backToBackCancellations'] as int) >=
        watchlistThreshold) {
      nextRisk['activeFlags'] = _upsertFlag(
        existing: nextRisk['activeFlags'] as List<dynamic>,
        code: 'cancellation_watchlist',
        severity: 'watchlist',
        message:
            'Cancellation pattern is approaching the configured threshold.',
      );
    }

    nextRisk['status'] = _deriveRiskStatus(
      riskFlags: nextRisk,
      paymentFlags: nextPayment,
      rules: rules,
    );
    nextRisk['result'] = nextRisk['status'];
    nextPayment['status'] =
        (nextPayment['outstandingCancellationFeesNgn'] as int) > 0
        ? 'restricted'
        : 'clear';
    nextPayment['tripRequestAccess'] =
        (nextPayment['outstandingCancellationFeesNgn'] as int) > 0
        ? 'blocked'
        : 'enabled';
    nextPayment['cashAllowed'] =
        (nextRisk['status'] == 'restricted' ||
            nextRisk['status'] == 'suspended' ||
            nextRisk['status'] == 'blacklisted')
        ? false
        : paymentFlags['cashAllowed'];
    nextPayment['cashAccessStatus'] = nextPayment['cashAllowed'] == false
        ? 'restricted'
        : 'enabled';

    final decision = evaluateAccess(
      verification: verification,
      riskFlags: nextRisk,
      paymentFlags: nextPayment,
      rules: rules,
    );
    final trustSummary = buildRiderTrustSummary(
      verification: verification,
      riskFlags: nextRisk,
      paymentFlags: nextPayment,
      reputation: nextReputation,
      accessDecision: decision.toMap(),
    );

    await _rootRef.update(<String, dynamic>{
      'rider_risk_flags/$riderId': nextRisk,
      'rider_payment_flags/$riderId': nextPayment,
      'rider_reputation/$riderId': nextReputation,
      'users/$riderId/trustSummary': trustSummary,
      'trip_route_logs/$rideId/cancellation': <String, dynamic>{
        'rideId': rideId,
        'riderId': riderId,
        'serviceType': serviceType,
        'statusBeforeCancel': statusBeforeCancel,
        'cancellationFeeNgn': chargeFee ? cancellationFee : 0,
        'createdAt': rtdb.ServerValue.timestamp,
      },
    });
  }

  Future<void> recordTripCompletion({required String riderId}) async {
    final snapshots =
        await Future.wait<rtdb.DataSnapshot>(<Future<rtdb.DataSnapshot>>[
          _rootRef.child('users/$riderId').get(),
          _rootRef.child('rider_risk_flags/$riderId').get(),
          _rootRef.child('rider_payment_flags/$riderId').get(),
          _rootRef.child('rider_reputation/$riderId').get(),
        ]);

    final userProfile = snapshots[0].value is Map
        ? Map<String, dynamic>.from(snapshots[0].value as Map)
        : <String, dynamic>{};
    final verification = buildRiderVerificationDefaults(
      userProfile['verification'],
    );
    final riskFlags = buildRiderRiskFlagsDefaults(snapshots[1].value);
    final paymentFlags = buildRiderPaymentFlagsDefaults(snapshots[2].value);
    final reputation = buildRiderReputationDefaults(snapshots[3].value);
    final rules = await fetchRules();

    final nextRisk = <String, dynamic>{
      ...riskFlags,
      'riderId': riderId,
      'backToBackCancellations': 0,
      'updatedAt': rtdb.ServerValue.timestamp,
    };
    final nextReputation = <String, dynamic>{
      ...reputation,
      'riderId': riderId,
      'completedTrips': (reputation['completedTrips'] as int) + 1,
      'backToBackCancellations': 0,
      'updatedAt': rtdb.ServerValue.timestamp,
    };

    nextRisk['status'] = _deriveRiskStatus(
      riskFlags: nextRisk,
      paymentFlags: paymentFlags,
      rules: rules,
    );
    nextRisk['result'] = nextRisk['status'];

    final decision = evaluateAccess(
      verification: verification,
      riskFlags: nextRisk,
      paymentFlags: paymentFlags,
      rules: rules,
    );
    final trustSummary = buildRiderTrustSummary(
      verification: verification,
      riskFlags: nextRisk,
      paymentFlags: paymentFlags,
      reputation: nextReputation,
      accessDecision: decision.toMap(),
    );

    await _rootRef.update(<String, dynamic>{
      'rider_risk_flags/$riderId': nextRisk,
      'rider_reputation/$riderId': nextReputation,
      'users/$riderId/trustSummary': trustSummary,
    });
  }

  Future<void> recordDriverReportImpact({
    required String riderId,
    required String reason,
  }) async {
    final rules = await fetchRules();
    final snapshots =
        await Future.wait<rtdb.DataSnapshot>(<Future<rtdb.DataSnapshot>>[
          _rootRef.child('users/$riderId').get(),
          _rootRef.child('rider_risk_flags/$riderId').get(),
          _rootRef.child('rider_payment_flags/$riderId').get(),
          _rootRef.child('rider_reputation/$riderId').get(),
        ]);

    final userProfile = snapshots[0].value is Map
        ? Map<String, dynamic>.from(snapshots[0].value as Map)
        : <String, dynamic>{};
    final verification = buildRiderVerificationDefaults(
      userProfile['verification'],
    );
    final riskFlags = buildRiderRiskFlagsDefaults(snapshots[1].value);
    final paymentFlags = buildRiderPaymentFlagsDefaults(snapshots[2].value);
    final reputation = buildRiderReputationDefaults(snapshots[3].value);

    final nextRisk = <String, dynamic>{
      ...riskFlags,
      'riderId': riderId,
      'updatedAt': rtdb.ServerValue.timestamp,
    };
    final nextPayment = <String, dynamic>{
      ...paymentFlags,
      'riderId': riderId,
      'updatedAt': rtdb.ServerValue.timestamp,
    };
    final nextReputation = <String, dynamic>{
      ...reputation,
      'riderId': riderId,
      'updatedAt': rtdb.ServerValue.timestamp,
    };

    switch (reason) {
      case 'non-payment':
        nextRisk['nonPaymentReports'] =
            (riskFlags['nonPaymentReports'] as int) + 1;
        nextReputation['nonPaymentReports'] =
            (reputation['nonPaymentReports'] as int) + 1;
        nextPayment['cashAllowed'] = false;
        nextPayment['cashAccessStatus'] = 'restricted';
        nextRisk['activeFlags'] = _upsertFlag(
          existing: riskFlags['activeFlags'] as List<dynamic>,
          code: 'driver_non_payment_report',
          severity: 'restricted',
          message: 'A driver submitted a non-payment report for this rider.',
        );
        break;
      case 'abuse':
      case 'safety concern':
      case 'off-route coercion':
        nextRisk['seriousSafetyReports'] =
            (riskFlags['seriousSafetyReports'] as int) + 1;
        nextReputation['seriousSafetyReports'] =
            (reputation['seriousSafetyReports'] as int) + 1;
        nextRisk['activeFlags'] = _upsertFlag(
          existing: riskFlags['activeFlags'] as List<dynamic>,
          code: 'serious_driver_safety_report',
          severity: 'watchlist',
          message: 'A safety-related report was submitted by a driver.',
        );
        break;
      default:
        nextRisk['abuseReports'] = (riskFlags['abuseReports'] as int) + 1;
        nextRisk['activeFlags'] = _upsertFlag(
          existing: riskFlags['activeFlags'] as List<dynamic>,
          code: 'driver_behavior_report',
          severity: 'watchlist',
          message: 'A driver submitted a rider report for review.',
        );
        break;
    }

    nextRisk['status'] = _deriveRiskStatus(
      riskFlags: nextRisk,
      paymentFlags: nextPayment,
      rules: rules,
    );
    nextRisk['result'] = nextRisk['status'];
    nextPayment['status'] = nextPayment['cashAllowed'] == false
        ? 'restricted'
        : nextPayment['status'];

    final decision = evaluateAccess(
      verification: verification,
      riskFlags: nextRisk,
      paymentFlags: nextPayment,
      rules: rules,
    );
    final trustSummary = buildRiderTrustSummary(
      verification: verification,
      riskFlags: nextRisk,
      paymentFlags: nextPayment,
      reputation: nextReputation,
      accessDecision: decision.toMap(),
    );

    await _rootRef.update(<String, dynamic>{
      'rider_risk_flags/$riderId': nextRisk,
      'rider_payment_flags/$riderId': nextPayment,
      'rider_reputation/$riderId': nextReputation,
      'users/$riderId/trustSummary': trustSummary,
    });
  }

  int _asRuleInt(dynamic value, int fallback) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }

  String _deriveRiskStatus({
    required Map<String, dynamic> riskFlags,
    required Map<String, dynamic> paymentFlags,
    required Map<String, dynamic> rules,
  }) {
    final outstandingFees =
        paymentFlags['outstandingCancellationFeesNgn'] as int;
    final backToBackCancellations = riskFlags['backToBackCancellations'] as int;
    final nonPaymentReports = riskFlags['nonPaymentReports'] as int;
    final seriousSafetyReports = riskFlags['seriousSafetyReports'] as int;

    if (seriousSafetyReports >=
        _asRuleInt(rules['seriousSafetySuspensionThreshold'], 2)) {
      return 'suspended';
    }
    if (outstandingFees > 0 ||
        nonPaymentReports >=
            _asRuleInt(rules['nonPaymentRestrictionThreshold'], 2)) {
      return 'restricted';
    }
    if (seriousSafetyReports >=
            _asRuleInt(rules['seriousSafetyWatchlistThreshold'], 1) ||
        backToBackCancellations >=
            _asRuleInt(rules['watchlistCancellationThreshold'], 3)) {
      return 'watchlist';
    }
    return 'clear';
  }

  List<dynamic> _upsertFlag({
    required List<dynamic> existing,
    required String code,
    required String severity,
    required String message,
  }) {
    final flags = existing
        .map<Map<String, dynamic>>(
          (dynamic entry) => entry is Map
              ? entry.map<String, dynamic>(
                  (dynamic key, dynamic value) =>
                      MapEntry(key.toString(), value),
                )
              : <String, dynamic>{},
        )
        .where((Map<String, dynamic> flag) => flag.isNotEmpty)
        .toList();

    flags.removeWhere((Map<String, dynamic> flag) => flag['code'] == code);
    flags.add(<String, dynamic>{
      'code': code,
      'severity': severity,
      'message': message,
      'updatedAt': rtdb.ServerValue.timestamp,
      'createdAt': rtdb.ServerValue.timestamp,
    });
    return flags;
  }
}

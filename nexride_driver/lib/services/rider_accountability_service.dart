import 'package:firebase_database/firebase_database.dart' as rtdb;

import 'support_ticket_bridge_service.dart';

class DriverRiderContext {
  const DriverRiderContext({
    required this.riderId,
    required this.name,
    required this.phone,
    required this.verificationStatus,
    required this.verifiedBadge,
    required this.rating,
    required this.ratingCount,
    required this.riskStatus,
    required this.paymentStatus,
    required this.cashAccessStatus,
    required this.outstandingCancellationFeesNgn,
    required this.nonPaymentReports,
  });

  final String riderId;
  final String name;
  final String phone;
  final String verificationStatus;
  final bool verifiedBadge;
  final double rating;
  final int ratingCount;
  final String riskStatus;
  final String paymentStatus;
  final String cashAccessStatus;
  final int outstandingCancellationFeesNgn;
  final int nonPaymentReports;
}

class RiderAccountabilityService {
  const RiderAccountabilityService();

  static const Map<String, dynamic> _defaultRules = <String, dynamic>{
    'backToBackCancellationThreshold': 5,
    'unpaidCancellationFeeBlocksTripRequests': true,
    'nonPaymentRestrictionThreshold': 2,
    'seriousSafetyWatchlistThreshold': 1,
    'seriousSafetySuspensionThreshold': 2,
  };

  rtdb.DatabaseReference get _rootRef => rtdb.FirebaseDatabase.instance.ref();
  SupportTicketBridgeService get _supportTicketBridge =>
      const SupportTicketBridgeService();

  Future<DriverRiderContext> loadRiderContext({
    required String riderId,
    required Map<String, dynamic> rideData,
  }) async {
    final trustSnapshot = _map(rideData['rider_trust_snapshot']);
    final snapshots =
        await Future.wait<rtdb.DataSnapshot>(<Future<rtdb.DataSnapshot>>[
      _rootRef.child('users/$riderId').get(),
      _rootRef.child('rider_reputation/$riderId').get(),
      _rootRef.child('rider_risk_flags/$riderId').get(),
      _rootRef.child('rider_payment_flags/$riderId').get(),
    ]);

    final user = _map(snapshots[0].value);
    final verification = _map(user['verification']);
    final trustSummary = _map(user['trustSummary']);
    final reputation = _map(snapshots[1].value);
    final riskFlags = _map(snapshots[2].value);
    final paymentFlags = _map(snapshots[3].value);

    final name = _firstNonEmpty(<dynamic>[
      rideData['rider_name'],
      user['name'],
    ], fallback: 'Rider');
    final phone = _firstNonEmpty(<dynamic>[
      rideData['rider_phone'],
      rideData['phone'],
      user['phone'],
    ]);
    final verificationStatus = _normalizedVerificationStatus(
      _firstNonEmpty(<dynamic>[
        verification['overallStatus'],
        trustSummary['verificationStatus'],
        trustSnapshot['verificationStatus'],
      ], fallback: 'unverified'),
    );
    final verifiedBadge = verificationStatus == 'verified' &&
        (trustSummary['verifiedBadge'] == true ||
            verification['verifiedBadgeEligible'] == true ||
            trustSnapshot['verifiedBadge'] == true);
    final rating = _toDouble(
          reputation['averageRating'],
        ) ??
        _toDouble(trustSnapshot['rating']) ??
        5.0;
    final ratingCount = _toInt(reputation['ratingCount']) ??
        _toInt(trustSnapshot['ratingCount']) ??
        0;
    final riskStatus = _firstNonEmpty(<dynamic>[
      riskFlags['status'],
      trustSummary['riskStatus'],
      trustSnapshot['riskStatus'],
    ], fallback: 'clear');
    final paymentStatus = _firstNonEmpty(<dynamic>[
      paymentFlags['status'],
      trustSummary['paymentStatus'],
    ], fallback: 'clear');
    final cashAccessStatus = _firstNonEmpty(<dynamic>[
      paymentFlags['cashAccessStatus'],
      trustSummary['cashAccessStatus'],
      trustSnapshot['cashAccessStatus'],
    ], fallback: 'enabled');
    final outstandingCancellationFeesNgn = _toInt(
          paymentFlags['outstandingCancellationFeesNgn'],
        ) ??
        _toInt(trustSummary['outstandingCancellationFeesNgn']) ??
        0;
    final nonPaymentReports = _toInt(reputation['nonPaymentReports']) ??
        _toInt(riskFlags['nonPaymentReports']) ??
        0;

    return DriverRiderContext(
      riderId: riderId,
      name: name,
      phone: phone,
      verificationStatus: verificationStatus,
      verifiedBadge: verifiedBadge,
      rating: rating,
      ratingCount: ratingCount,
      riskStatus: riskStatus,
      paymentStatus: paymentStatus,
      cashAccessStatus: cashAccessStatus,
      outstandingCancellationFeesNgn: outstandingCancellationFeesNgn,
      nonPaymentReports: nonPaymentReports,
    );
  }

  Future<void> submitRiderRating({
    required String rideId,
    required String riderId,
    required String driverId,
    required String serviceType,
    required double rating,
    String? note,
  }) async {
    final ratingRef = _rootRef.child('rider_ratings/$riderId').push();
    await ratingRef.set(<String, dynamic>{
      'ratingId': ratingRef.key,
      'rideId': rideId,
      'riderId': riderId,
      'driverId': driverId,
      'serviceType': serviceType,
      'rating': rating,
      'message': (note ?? '').trim(),
      'createdAt': rtdb.ServerValue.timestamp,
      'updatedAt': rtdb.ServerValue.timestamp,
    });

    final reputationRef = _rootRef.child('rider_reputation/$riderId');
    final transactionResult =
        await reputationRef.runTransaction((Object? currentData) {
      final current = _map(currentData);
      final currentRating = _toDouble(current['averageRating']) ?? 5.0;
      final ratingCount = _toInt(current['ratingCount']) ?? 0;
      final nextRating =
          ((currentRating * ratingCount) + rating) / (ratingCount + 1);
      return rtdb.Transaction.success(<String, dynamic>{
        ...current,
        'riderId': riderId,
        'verificationType': _firstNonEmpty(<dynamic>[
          current['verificationType'],
        ], fallback: 'reputation'),
        'provider': _firstNonEmpty(<dynamic>[
          current['provider'],
        ], fallback: 'nexride_reputation_engine'),
        'providerReference': _firstNonEmpty(<dynamic>[
          current['providerReference'],
        ], fallback: riderId),
        'status': 'active',
        'result': 'stable',
        'averageRating': double.parse(nextRating.toStringAsFixed(2)),
        'ratingCount': ratingCount + 1,
        'lastRatingAt': rtdb.ServerValue.timestamp,
        'updatedAt': rtdb.ServerValue.timestamp,
        'createdAt': current['createdAt'] ?? rtdb.ServerValue.timestamp,
      });
    });
    final updatedReputation = _map(transactionResult.snapshot.value);

    await _rootRef
        .child('users/$riderId/trustSummary')
        .update(<String, dynamic>{
      'rating': updatedReputation['averageRating'] ?? rating,
      'ratingCount': updatedReputation['ratingCount'] ?? 1,
      'updatedAt': rtdb.ServerValue.timestamp,
    });
  }

  Future<void> submitRiderReport({
    required String rideId,
    required String riderId,
    required String driverId,
    required String serviceType,
    required String reason,
    required String message,
    required String rideStatus,
    double? amountDueNgn,
    String? paymentMethod,
    String? evidenceSummary,
    String? evidenceReference,
    List<String>? evidenceTypes,
  }) async {
    final rules = await _fetchRules();
    final reportRef = _rootRef.child('rider_reports').push();
    final riskSnapshot =
        await _rootRef.child('rider_risk_flags/$riderId').get();
    final paymentSnapshot =
        await _rootRef.child('rider_payment_flags/$riderId').get();
    final reputationSnapshot =
        await _rootRef.child('rider_reputation/$riderId').get();

    final riskFlags = _map(riskSnapshot.value);
    final paymentFlags = _map(paymentSnapshot.value);
    final reputation = _map(reputationSnapshot.value);

    final nextRisk = <String, dynamic>{
      ...riskFlags,
      'riderId': riderId,
      'verificationType': _firstNonEmpty(<dynamic>[
        riskFlags['verificationType'],
      ], fallback: 'rider_risk'),
      'provider': _firstNonEmpty(<dynamic>[
        riskFlags['provider'],
      ], fallback: 'nexride_trust_rules'),
      'providerReference': _firstNonEmpty(<dynamic>[
        riskFlags['providerReference'],
      ], fallback: riderId),
      'updatedAt': rtdb.ServerValue.timestamp,
      'createdAt': riskFlags['createdAt'] ?? rtdb.ServerValue.timestamp,
    };
    final nextPayment = <String, dynamic>{
      ...paymentFlags,
      'riderId': riderId,
      'verificationType': _firstNonEmpty(<dynamic>[
        paymentFlags['verificationType'],
      ], fallback: 'payment_trust'),
      'provider': _firstNonEmpty(<dynamic>[
        paymentFlags['provider'],
      ], fallback: 'nexride_payment_rules'),
      'providerReference': _firstNonEmpty(<dynamic>[
        paymentFlags['providerReference'],
      ], fallback: riderId),
      'updatedAt': rtdb.ServerValue.timestamp,
      'createdAt': paymentFlags['createdAt'] ?? rtdb.ServerValue.timestamp,
    };
    final nextReputation = <String, dynamic>{
      ...reputation,
      'riderId': riderId,
      'verificationType': _firstNonEmpty(<dynamic>[
        reputation['verificationType'],
      ], fallback: 'reputation'),
      'provider': _firstNonEmpty(<dynamic>[
        reputation['provider'],
      ], fallback: 'nexride_reputation_engine'),
      'providerReference': _firstNonEmpty(<dynamic>[
        reputation['providerReference'],
      ], fallback: riderId),
      'updatedAt': rtdb.ServerValue.timestamp,
      'createdAt': reputation['createdAt'] ?? rtdb.ServerValue.timestamp,
    };

    final normalizedReason = reason.trim().toLowerCase();
    final roundedAmountDue = amountDueNgn == null
        ? 0
        : amountDueNgn.isFinite
            ? amountDueNgn.round()
            : 0;
    final normalizedPaymentMethod =
        _firstNonEmpty(<dynamic>[paymentMethod], fallback: 'unspecified');
    final normalizedEvidenceSummary =
        _firstNonEmpty(<dynamic>[evidenceSummary]);
    final normalizedEvidenceReference =
        _firstNonEmpty(<dynamic>[evidenceReference]);
    final normalizedEvidenceTypes = (evidenceTypes ?? const <String>[])
        .map((String value) => value.trim().toLowerCase())
        .where((String value) => value.isNotEmpty)
        .toList();
    final activeFlags = _list(nextRisk['activeFlags']);

    switch (normalizedReason) {
      case 'non-payment':
        nextRisk['nonPaymentReports'] =
            (_toInt(nextRisk['nonPaymentReports']) ?? 0) + 1;
        nextReputation['nonPaymentReports'] =
            (_toInt(nextReputation['nonPaymentReports']) ?? 0) + 1;
        nextPayment['cashAllowed'] = false;
        nextPayment['cashAccessStatus'] = 'restricted';
        nextPayment['status'] = 'restricted';
        nextPayment['lastReportedOutstandingAmountNgn'] = roundedAmountDue;
        nextPayment['lastPaymentMethod'] = normalizedPaymentMethod;
        nextPayment['lastPaymentIssueRideId'] = rideId;
        nextPayment['lastPaymentIssueAt'] = rtdb.ServerValue.timestamp;
        nextRisk['activeFlags'] = _upsertFlag(
          existing: activeFlags,
          code: 'driver_non_payment_report',
          severity: 'restricted',
          message: 'A driver submitted a non-payment report for this rider.',
        );
        break;
      case 'abuse':
      case 'safety concern':
      case 'off-route coercion':
        nextRisk['seriousSafetyReports'] =
            (_toInt(nextRisk['seriousSafetyReports']) ?? 0) + 1;
        nextReputation['seriousSafetyReports'] =
            (_toInt(nextReputation['seriousSafetyReports']) ?? 0) + 1;
        nextRisk['activeFlags'] = _upsertFlag(
          existing: activeFlags,
          code: 'serious_driver_safety_report',
          severity: 'watchlist',
          message: 'A safety-related report was submitted by a driver.',
        );
        break;
      default:
        nextRisk['abuseReports'] = (_toInt(nextRisk['abuseReports']) ?? 0) + 1;
        nextRisk['activeFlags'] = _upsertFlag(
          existing: activeFlags,
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
    nextPayment['cashAccessStatus'] = nextPayment['cashAllowed'] == false
        ? 'restricted'
        : _firstNonEmpty(<dynamic>[
            nextPayment['cashAccessStatus'],
          ], fallback: 'enabled');
    nextPayment['result'] =
        nextPayment['cashAllowed'] == false ? 'restricted' : 'clear';
    nextPayment['status'] = _firstNonEmpty(<dynamic>[
      nextPayment['status'],
    ], fallback: 'clear');

    await _rootRef.update(<String, dynamic>{
      'rider_reports/${reportRef.key}': <String, dynamic>{
        'reportId': reportRef.key,
        'rideId': rideId,
        'riderId': riderId,
        'driverId': driverId,
        'serviceType': serviceType,
        'reason': reason,
        'message': message,
        'rideStatus': rideStatus,
        'status': 'pending',
        'provider': 'driver_report_queue',
        'providerReference': reportRef.key,
        'paymentContext': <String, dynamic>{
          'method': normalizedPaymentMethod,
          'amountDueNgn': roundedAmountDue,
          'cashAccessStatus': nextPayment['cashAccessStatus'] ?? 'enabled',
        },
        'evidence': <String, dynamic>{
          'summary': normalizedEvidenceSummary,
          'reference': normalizedEvidenceReference,
          'types': normalizedEvidenceTypes,
          'attachmentStatus': normalizedEvidenceTypes.isEmpty &&
                  normalizedEvidenceSummary.isEmpty &&
                  normalizedEvidenceReference.isEmpty
              ? 'not_provided'
              : 'details_recorded',
        },
        'reviewQueue': <String, dynamic>{
          'queue': normalizedReason == 'non-payment'
              ? 'rider_payment_review'
              : 'rider_trust_review',
          'status': 'pending',
        },
        'createdAt': rtdb.ServerValue.timestamp,
        'updatedAt': rtdb.ServerValue.timestamp,
      },
      'rider_risk_flags/$riderId': nextRisk,
      'rider_payment_flags/$riderId': nextPayment,
      'rider_reputation/$riderId': nextReputation,
      'users/$riderId/trustSummary/riskStatus': nextRisk['status'],
      'users/$riderId/trustSummary/paymentStatus':
          nextPayment['status'] ?? 'clear',
      'users/$riderId/trustSummary/cashAccessStatus':
          nextPayment['cashAccessStatus'] ?? 'enabled',
      'users/$riderId/trustSummary/updatedAt': rtdb.ServerValue.timestamp,
    });

    try {
      await _supportTicketBridge.upsertRiderReportTicket(
        sourceReference: reportRef.key ?? rideId,
        rideId: rideId,
        riderId: riderId,
        driverId: driverId,
        serviceType: serviceType,
        reason: reason,
        message: message,
        rideStatus: rideStatus,
        paymentMethod: normalizedPaymentMethod,
        amountDueNgn: roundedAmountDue,
        evidenceSummary: normalizedEvidenceSummary,
        evidenceReference: normalizedEvidenceReference,
        evidenceTypes: normalizedEvidenceTypes,
      );
    } catch (_) {}
  }

  Future<Map<String, dynamic>> _fetchRules() async {
    final snapshot = await _rootRef.child('app_config/rider_trust_rules').get();
    if (snapshot.value is! Map) {
      return Map<String, dynamic>.from(_defaultRules);
    }
    return <String, dynamic>{
      ..._defaultRules,
      ...Map<String, dynamic>.from(snapshot.value as Map),
    };
  }

  String _normalizedVerificationStatus(String value) {
    switch (value.trim().toLowerCase()) {
      case 'submitted':
        return 'submitted';
      case 'checking':
        return 'checking';
      case 'manual_review':
      case 'under_review':
        return 'manual_review';
      case 'verified':
      case 'approved':
        return 'verified';
      case 'rejected':
      case 'failed':
        return 'rejected';
      default:
        return 'unverified';
    }
  }

  String _deriveRiskStatus({
    required Map<String, dynamic> riskFlags,
    required Map<String, dynamic> paymentFlags,
    required Map<String, dynamic> rules,
  }) {
    final outstandingFees =
        _toInt(paymentFlags['outstandingCancellationFeesNgn']) ?? 0;
    final seriousSafetyReports = _toInt(riskFlags['seriousSafetyReports']) ?? 0;
    final nonPaymentReports = _toInt(riskFlags['nonPaymentReports']) ?? 0;
    final backToBackCancellations =
        _toInt(riskFlags['backToBackCancellations']) ?? 0;

    if (riskFlags['status']?.toString() == 'blacklisted') {
      return 'blacklisted';
    }
    if (seriousSafetyReports >=
        _toInt(rules['seriousSafetySuspensionThreshold'])!) {
      return 'suspended';
    }
    if (outstandingFees > 0 &&
        rules['unpaidCancellationFeeBlocksTripRequests'] == true) {
      return 'restricted';
    }
    if (nonPaymentReports >= _toInt(rules['nonPaymentRestrictionThreshold'])!) {
      return 'restricted';
    }
    if (seriousSafetyReports >=
        _toInt(rules['seriousSafetyWatchlistThreshold'])!) {
      return 'watchlist';
    }
    if (backToBackCancellations >=
        _toInt(rules['backToBackCancellationThreshold'])!) {
      return 'watchlist';
    }
    if ((_toInt(riskFlags['abuseReports']) ?? 0) > 0) {
      return 'watchlist';
    }
    return 'clear';
  }

  Map<String, dynamic> _map(dynamic value) {
    if (value is Map) {
      return value.map<String, dynamic>(
        (dynamic key, dynamic entryValue) =>
            MapEntry(key.toString(), entryValue),
      );
    }
    return <String, dynamic>{};
  }

  List<dynamic> _list(dynamic value) {
    if (value is List) {
      return List<dynamic>.from(value);
    }
    return <dynamic>[];
  }

  String _firstNonEmpty(Iterable<dynamic> values, {String fallback = ''}) {
    for (final value in values) {
      final text = value?.toString().trim() ?? '';
      if (text.isNotEmpty) {
        return text;
      }
    }
    return fallback;
  }

  int? _toInt(dynamic value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '');
  }

  double? _toDouble(dynamic value) {
    if (value is double) {
      return value;
    }
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '');
  }

  List<dynamic> _upsertFlag({
    required List<dynamic> existing,
    required String code,
    required String severity,
    required String message,
  }) {
    final remaining = existing
        .where(
          (dynamic value) =>
              _map(value)['code']?.toString().trim().toLowerCase() !=
              code.trim().toLowerCase(),
        )
        .toList();
    remaining.add(<String, dynamic>{
      'code': code,
      'severity': severity,
      'message': message,
      'updatedAt': rtdb.ServerValue.timestamp,
    });
    return remaining;
  }
}

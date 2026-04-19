import 'dart:math';

import 'package:flutter/material.dart';

import '../config/rider_app_config.dart';

const int kRiderVerificationReviewDays = 3;
const int kDefaultCancellationFeeNgn = 800;
const List<String> kRiderTrustServiceTypes = <String>[
  'ride',
  'dispatch_delivery',
  'groceries_mart',
  'restaurants_food',
];

enum RiderIdentityMethod { nin, bvn }

extension RiderIdentityMethodX on RiderIdentityMethod {
  String get key => switch (this) {
    RiderIdentityMethod.nin => 'nin',
    RiderIdentityMethod.bvn => 'bvn',
  };

  String get label => switch (this) {
    RiderIdentityMethod.nin => 'NIN',
    RiderIdentityMethod.bvn => 'BVN',
  };

  String get description => switch (this) {
    RiderIdentityMethod.nin =>
      'Use your National Identification Number if it is available.',
    RiderIdentityMethod.bvn =>
      'Use your Bank Verification Number when NIN is not available yet.',
  };

  String get checkType => switch (this) {
    RiderIdentityMethod.nin => 'nin_verification',
    RiderIdentityMethod.bvn => 'bvn_verification',
  };
}

RiderIdentityMethod riderIdentityMethodFromKey(String? rawValue) {
  final normalized = rawValue?.trim().toLowerCase() ?? '';
  return normalized == 'bvn'
      ? RiderIdentityMethod.bvn
      : RiderIdentityMethod.nin;
}

class RiderVerificationRequirement {
  const RiderVerificationRequirement({
    required this.key,
    required this.label,
    required this.description,
    required this.icon,
    required this.requiresUpload,
    this.numberLabel,
  });

  final String key;
  final String label;
  final String description;
  final IconData icon;
  final bool requiresUpload;
  final String? numberLabel;
}

const List<RiderVerificationRequirement>
kRiderVerificationRequirements = <RiderVerificationRequirement>[
  RiderVerificationRequirement(
    key: 'identity',
    label: 'Identity number',
    description:
        'Submit either your NIN or BVN so the identity review can be completed later through an approved KYC provider.',
    icon: Icons.credit_card_outlined,
    requiresUpload: false,
    numberLabel: 'NIN or BVN',
  ),
  RiderVerificationRequirement(
    key: 'selfie',
    label: 'Selfie / face verification',
    description:
        'Capture a clear selfie so future liveness and face-match checks can be connected safely.',
    icon: Icons.camera_alt_outlined,
    requiresUpload: true,
  ),
];

Map<String, dynamic> _asStringDynamicMap(dynamic value) {
  if (value is Map) {
    return value.map<String, dynamic>(
      (dynamic key, dynamic entryValue) => MapEntry(key.toString(), entryValue),
    );
  }
  return <String, dynamic>{};
}

String _text(dynamic value) => value?.toString().trim() ?? '';

int _intValue(dynamic value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

double _doubleValue(dynamic value) {
  if (value is double) {
    return value;
  }
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value?.toString() ?? '') ?? 0;
}

List<String> _stringList(dynamic value) {
  if (value is Iterable) {
    return value.map((dynamic item) => item.toString()).toList();
  }
  return <String>[];
}

String riderTrustFingerprint(String input) {
  var hash = 2166136261;
  for (final codeUnit in input.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 16777619) & 0xFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

String riderMaskedSensitiveNumber(String rawValue) {
  final cleaned = rawValue.replaceAll(RegExp(r'\s+'), '');
  if (cleaned.length <= 4) {
    return cleaned;
  }
  return '${'*' * (cleaned.length - 4)}${cleaned.substring(cleaned.length - 4)}';
}

String _normalizeRiderVerificationStatus(String status) {
  return switch (status.trim().toLowerCase()) {
    'submitted' => 'submitted',
    'checking' => 'checking',
    'manual_review' || 'under_review' => 'manual_review',
    'verified' || 'approved' => 'verified',
    'rejected' || 'failed' => 'rejected',
    _ => 'unverified',
  };
}

Map<String, dynamic> _normalizedRiderDocument({
  required String documentType,
  required String label,
  required String providerFallback,
  required dynamic rawValue,
  required String verificationType,
}) {
  final existing = _asStringDynamicMap(rawValue);
  final status = _normalizeRiderVerificationStatus(_text(existing['status']));
  final documentNumber = _text(existing['documentNumber']);

  return <String, dynamic>{
    'documentType': documentType,
    'label': label,
    'verificationType': verificationType,
    'documentMethod': _text(existing['documentMethod']),
    'documentNumber': documentNumber,
    'maskedDocumentNumber': _text(existing['maskedDocumentNumber']).isNotEmpty
        ? _text(existing['maskedDocumentNumber'])
        : riderMaskedSensitiveNumber(documentNumber),
    'numberFingerprint': _text(existing['numberFingerprint']),
    'fileUrl': _text(existing['fileUrl']),
    'fileReference': _text(existing['fileReference']),
    'fileName': _text(existing['fileName']),
    'mimeType': _text(existing['mimeType']),
    'uploadSource': _text(existing['uploadSource']),
    'fileSizeBytes': _intValue(existing['fileSizeBytes']),
    'note': _text(existing['note']),
    'provider': _text(existing['provider']).isNotEmpty
        ? _text(existing['provider'])
        : providerFallback,
    'providerReference': _text(existing['providerReference']),
    'status': status,
    'result': _text(existing['result']).isNotEmpty
        ? _text(existing['result'])
        : (status == 'unverified' ? 'awaiting_submission' : 'pending_review'),
    'failureReason': _text(existing['failureReason']),
    'reviewedAt': existing['reviewedAt'],
    'reviewedBy': _text(existing['reviewedBy']),
    'submittedAt': existing['submittedAt'],
    'createdAt': existing['createdAt'],
    'updatedAt': existing['updatedAt'],
  };
}

Map<String, dynamic> _normalizedRiderCheck({
  required String checkType,
  required String providerFallback,
  required dynamic rawValue,
}) {
  final existing = _asStringDynamicMap(rawValue);
  final status = _normalizeRiderVerificationStatus(_text(existing['status']));

  return <String, dynamic>{
    'checkType': checkType,
    'provider': _text(existing['provider']).isNotEmpty
        ? _text(existing['provider'])
        : providerFallback,
    'providerReference': _text(existing['providerReference']),
    'status': status,
    'result': _text(existing['result']).isNotEmpty
        ? _text(existing['result'])
        : (status == 'unverified' ? 'awaiting_submission' : 'pending_review'),
    'failureReason': _text(existing['failureReason']),
    'reviewedAt': existing['reviewedAt'],
    'reviewedBy': _text(existing['reviewedBy']),
    'createdAt': existing['createdAt'],
    'updatedAt': existing['updatedAt'],
  };
}

Map<String, dynamic> buildRiderVerificationDefaults(dynamic rawValue) {
  final existing = _asStringDynamicMap(rawValue);
  final documents = _asStringDynamicMap(existing['documents']);
  final checks = _asStringDynamicMap(existing['checks']);
  final identityMethod = riderIdentityMethodFromKey(
    _text(existing['identityMethod']),
  );

  final normalizedDocuments = <String, dynamic>{
    'identity': _normalizedRiderDocument(
      documentType: 'identity',
      label: 'Identity number',
      providerFallback: 'identity_review_queue',
      rawValue: documents['identity'],
      verificationType: '${identityMethod.key}_identity',
    ),
    'selfie': _normalizedRiderDocument(
      documentType: 'selfie',
      label: 'Selfie / face verification',
      providerFallback: 'selfie_review_queue',
      rawValue: documents['selfie'],
      verificationType: 'selfie_face_verification',
    ),
  };

  final normalizedChecks = <String, dynamic>{
    'identity': _normalizedRiderCheck(
      checkType: identityMethod.checkType,
      providerFallback: 'identity_verification_queue',
      rawValue: checks['identity'],
    ),
    'liveness': _normalizedRiderCheck(
      checkType: 'liveness_verification',
      providerFallback: 'liveness_review_queue',
      rawValue: checks['liveness'],
    ),
    'face_match': _normalizedRiderCheck(
      checkType: 'face_match_verification',
      providerFallback: 'face_match_review_queue',
      rawValue: checks['face_match'],
    ),
  };

  final documentStatuses = normalizedDocuments.values
      .map<String>(
        (dynamic value) => _normalizeRiderVerificationStatus(
          _text(_asStringDynamicMap(value)['status']),
        ),
      )
      .toList();
  final checkStatuses = normalizedChecks.values
      .map<String>(
        (dynamic value) => _normalizeRiderVerificationStatus(
          _text(_asStringDynamicMap(value)['status']),
        ),
      )
      .toList();
  final statuses = <String>[...documentStatuses, ...checkStatuses];

  final overallStatus = statuses.any((String status) => status == 'rejected')
      ? 'rejected'
      : statuses.every((String status) => status == 'verified')
      ? 'verified'
      : statuses.any((String status) => status == 'checking')
      ? 'checking'
      : statuses.any((String status) => status == 'manual_review')
      ? 'manual_review'
      : statuses.any((String status) => status == 'submitted')
      ? 'submitted'
      : 'unverified';

  final reviewStatus = overallStatus == 'verified'
      ? 'approved'
      : overallStatus == 'rejected'
      ? 'attention_required'
      : overallStatus == 'unverified'
      ? 'pending_submission'
      : 'in_review';

  return <String, dynamic>{
    'riderId': _text(existing['riderId']),
    'identityMethod': identityMethod.key,
    'identityMethodLabel': identityMethod.label,
    'overallStatus': overallStatus,
    'status': overallStatus,
    'verifiedBadgeEligible': overallStatus == 'verified',
    'badgeLabel': overallStatus == 'verified' ? 'Verified rider' : '',
    'reviewWindowDays': _intValue(existing['reviewWindowDays']) > 0
        ? _intValue(existing['reviewWindowDays'])
        : kRiderVerificationReviewDays,
    'documents': normalizedDocuments,
    'checks': normalizedChecks,
    'providerAdapters': <String, dynamic>{
      'nin': <String, dynamic>{
        'status': 'ready_for_integration',
        'label': 'NIN provider adapter ready',
      },
      'bvn': <String, dynamic>{
        'status': 'ready_for_integration',
        'label': 'BVN provider adapter ready',
      },
      'liveness': <String, dynamic>{
        'status': 'ready_for_integration',
        'label': 'Liveness provider adapter ready',
      },
      'face_match': <String, dynamic>{
        'status': 'ready_for_integration',
        'label': 'Face match provider adapter ready',
      },
    },
    'verificationType': 'aggregate_verification',
    'provider': 'multi_provider',
    'providerReference': _text(existing['providerReference']),
    'result': reviewStatus,
    'failureReason': overallStatus == 'rejected' ? 'review_required' : '',
    'reviewedAt': existing['reviewedAt'],
    'reviewedBy': _text(existing['reviewedBy']),
    'createdAt': existing['createdAt'],
    'updatedAt': existing['updatedAt'],
    'lastSubmittedAt': existing['lastSubmittedAt'],
  };
}

Map<String, dynamic> buildRiderRiskFlagsDefaults(dynamic rawValue) {
  final existing = _asStringDynamicMap(rawValue);
  final status = _text(existing['status']).isNotEmpty
      ? _text(existing['status'])
      : 'clear';

  return <String, dynamic>{
    'riderId': _text(existing['riderId']),
    'verificationType': 'risk_profile',
    'provider': _text(existing['provider']).isNotEmpty
        ? _text(existing['provider'])
        : 'nexride_rules_engine',
    'providerReference': _text(existing['providerReference']),
    'status': status,
    'result': _text(existing['result']).isNotEmpty
        ? _text(existing['result'])
        : status,
    'failureReason': _text(existing['failureReason']),
    'reviewedAt': existing['reviewedAt'],
    'reviewedBy': _text(existing['reviewedBy']),
    'createdAt': existing['createdAt'],
    'updatedAt': existing['updatedAt'],
    'activeFlags': existing['activeFlags'] is List
        ? List<dynamic>.from(existing['activeFlags'] as List<dynamic>)
        : <dynamic>[],
    'backToBackCancellations': _intValue(existing['backToBackCancellations']),
    'totalCancellations': _intValue(existing['totalCancellations']),
    'noShowCount': _intValue(existing['noShowCount']),
    'nonPaymentReports': _intValue(existing['nonPaymentReports']),
    'seriousSafetyReports': _intValue(existing['seriousSafetyReports']),
    'abuseReports': _intValue(existing['abuseReports']),
    'watchlistReason': _text(existing['watchlistReason']),
    'restrictionReason': _text(existing['restrictionReason']),
  };
}

Map<String, dynamic> buildRiderPaymentFlagsDefaults(
  dynamic rawValue, {
  int cancellationFeeNgn = kDefaultCancellationFeeNgn,
}) {
  final existing = _asStringDynamicMap(rawValue);
  final outstandingFees = _intValue(existing['outstandingCancellationFeesNgn']);
  final cashRestricted = existing['cashAllowed'] == false;
  final restrictionStatus = outstandingFees > 0
      ? 'restricted'
      : cashRestricted
      ? 'limited'
      : 'clear';

  return <String, dynamic>{
    'riderId': _text(existing['riderId']),
    'verificationType': 'payment_access',
    'provider': _text(existing['provider']).isNotEmpty
        ? _text(existing['provider'])
        : 'nexride_rules_engine',
    'providerReference': _text(existing['providerReference']),
    'status': restrictionStatus,
    'result': _text(existing['result']).isNotEmpty
        ? _text(existing['result'])
        : restrictionStatus,
    'failureReason': _text(existing['failureReason']),
    'reviewedAt': existing['reviewedAt'],
    'reviewedBy': _text(existing['reviewedBy']),
    'createdAt': existing['createdAt'],
    'updatedAt': existing['updatedAt'],
    'cashAllowed': existing['cashAllowed'] == false ? false : true,
    'cashAccessStatus': _text(existing['cashAccessStatus']).isNotEmpty
        ? _text(existing['cashAccessStatus'])
        : (cashRestricted ? 'restricted' : 'enabled'),
    'tripRequestAccess': _text(existing['tripRequestAccess']).isNotEmpty
        ? _text(existing['tripRequestAccess'])
        : (outstandingFees > 0 ? 'blocked' : 'enabled'),
    'outstandingCancellationFeesNgn': outstandingFees,
    'unpaidCancellationCount': _intValue(existing['unpaidCancellationCount']),
    'defaultCancellationFeeNgn':
        _intValue(existing['defaultCancellationFeeNgn']) > 0
        ? _intValue(existing['defaultCancellationFeeNgn'])
        : cancellationFeeNgn,
    'lastFeeAppliedAt': existing['lastFeeAppliedAt'],
    'lastClearedAt': existing['lastClearedAt'],
  };
}

Map<String, dynamic> buildRiderReputationDefaults(dynamic rawValue) {
  final existing = _asStringDynamicMap(rawValue);
  final ratingCount = _intValue(existing['ratingCount']);
  final averageRating = ratingCount <= 0
      ? 5.0
      : _doubleValue(existing['averageRating']);

  return <String, dynamic>{
    'riderId': _text(existing['riderId']),
    'verificationType': 'reputation',
    'provider': _text(existing['provider']).isNotEmpty
        ? _text(existing['provider'])
        : 'nexride_reputation_engine',
    'providerReference': _text(existing['providerReference']),
    'status': _text(existing['status']).isNotEmpty
        ? _text(existing['status'])
        : 'active',
    'result': _text(existing['result']).isNotEmpty
        ? _text(existing['result'])
        : 'stable',
    'failureReason': _text(existing['failureReason']),
    'reviewedAt': existing['reviewedAt'],
    'reviewedBy': _text(existing['reviewedBy']),
    'createdAt': existing['createdAt'],
    'updatedAt': existing['updatedAt'],
    'averageRating': averageRating,
    'ratingCount': ratingCount,
    'completedTrips': _intValue(existing['completedTrips']),
    'cancellationCount': _intValue(existing['cancellationCount']),
    'backToBackCancellations': _intValue(existing['backToBackCancellations']),
    'noShowCount': _intValue(existing['noShowCount']),
    'nonPaymentReports': _intValue(existing['nonPaymentReports']),
    'seriousSafetyReports': _intValue(existing['seriousSafetyReports']),
    'verifiedBadge': existing['verifiedBadge'] == true,
    'trustTier': _text(existing['trustTier']).isNotEmpty
        ? _text(existing['trustTier'])
        : 'standard',
  };
}

Map<String, dynamic> buildRiderDeviceFingerprintsDefaults(
  dynamic rawValue, {
  required String installFingerprint,
  String? email,
  String? phone,
}) {
  final existing = _asStringDynamicMap(rawValue);
  final normalizedEmail = _text(email).toLowerCase();
  final normalizedPhone = _text(phone).replaceAll(RegExp(r'\D'), '');

  return <String, dynamic>{
    'riderId': _text(existing['riderId']),
    'verificationType': 'device_linkage',
    'provider': _text(existing['provider']).isNotEmpty
        ? _text(existing['provider'])
        : 'install_fingerprint_service',
    'providerReference': _text(existing['providerReference']).isNotEmpty
        ? _text(existing['providerReference'])
        : installFingerprint,
    'status': _text(existing['status']).isNotEmpty
        ? _text(existing['status'])
        : 'clear',
    'result': _text(existing['result']).isNotEmpty
        ? _text(existing['result'])
        : 'tracked',
    'failureReason': _text(existing['failureReason']),
    'reviewedAt': existing['reviewedAt'],
    'reviewedBy': _text(existing['reviewedBy']),
    'createdAt': existing['createdAt'],
    'updatedAt': existing['updatedAt'],
    'installFingerprint': _text(existing['installFingerprint']).isNotEmpty
        ? _text(existing['installFingerprint'])
        : installFingerprint,
    'identityFingerprint': _text(existing['identityFingerprint']),
    'paymentFingerprints': _stringList(existing['paymentFingerprints']),
    'linkedAccounts': _stringList(existing['linkedAccounts']),
    'linkedBlacklistedProfiles': _stringList(
      existing['linkedBlacklistedProfiles'],
    ),
    'accountLinkageSignals': <String, dynamic>{
      'emailFingerprint': normalizedEmail.isNotEmpty
          ? riderTrustFingerprint(normalizedEmail)
          : _text(
              _asStringDynamicMap(
                existing['accountLinkageSignals'],
              )['emailFingerprint'],
            ),
      'phoneFingerprint': normalizedPhone.isNotEmpty
          ? riderTrustFingerprint(normalizedPhone)
          : _text(
              _asStringDynamicMap(
                existing['accountLinkageSignals'],
              )['phoneFingerprint'],
            ),
    },
  };
}

Map<String, dynamic> buildRiderTrustSummary({
  required Map<String, dynamic> verification,
  required Map<String, dynamic> riskFlags,
  required Map<String, dynamic> paymentFlags,
  required Map<String, dynamic> reputation,
  required Map<String, dynamic> accessDecision,
}) {
  final verified =
      _normalizeRiderVerificationStatus(_text(verification['overallStatus'])) ==
      'verified';

  return <String, dynamic>{
    'verificationStatus': _text(verification['overallStatus']).isNotEmpty
        ? _text(verification['overallStatus'])
        : 'unverified',
    'verifiedBadge': verified,
    'riskStatus': _text(riskFlags['status']).isNotEmpty
        ? _text(riskFlags['status'])
        : 'clear',
    'paymentStatus': _text(paymentFlags['status']).isNotEmpty
        ? _text(paymentFlags['status'])
        : 'clear',
    'cashAccessStatus': _text(paymentFlags['cashAccessStatus']).isNotEmpty
        ? _text(paymentFlags['cashAccessStatus'])
        : 'enabled',
    'canRequestTrips': accessDecision['canRequestTrips'] == true,
    'canUseCash': accessDecision['canUseCash'] == true,
    'restrictionCode': _text(accessDecision['restrictionCode']),
    'restrictionMessage': _text(accessDecision['message']),
    'outstandingCancellationFeesNgn': _intValue(
      paymentFlags['outstandingCancellationFeesNgn'],
    ),
    'backToBackCancellations': _intValue(riskFlags['backToBackCancellations']),
    'rating': _doubleValue(reputation['averageRating']),
    'ratingCount': _intValue(reputation['ratingCount']),
    'updatedAt': max(
      _intValue(verification['updatedAt']),
      max(
        _intValue(riskFlags['updatedAt']),
        _intValue(paymentFlags['updatedAt']),
      ),
    ),
  };
}

Map<String, dynamic> buildRiderProfileDefaults({
  required String riderId,
  required Map<String, dynamic> existing,
  required String installFingerprint,
  Map<String, dynamic>? existingRiskFlags,
  Map<String, dynamic>? existingPaymentFlags,
  Map<String, dynamic>? existingReputation,
  Map<String, dynamic>? existingDeviceFingerprints,
  Map<String, dynamic>? accessDecision,
  String? fallbackName,
  String? fallbackEmail,
  String? fallbackPhone,
}) {
  final verification = buildRiderVerificationDefaults(existing['verification']);
  final riskFlags = buildRiderRiskFlagsDefaults(existingRiskFlags);
  final paymentFlags = buildRiderPaymentFlagsDefaults(existingPaymentFlags);
  final reputation = buildRiderReputationDefaults(existingReputation);
  final deviceFingerprints = buildRiderDeviceFingerprintsDefaults(
    existingDeviceFingerprints,
    installFingerprint: installFingerprint,
    email: _text(existing['email']).isNotEmpty
        ? _text(existing['email'])
        : fallbackEmail,
    phone: _text(existing['phone']).isNotEmpty
        ? _text(existing['phone'])
        : fallbackPhone,
  );
  final trustSummary = buildRiderTrustSummary(
    verification: verification,
    riskFlags: riskFlags,
    paymentFlags: paymentFlags,
    reputation: reputation,
    accessDecision: accessDecision ?? const <String, dynamic>{},
  );

  return <String, dynamic>{
    'uid': riderId,
    'name': _text(existing['name']).isNotEmpty
        ? _text(existing['name'])
        : (fallbackName ?? 'Rider'),
    'email': _text(existing['email']).isNotEmpty
        ? _text(existing['email'])
        : (fallbackEmail ?? ''),
    'phone': _text(existing['phone']).isNotEmpty
        ? _text(existing['phone'])
        : (fallbackPhone ?? ''),
    'role': _text(existing['role']).isNotEmpty
        ? _text(existing['role'])
        : 'rider',
    'verification': verification,
    'trustSummary': trustSummary,
    'installFingerprint': deviceFingerprints['installFingerprint'],
    'created_at': existing['created_at'],
    'updated_at': existing['updated_at'],
  };
}

double riderVerificationProgressValue(Map<String, dynamic> verification) {
  final normalized = buildRiderVerificationDefaults(verification);
  final overallStatus = _normalizeRiderVerificationStatus(
    _text(normalized['overallStatus']),
  );
  return switch (overallStatus) {
    'submitted' => 0.35,
    'checking' => 0.6,
    'manual_review' => 0.8,
    'verified' => 1,
    'rejected' => 1,
    _ => 0.08,
  };
}

String riderVerificationStatusLabel(String status) {
  return switch (_normalizeRiderVerificationStatus(status)) {
    'submitted' => 'Submitted',
    'checking' => 'Checking',
    'manual_review' => 'Manual review',
    'verified' => 'Approved',
    'rejected' => 'Rejected',
    _ => 'Missing',
  };
}

Color riderVerificationStatusColor(String status) {
  return switch (_normalizeRiderVerificationStatus(status)) {
    'submitted' => const Color(0xFF8A6424),
    'checking' => const Color(0xFF2E6DA4),
    'manual_review' => const Color(0xFF5B7C99),
    'verified' => const Color(0xFF198754),
    'rejected' => const Color(0xFFD64545),
    _ => const Color(0xFF8A6424),
  };
}

String riderRiskStatusLabel(String status) {
  return switch (_text(status)) {
    'watchlist' => 'Under review',
    'restricted' => 'Limited access',
    'suspended' => 'Temporarily suspended',
    'blacklisted' => 'Restricted',
    _ => 'Good standing',
  };
}

Color riderRiskStatusColor(String status) {
  return switch (_text(status)) {
    'watchlist' => const Color(0xFF8A6424),
    'restricted' => const Color(0xFFB45F06),
    'suspended' => const Color(0xFFD64545),
    'blacklisted' => const Color(0xFF7A1010),
    _ => const Color(0xFF198754),
  };
}

String riderCashAccessLabel(String status) {
  return switch (_text(status)) {
    'restricted' => 'Cash restricted',
    'blocked' => 'Cash blocked',
    _ => 'Cash enabled',
  };
}

Color riderCashAccessColor(String status) {
  return switch (_text(status)) {
    'restricted' => const Color(0xFF8A6424),
    'blocked' => const Color(0xFFD64545),
    _ => const Color(0xFF198754),
  };
}

String riderTrustSummaryMessage(Map<String, dynamic> trustSummary) {
  final message = _text(trustSummary['restrictionMessage']);
  if (message.isNotEmpty) {
    return message;
  }

  if (trustSummary['verifiedBadge'] == true) {
    return 'Your account passed ${RiderVerificationCopy.titleLowercase} and is ready for broader trust-based access as new payment features roll out.';
  }

  return 'Complete ${RiderVerificationCopy.titleLowercase} to unlock a verified badge and stronger account trust over time.';
}

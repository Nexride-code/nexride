import 'package:flutter/material.dart';

import '../config/driver_app_config.dart';

const int kDriverVerificationReviewDays = 3;
const List<String> kDriverServiceTypes = <String>[
  'ride',
  'dispatch_delivery',
  'groceries_mart',
  'restaurants_food',
];

class DriverRequiredDocument {
  const DriverRequiredDocument({
    required this.key,
    required this.label,
    required this.description,
    required this.icon,
    required this.referenceHint,
    required this.providerHint,
    required this.checkTypes,
    required this.requiredForServices,
    this.numberLabel,
  });

  final String key;
  final String label;
  final String description;
  final IconData icon;
  final String referenceHint;
  final String providerHint;
  final List<String> checkTypes;
  final List<String> requiredForServices;
  final String? numberLabel;
}

const List<DriverRequiredDocument> kDriverRequiredDocuments =
    <DriverRequiredDocument>[
  DriverRequiredDocument(
    key: 'selfie',
    label: 'Selfie / Profile Photo',
    description:
        'A clear front-facing photo used for identity review and future liveness checks.',
    icon: Icons.face_outlined,
    referenceHint: 'Selfie capture or profile image upload',
    providerHint: 'Identity review',
    checkTypes: <String>[
      'liveness_verification',
      'face_match_verification',
    ],
    requiredForServices: kDriverServiceTypes,
  ),
  DriverRequiredDocument(
    key: 'drivers_license',
    label: 'Driver\'s License',
    description:
        'Valid Nigeria driver\'s licence details for review and future licence verification checks.',
    icon: Icons.badge_outlined,
    referenceHint: 'Driver\'s licence upload',
    providerHint: 'Licence review',
    checkTypes: <String>['drivers_license_verification'],
    requiredForServices: kDriverServiceTypes,
    numberLabel: 'Licence number',
  ),
  DriverRequiredDocument(
    key: 'nin',
    label: 'NIN',
    description:
        'National Identification Number for identity review and future NIMC-connected checks.',
    icon: Icons.verified_user_outlined,
    referenceHint: 'NIN slip or supporting image upload',
    providerHint: 'Identity review',
    checkTypes: <String>['nin_verification'],
    requiredForServices: kDriverServiceTypes,
    numberLabel: 'NIN',
  ),
  DriverRequiredDocument(
    key: 'vehicle_documents',
    label: 'Vehicle Documents',
    description:
        'Vehicle licence, insurance, ownership, or roadworthiness documents for compliance review.',
    icon: Icons.directions_car_outlined,
    referenceHint: 'Vehicle document upload',
    providerHint: 'Vehicle compliance review',
    checkTypes: <String>['vehicle_document_review'],
    requiredForServices: kDriverServiceTypes,
    numberLabel: 'Vehicle registration or plate',
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

String driverScopeLabel(String serviceType) {
  return switch (serviceType) {
    'dispatch_delivery' => 'Dispatch / Delivery',
    'groceries_mart' => 'Groceries / Mart',
    'restaurants_food' => 'Restaurants / Food',
    _ => 'Ride',
  };
}

String _normalizeDocumentStatus(String status) {
  return switch (status) {
    'submitted' => 'submitted',
    'checking' => 'checking',
    'manual_review' => 'manual_review',
    'under_review' => 'manual_review',
    'verified' => 'approved',
    'approved' => 'approved',
    'failed' => 'rejected',
    'rejected' => 'rejected',
    _ => 'missing',
  };
}

double driverDocumentProgressValue(String status, {bool isUploading = false}) {
  if (isUploading) {
    return 0.2;
  }
  return switch (_normalizeDocumentStatus(status)) {
    'submitted' => 0.28,
    'checking' => 0.55,
    'manual_review' => 0.78,
    'approved' => 1,
    'rejected' => 1,
    _ => 0,
  };
}

Map<String, dynamic> normalizedDriverDocument(
  DriverRequiredDocument document,
  dynamic rawValue,
) {
  final existing = _asStringDynamicMap(rawValue);
  final status = _normalizeDocumentStatus(_text(existing['status']));
  return <String, dynamic>{
    'key': document.key,
    'documentType': document.key,
    'label': document.label,
    'description': document.description,
    'status': status,
    'documentNumber': _text(existing['documentNumber']),
    'reference': _text(existing['reference']),
    'note': _text(existing['note']),
    'fileUrl': _text(existing['fileUrl']),
    'fileReference': _text(existing['fileReference']),
    'fileName': _text(existing['fileName']),
    'mimeType': _text(existing['mimeType']),
    'uploadSource': _text(existing['uploadSource']),
    'fileSizeBytes': _intValue(existing['fileSizeBytes']),
    'createdAt': existing['createdAt'],
    'submittedAt': existing['submittedAt'],
    'reviewedAt': existing['reviewedAt'],
    'reviewedBy': _text(existing['reviewedBy']),
    'updatedAt': existing['updatedAt'],
    'reviewNote': _text(existing['reviewNote']),
    'verificationProvider': _text(existing['verificationProvider']),
    'verificationProviderLabel':
        _text(existing['verificationProviderLabel']).isNotEmpty
            ? _text(existing['verificationProviderLabel'])
            : document.providerHint,
    'providerReference': _text(existing['providerReference']),
    'result': _text(existing['result']).isNotEmpty
        ? _text(existing['result'])
        : (status == 'missing' ? 'awaiting_submission' : 'pending_review'),
    'failureReason': _text(existing['failureReason']),
    'checkTypes': document.checkTypes,
    'requiredForServices': document.requiredForServices,
    'reviewWindowDays': _intValue(existing['reviewWindowDays']) > 0
        ? _intValue(existing['reviewWindowDays'])
        : kDriverVerificationReviewDays,
    'officialVerificationLive': existing['officialVerificationLive'] == true,
  };
}

Map<String, dynamic> _buildServiceApprovalSummary(
  Map<String, dynamic> documents,
) {
  final summary = <String, dynamic>{};

  for (final serviceType in kDriverServiceTypes) {
    final requiredDocuments = kDriverRequiredDocuments
        .where(
          (DriverRequiredDocument document) =>
              document.requiredForServices.contains(serviceType),
        )
        .toList();
    final statuses = requiredDocuments
        .map(
          (DriverRequiredDocument document) => _normalizeDocumentStatus(
            _text(_asStringDynamicMap(documents[document.key])['status']),
          ),
        )
        .toList();

    final hasRejected = statuses.any((String status) => status == 'rejected');
    final allApproved = requiredDocuments.isNotEmpty &&
        statuses.every((String status) => status == 'approved');
    final anySubmitted = statuses.any((String status) => status != 'missing');
    final anyChecking = statuses.any((String status) => status == 'checking');
    final anyManualReview = statuses.any(
      (String status) => status == 'manual_review',
    );
    final anyPendingSubmission = statuses.any(
      (String status) => status == 'submitted',
    );

    final status = hasRejected
        ? 'rejected'
        : allApproved
            ? 'approved'
            : anyChecking
                ? 'checking'
                : anyManualReview
                    ? 'manual_review'
                    : anyPendingSubmission
                        ? 'submitted'
                        : anySubmitted
                            ? 'submitted'
                            : 'missing';
    final verificationBypassed =
        !DriverFeatureFlags.driverVerificationRequired &&
            DriverFeatureFlags.serviceCanReceiveRequestsWithoutVerification(
              serviceType,
            );

    summary[serviceType] = <String, dynamic>{
      'serviceType': serviceType,
      'label': driverScopeLabel(serviceType),
      'status': status,
      'canReceiveRequests': status == 'approved' || verificationBypassed,
      'verificationBypassed': verificationBypassed,
      'requiredDocuments': requiredDocuments
          .map((DriverRequiredDocument document) => document.key)
          .toList(),
    };
  }

  return summary;
}

Map<String, dynamic> _buildVerificationSummaryFromDocuments(
  Map<String, dynamic> documents,
) {
  var approvedCount = 0;
  var submittedCount = 0;
  var submittedPendingCount = 0;
  var checkingCount = 0;
  var manualReviewCount = 0;
  var rejectedCount = 0;

  for (final dynamic value in documents.values) {
    final document = _asStringDynamicMap(value);
    final status = _normalizeDocumentStatus(_text(document['status']));

    if (status != 'missing') {
      submittedCount += 1;
    }
    if (status == 'approved') {
      approvedCount += 1;
    }
    if (status == 'submitted') {
      submittedPendingCount += 1;
    }
    if (status == 'checking') {
      checkingCount += 1;
    }
    if (status == 'manual_review') {
      manualReviewCount += 1;
    }
    if (status == 'rejected') {
      rejectedCount += 1;
    }
  }

  final requiredCount = kDriverRequiredDocuments.length;
  final workflowStatus = rejectedCount > 0
      ? 'rejected'
      : approvedCount == requiredCount
          ? 'approved'
          : checkingCount > 0
              ? 'checking'
              : manualReviewCount > 0
                  ? 'manual_review'
                  : submittedPendingCount > 0
                      ? 'submitted'
                      : 'missing';
  final overallStatus =
      workflowStatus == 'approved' || workflowStatus == 'rejected'
          ? workflowStatus
          : workflowStatus == 'missing'
              ? 'incomplete'
              : 'under_review';

  return <String, dynamic>{
    'status': workflowStatus,
    'overallStatus': overallStatus,
    'requiredCount': requiredCount,
    'submittedCount': submittedCount,
    'submittedPendingCount': submittedPendingCount,
    'approvedCount': approvedCount,
    'checkingCount': checkingCount,
    'manualReviewCount': manualReviewCount,
    'rejectedCount': rejectedCount,
  };
}

Map<String, dynamic> normalizedDriverVerification(dynamic rawValue) {
  final existing = _asStringDynamicMap(rawValue);
  final existingDocuments = _asStringDynamicMap(existing['documents']);
  final normalizedDocuments = <String, dynamic>{
    for (final document in kDriverRequiredDocuments)
      document.key: normalizedDriverDocument(
        document,
        existingDocuments[document.key],
      ),
  };

  final serviceApprovals = _buildServiceApprovalSummary(normalizedDocuments);
  final overall = _buildVerificationSummaryFromDocuments(normalizedDocuments);
  final approvedServices = serviceApprovals.values
      .where(
        (dynamic value) =>
            _asStringDynamicMap(value)['canReceiveRequests'] == true,
      )
      .length;

  return <String, dynamic>{
    ...overall,
    'documents': normalizedDocuments,
    'serviceApprovals': serviceApprovals,
    'restrictions': <String, dynamic>{
      'canGoOnline': approvedServices > 0,
      'ride':
          _asStringDynamicMap(serviceApprovals['ride'])['canReceiveRequests'] ==
              true,
      'dispatch_delivery': _asStringDynamicMap(
            serviceApprovals['dispatch_delivery'],
          )['canReceiveRequests'] ==
          true,
      'groceries_mart': _asStringDynamicMap(
            serviceApprovals['groceries_mart'],
          )['canReceiveRequests'] ==
          true,
      'restaurants_food': _asStringDynamicMap(
            serviceApprovals['restaurants_food'],
          )['canReceiveRequests'] ==
          true,
    },
    'documentType': 'aggregate',
    'submittedAt': existing['lastSubmittedAt'],
    'verificationProvider': 'multi_provider',
    'providerReference': '',
    'status': overall['status'],
    'result': overall['status'],
    'failureReason': overall['status'] == 'rejected' ? 'review_required' : '',
    'reviewedAt': existing['lastReviewedAt'],
    'reviewedBy': _text(existing['reviewedBy']),
    'createdAt': existing['createdAt'],
    'reviewWindowDays': _intValue(existing['reviewWindowDays']) > 0
        ? _intValue(existing['reviewWindowDays'])
        : kDriverVerificationReviewDays,
    'providerConnections': <String, dynamic>{
      'nin': <String, dynamic>{
        'status': 'ready_for_integration',
        'label': 'NIMC adapter ready',
      },
      'drivers_license': <String, dynamic>{
        'status': 'ready_for_integration',
        'label': 'FRSC adapter ready',
      },
      'liveness': <String, dynamic>{
        'status': 'ready_for_integration',
        'label': 'Liveness adapter ready',
      },
      'face_match': <String, dynamic>{
        'status': 'ready_for_integration',
        'label': 'Face match adapter ready',
      },
    },
    'updatedAt': existing['updatedAt'],
    'lastSubmittedAt': existing['lastSubmittedAt'],
    'lastReviewedAt': existing['lastReviewedAt'],
  };
}

bool driverVerificationCanGoOnline(Map<String, dynamic> verification) {
  if (!DriverFeatureFlags.driverVerificationRequired) {
    return true;
  }
  final normalized = normalizedDriverVerification(verification);
  return _asStringDynamicMap(normalized['restrictions'])['canGoOnline'] == true;
}

bool driverServiceCanReceiveRequests(
  Map<String, dynamic> verification,
  String serviceType,
) {
  final key = serviceType.trim().toLowerCase();
  if (!DriverFeatureFlags.activeRequestServiceTypes.contains(key)) {
    return false;
  }
  final normalized = normalizedDriverVerification(verification);
  final approvals = _asStringDynamicMap(normalized['serviceApprovals']);
  final serviceApproval = _asStringDynamicMap(approvals[serviceType]);
  return serviceApproval['canReceiveRequests'] == true;
}

String driverVerificationEligibilityMessage(Map<String, dynamic> verification) {
  if (!DriverFeatureFlags.driverVerificationRequired) {
    return 'Driver verification is still active in the backend, but it is not blocking online access right now.';
  }

  final normalized = normalizedDriverVerification(verification);
  final status = _text(normalized['status']);

  return switch (status) {
    'approved' =>
      'Your driver verification is approved for active service categories.',
    'submitted' ||
    'checking' ||
    'manual_review' =>
      'Your verification is under review. Reviews may take up to 3 days before you can go online.',
    'rejected' =>
      'Your verification needs attention before the account can go online again.',
    _ => 'Complete the driver verification checklist before going online.',
  };
}

String driverServiceRestrictionMessage(
  Map<String, dynamic> verification,
  String serviceType,
) {
  final normalized = normalizedDriverVerification(verification);
  final approval = _asStringDynamicMap(
    _asStringDynamicMap(normalized['serviceApprovals'])[serviceType],
  );
  final status = _text(approval['status']);
  final label = driverScopeLabel(serviceType);

  return switch (status) {
    'approved' => '$label is approved for your account.',
    'submitted' ||
    'checking' ||
    'manual_review' =>
      '$label approval is still under review. Reviews may take up to 3 days.',
    'rejected' =>
      '$label approval was rejected. Update the required documents and submit again.',
    _ => '$label is not approved yet for this driver account.',
  };
}

List<String> driverApprovedServiceLabels(Map<String, dynamic> verification) {
  final normalized = normalizedDriverVerification(verification);
  final approvals = _asStringDynamicMap(normalized['serviceApprovals']);
  return approvals.values
      .map<Map<String, dynamic>>((dynamic value) => _asStringDynamicMap(value))
      .where(
          (Map<String, dynamic> value) => value['canReceiveRequests'] == true)
      .map((Map<String, dynamic> value) => _text(value['label']))
      .toList();
}

double driverVerificationProgressValue(Map<String, dynamic> verification) {
  final normalized = normalizedDriverVerification(verification);
  final requiredCount = _intValue(normalized['requiredCount']);
  if (requiredCount <= 0) {
    return 0;
  }

  final submittedCount = _intValue(normalized['submittedCount']);
  final approvedCount = _intValue(normalized['approvedCount']);
  final pendingCount = _intValue(normalized['manualReviewCount']) +
      _intValue(normalized['checkingCount']);
  final weighted = approvedCount + (pendingCount * 0.65);
  return (weighted > 0 ? weighted : submittedCount * 0.35) / requiredCount;
}

String driverDocumentStatusLabel(String status) {
  return switch (_normalizeDocumentStatus(status)) {
    'submitted' => 'Submitted',
    'checking' => 'Checking',
    'manual_review' => 'Manual Review',
    'approved' => 'Approved',
    'rejected' => 'Rejected',
    _ => 'Missing',
  };
}

Color driverDocumentStatusColor(String status) {
  return switch (_normalizeDocumentStatus(status)) {
    'submitted' => const Color(0xFF8A6424),
    'checking' => const Color(0xFF3A6EA5),
    'manual_review' => const Color(0xFF5B7C99),
    'approved' => const Color(0xFF198754),
    'rejected' => const Color(0xFFD64545),
    _ => Colors.black54,
  };
}

String driverVerificationStatusLabel(String status) {
  return switch (status) {
    'submitted' || 'checking' || 'manual_review' => 'Under review',
    'under_review' => 'Under review',
    'approved' => 'Approved',
    'rejected' => 'Rejected',
    _ => 'Incomplete',
  };
}

Color driverVerificationStatusColor(String status) {
  return switch (status) {
    'submitted' || 'checking' || 'manual_review' => const Color(0xFF3A6EA5),
    'under_review' => const Color(0xFF3A6EA5),
    'approved' => const Color(0xFF198754),
    'rejected' => const Color(0xFFD64545),
    _ => const Color(0xFF8A6424),
  };
}

String driverServiceApprovalStatusLabel(String status) {
  return switch (status) {
    'submitted' => 'Submitted',
    'checking' => 'Checking',
    'manual_review' => 'Manual review',
    'approved' => 'Approved',
    'rejected' => 'Rejected',
    _ => 'Missing',
  };
}

Color driverServiceApprovalStatusColor(String status) {
  return switch (status) {
    'submitted' => const Color(0xFF8A6424),
    'checking' => const Color(0xFF3A6EA5),
    'manual_review' => const Color(0xFF5B7C99),
    'approved' => const Color(0xFF198754),
    'rejected' => const Color(0xFFD64545),
    _ => const Color(0xFF8A6424),
  };
}

import '../support/rider_trust_support.dart';

class RiderVerificationCheckRequest {
  const RiderVerificationCheckRequest({
    required this.riderId,
    required this.identityMethod,
    required this.identityNumber,
    required this.fileReference,
    required this.checkType,
  });

  final String riderId;
  final RiderIdentityMethod identityMethod;
  final String identityNumber;
  final String fileReference;
  final String checkType;
}

class RiderVerificationCheckPlan {
  const RiderVerificationCheckPlan({
    required this.checkType,
    required this.provider,
    required this.providerLabel,
    required this.providerReference,
    required this.status,
    required this.result,
    required this.failureReason,
    required this.summary,
  });

  final String checkType;
  final String provider;
  final String providerLabel;
  final String providerReference;
  final String status;
  final String result;
  final String failureReason;
  final String summary;
}

abstract class RiderVerificationProviderAdapter {
  String get provider;
  String get providerLabel;
  List<String> get supportedCheckTypes;

  RiderVerificationCheckPlan createCheckPlan(
    RiderVerificationCheckRequest request,
  );
}

class PlaceholderRiderVerificationProviderAdapter
    implements RiderVerificationProviderAdapter {
  const PlaceholderRiderVerificationProviderAdapter({
    required this.provider,
    required this.providerLabel,
    required this.supportedCheckTypes,
    required this.summary,
  });

  @override
  final String provider;

  @override
  final String providerLabel;

  @override
  final List<String> supportedCheckTypes;

  final String summary;

  @override
  RiderVerificationCheckPlan createCheckPlan(
    RiderVerificationCheckRequest request,
  ) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return RiderVerificationCheckPlan(
      checkType: request.checkType,
      provider: provider,
      providerLabel: providerLabel,
      providerReference:
          '$provider-${request.riderId}-${request.checkType}-$now',
      status: 'manual_review',
      result: 'awaiting_provider_connection_or_ops_review',
      failureReason: '',
      summary: summary,
    );
  }
}

class RiderVerificationProviderRegistry {
  RiderVerificationProviderRegistry._();

  static final List<RiderVerificationProviderAdapter>
  _adapters = <RiderVerificationProviderAdapter>[
    const PlaceholderRiderVerificationProviderAdapter(
      provider: 'nin_verification_queue',
      providerLabel: 'NIN identity review queue',
      supportedCheckTypes: <String>['nin_verification'],
      summary:
          'Prepared for future NIN provider integration. The submission is currently queued for manual review.',
    ),
    const PlaceholderRiderVerificationProviderAdapter(
      provider: 'bvn_verification_queue',
      providerLabel: 'BVN identity review queue',
      supportedCheckTypes: <String>['bvn_verification'],
      summary:
          'Prepared for future BVN provider integration. The submission is currently queued for manual review.',
    ),
    const PlaceholderRiderVerificationProviderAdapter(
      provider: 'liveness_review_queue',
      providerLabel: 'Liveness review queue',
      supportedCheckTypes: <String>['liveness_verification'],
      summary:
          'Prepared for future liveness verification. The submission is currently queued for manual review.',
    ),
    const PlaceholderRiderVerificationProviderAdapter(
      provider: 'face_match_review_queue',
      providerLabel: 'Face match review queue',
      supportedCheckTypes: <String>['face_match_verification'],
      summary:
          'Prepared for future face-match verification. The submission is currently queued for manual review.',
    ),
  ];

  static RiderVerificationProviderAdapter adapterForCheckType(
    String checkType,
  ) {
    return _adapters.firstWhere(
      (RiderVerificationProviderAdapter adapter) =>
          adapter.supportedCheckTypes.contains(checkType),
      orElse: () => const PlaceholderRiderVerificationProviderAdapter(
        provider: 'manual_review_queue',
        providerLabel: 'Manual review queue',
        supportedCheckTypes: <String>[],
        summary:
            'Prepared for manual review while a dedicated KYC connector is pending.',
      ),
    );
  }

  static List<RiderVerificationCheckPlan> plansForSubmission({
    required String riderId,
    required RiderIdentityMethod identityMethod,
    required String identityNumber,
    required String fileReference,
  }) {
    final checkTypes = <String>[
      identityMethod.checkType,
      'liveness_verification',
      'face_match_verification',
    ];

    return checkTypes
        .map(
          (String checkType) => adapterForCheckType(checkType).createCheckPlan(
            RiderVerificationCheckRequest(
              riderId: riderId,
              identityMethod: identityMethod,
              identityNumber: identityNumber,
              fileReference: fileReference,
              checkType: checkType,
            ),
          ),
        )
        .toList();
  }
}

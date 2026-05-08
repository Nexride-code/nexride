class VerificationCheckRequest {
  const VerificationCheckRequest({
    required this.driverId,
    required this.documentType,
    required this.checkType,
    required this.reference,
    required this.documentNumber,
  });

  final String driverId;
  final String documentType;
  final String checkType;
  final String reference;
  final String documentNumber;
}

class VerificationCheckPlan {
  const VerificationCheckPlan({
    required this.checkType,
    required this.providerKey,
    required this.providerLabel,
    required this.providerReference,
    required this.status,
    required this.result,
    required this.failureReason,
    required this.summary,
  });

  final String checkType;
  final String providerKey;
  final String providerLabel;
  final String providerReference;
  final String status;
  final String result;
  final String failureReason;
  final String summary;
}

abstract class VerificationProviderAdapter {
  String get providerKey;
  String get providerLabel;
  List<String> get supportedCheckTypes;

  VerificationCheckPlan createCheckPlan(VerificationCheckRequest request);
}

class PlaceholderVerificationProviderAdapter
    implements VerificationProviderAdapter {
  const PlaceholderVerificationProviderAdapter({
    required this.providerKey,
    required this.providerLabel,
    required this.supportedCheckTypes,
    required this.summary,
  });

  @override
  final String providerKey;

  @override
  final String providerLabel;

  @override
  final List<String> supportedCheckTypes;

  final String summary;

  @override
  VerificationCheckPlan createCheckPlan(VerificationCheckRequest request) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return VerificationCheckPlan(
      checkType: request.checkType,
      providerKey: providerKey,
      providerLabel: providerLabel,
      providerReference:
          '$providerKey-${request.driverId}-${request.documentType}-$now',
      status: 'manual_review',
      result: 'awaiting_provider_connection_or_ops_review',
      failureReason: '',
      summary: summary,
    );
  }
}

class VerificationProviderRegistry {
  VerificationProviderRegistry._();

  static final List<VerificationProviderAdapter> _adapters =
      <VerificationProviderAdapter>[
    const PlaceholderVerificationProviderAdapter(
      providerKey: 'nimc_provider_placeholder',
      providerLabel: 'Identity verification review queue',
      supportedCheckTypes: <String>['nin_verification'],
      summary:
          'Prepared for future NIMC identity verification, currently queued for manual review.',
    ),
    const PlaceholderVerificationProviderAdapter(
      providerKey: 'bvn_provider_placeholder',
      providerLabel: 'BVN verification review queue',
      supportedCheckTypes: <String>['bvn_verification'],
      summary:
          'Prepared for future BVN verification (NIBSS / provider API), currently queued for manual review.',
    ),
    const PlaceholderVerificationProviderAdapter(
      providerKey: 'frsc_provider_placeholder',
      providerLabel: 'Licence verification review queue',
      supportedCheckTypes: <String>['drivers_license_verification'],
      summary:
          'Prepared for future FRSC licence verification, currently queued for manual review.',
    ),
    const PlaceholderVerificationProviderAdapter(
      providerKey: 'liveness_provider_placeholder',
      providerLabel: 'Liveness review queue',
      supportedCheckTypes: <String>['liveness_verification'],
      summary:
          'Prepared for future liveness verification, currently queued for manual review.',
    ),
    const PlaceholderVerificationProviderAdapter(
      providerKey: 'face_match_provider_placeholder',
      providerLabel: 'Face match review queue',
      supportedCheckTypes: <String>['face_match_verification'],
      summary:
          'Prepared for future face-match verification, currently queued for manual review.',
    ),
    const PlaceholderVerificationProviderAdapter(
      providerKey: 'vehicle_compliance_placeholder',
      providerLabel: 'Vehicle compliance review queue',
      supportedCheckTypes: <String>['vehicle_document_review'],
      summary:
          'Prepared for vehicle document compliance checks, currently queued for manual review.',
    ),
  ];

  static VerificationProviderAdapter adapterForCheckType(String checkType) {
    return _adapters.firstWhere(
      (VerificationProviderAdapter adapter) =>
          adapter.supportedCheckTypes.contains(checkType),
      orElse: () => const PlaceholderVerificationProviderAdapter(
        providerKey: 'manual_review_placeholder',
        providerLabel: 'Manual review queue',
        supportedCheckTypes: <String>[],
        summary:
            'Prepared for manual review while a dedicated provider connector is pending.',
      ),
    );
  }

  static List<VerificationCheckPlan> plannedChecksForDocument({
    required String driverId,
    required String documentType,
    required List<String> checkTypes,
    required String reference,
    required String documentNumber,
  }) {
    return checkTypes
        .map(
          (String checkType) => adapterForCheckType(checkType).createCheckPlan(
            VerificationCheckRequest(
              driverId: driverId,
              documentType: documentType,
              checkType: checkType,
              reference: reference,
              documentNumber: documentNumber,
            ),
          ),
        )
        .toList();
  }
}

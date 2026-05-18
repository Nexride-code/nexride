import 'package:flutter/material.dart';

import '../legal/legal_models.dart';
import '../legal/legal_navigation.dart';
import '../services/rider_compliance_service.dart';

LegalPolicyId riderPolicyKindToLegalId(RiderPolicyDocumentKind kind) {
  switch (kind) {
    case RiderPolicyDocumentKind.terms:
      return LegalPolicyId.termsOfService;
    case RiderPolicyDocumentKind.privacy:
      return LegalPolicyId.privacyPolicy;
    case RiderPolicyDocumentKind.community:
      return LegalPolicyId.communityGuidelines;
  }
}

Future<void> showRiderPolicyBottomSheet(
  BuildContext context,
  RiderPolicyDocumentKind kind,
) async {
  await showLegalPolicySheet(
    context,
    riderPolicyKindToLegalId(kind),
    source: 'legacy_bottom_sheet',
  );
}

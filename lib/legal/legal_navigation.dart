import 'package:flutter/material.dart';

import '../screens/legal_policy_reader_screen.dart';
import '../screens/legal_trust_center_screen.dart';
import 'legal_models.dart';
import 'legal_policy_analytics_service.dart';

LegalPolicyId? legalPolicyIdFromLegacyKind(String kind) {
  switch (kind) {
    case 'terms':
      return LegalPolicyId.termsOfService;
    case 'privacy':
      return LegalPolicyId.privacyPolicy;
    case 'community':
      return LegalPolicyId.communityGuidelines;
    default:
      return null;
  }
}

Future<void> openLegalTrustCenter(
  BuildContext context, {
  LegalAudience audience = LegalAudience.rider,
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => LegalTrustCenterScreen(audience: audience),
    ),
  );
}

Future<void> openLegalPolicy(
  BuildContext context,
  LegalPolicyId policyId, {
  LegalAudience audience = LegalAudience.rider,
  String source = 'inline_link',
  bool useRootNavigator = false,
}) {
  final route = MaterialPageRoute<void>(
    builder: (_) => LegalPolicyReaderScreen(
      policyId: policyId,
      audience: audience,
      source: source,
    ),
  );
  if (useRootNavigator) {
    return Navigator.of(context, rootNavigator: true).push<void>(route);
  }
  return Navigator.of(context).push<void>(route);
}

/// Modal presentation for signup / compact contexts.
Future<void> showLegalPolicySheet(
  BuildContext context,
  LegalPolicyId policyId, {
  LegalAudience audience = LegalAudience.rider,
  String source = 'bottom_sheet',
}) async {
  await LegalPolicyAnalyticsService.instance.logPolicyOpened(
    policyId: policyId,
    audience: audience.name,
    source: source,
  );
  if (!context.mounted) {
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) {
      final height = MediaQuery.sizeOf(ctx).height * 0.92;
      return ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        child: SizedBox(
          height: height,
          child: LegalPolicyReaderScreen(
            policyId: policyId,
            audience: audience,
            source: source,
          ),
        ),
      );
    },
  );
}

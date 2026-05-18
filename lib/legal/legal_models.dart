import 'package:flutter/material.dart';

/// Who a policy document applies to.
enum LegalAudience { rider, driver, merchant, platform }

/// Stable policy identifiers for CMS / remote-config mapping.
enum LegalPolicyId {
  termsOfService,
  privacyPolicy,
  communityGuidelines,
  riderSafety,
  driverStandards,
  merchantStandards,
  refundCancellation,
  surgePricing,
  dataProtectionNdpc,
  kycIdentity,
  emergencySos,
  fraudPrevention,
  accountSuspension,
  lawEnforcement,
  childSafety,
  prohibitedConduct,
}

/// Grouping for Trust Center navigation.
enum LegalPolicyGroup {
  coreAgreements,
  safetyConduct,
  paymentsPricing,
  privacyData,
  trustIdentity,
  platformRoles,
}

class LegalPolicySection {
  const LegalPolicySection({
    required this.title,
    required this.body,
    this.icon,
    this.keywords = const <String>[],
  });

  final String title;
  final String body;
  final IconData? icon;
  final List<String> keywords;

  bool matchesQuery(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) {
      return true;
    }
    if (title.toLowerCase().contains(q) || body.toLowerCase().contains(q)) {
      return true;
    }
    return keywords.any((k) => k.toLowerCase().contains(q));
  }
}

class LegalPolicyDocument {
  const LegalPolicyDocument({
    required this.id,
    required this.title,
    required this.summary,
    required this.group,
    required this.audiences,
    required this.icon,
    required this.sections,
    required this.lastUpdated,
    this.versionKey,
    this.requiresAcceptance = false,
    this.externalUrl,
  });

  final LegalPolicyId id;
  final String title;
  final String summary;
  final LegalPolicyGroup group;
  final Set<LegalAudience> audiences;
  final IconData icon;
  final List<LegalPolicySection> sections;
  final DateTime lastUpdated;
  /// Firestore / remote-config key (e.g. `terms`, `privacy`, `guidelines`).
  final String? versionKey;
  final bool requiresAcceptance;
  final String? externalUrl;

  String get lastUpdatedLabel {
    const months = <String>[
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    return '${lastUpdated.day} ${months[lastUpdated.month - 1]} ${lastUpdated.year}';
  }

  String get groupTitle {
    switch (group) {
      case LegalPolicyGroup.coreAgreements:
        return 'Core agreements';
      case LegalPolicyGroup.safetyConduct:
        return 'Safety & conduct';
      case LegalPolicyGroup.paymentsPricing:
        return 'Payments & pricing';
      case LegalPolicyGroup.privacyData:
        return 'Privacy & data protection';
      case LegalPolicyGroup.trustIdentity:
        return 'Trust & identity';
      case LegalPolicyGroup.platformRoles:
        return 'Driver & merchant standards';
    }
  }

  bool matchesQuery(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) {
      return true;
    }
    if (title.toLowerCase().contains(q) ||
        summary.toLowerCase().contains(q) ||
        id.name.toLowerCase().contains(q)) {
      return true;
    }
    return sections.any((s) => s.matchesQuery(q));
  }

  List<LegalPolicySection> sectionsMatching(String query) {
    if (query.trim().isEmpty) {
      return sections;
    }
    return sections.where((s) => s.matchesQuery(query)).toList();
  }
}

String legalPolicyIdAnalyticsValue(LegalPolicyId id) => id.name;

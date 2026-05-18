import '../legal/legal_contacts.dart';
import '../legal/legal_policy_catalog.dart';
import '../legal/legal_models.dart';

/// Backward-compatible plain-text exports for legacy callers.
/// Prefer [LegalPolicyCatalog] and structured policy screens.
class RiderPolicyText {
  RiderPolicyText._();

  static const String contactEmail = LegalContacts.privacy;

  static String _plainBody(LegalPolicyId id) {
    final doc = LegalPolicyCatalog.byId(id);
    if (doc == null) {
      return '';
    }
    final buffer = StringBuffer()
      ..writeln(doc.title)
      ..writeln('Last updated: ${doc.lastUpdatedLabel}')
      ..writeln();
    for (final section in doc.sections) {
      buffer
        ..writeln(section.title)
        ..writeln(section.body)
        ..writeln();
    }
    return buffer.toString().trim();
  }

  static String get termsOfService => _plainBody(LegalPolicyId.termsOfService);

  static String get privacyPolicy => _plainBody(LegalPolicyId.privacyPolicy);

  static String get communityGuidelines =>
      _plainBody(LegalPolicyId.communityGuidelines);
}

import '../legal/legal_versions.dart';

/// Regulatory / Play Store compliance versioning for rider consent records.
class RiderComplianceConstants {
  RiderComplianceConstants._();

  /// Bump when legal copies change so existing users re-accept.
  static String get termsVersion => LegalPolicyVersions.terms;

  static String get privacyVersion => LegalPolicyVersions.privacy;

  static String get guidelinesVersion => LegalPolicyVersions.guidelines;
}

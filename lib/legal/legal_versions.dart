/// Default policy version strings (admin may override via RTDB `app_config/legal_policy_versions`).
abstract final class LegalPolicyVersions {
  static const String terms = '2026.05.01';
  static const String privacy = '2026.05.01';
  static const String guidelines = '2026.05.01';

  /// Legacy single-field version kept in sync for older clients.
  static const String legacyTermsVersion = terms;

  static const Map<String, String> defaults = <String, String>{
    'terms': terms,
    'privacy': privacy,
    'guidelines': guidelines,
    'rider_safety': '2026.05.01',
    'driver_standards': '2026.05.01',
    'merchant_standards': '2026.05.01',
    'refund_cancellation': '2026.05.01',
    'surge_pricing': '2026.05.01',
    'data_protection': '2026.05.01',
    'kyc_identity': '2026.05.01',
    'emergency_sos': '2026.05.01',
    'fraud_prevention': '2026.05.01',
    'account_suspension': '2026.05.01',
    'law_enforcement': '2026.05.01',
    'child_safety': '2026.05.01',
    'prohibited_conduct': '2026.05.01',
  };
}

class LegalPolicyVersionConfig {
  const LegalPolicyVersionConfig({
    required this.terms,
    required this.privacy,
    required this.guidelines,
    required this.raw,
  });

  final String terms;
  final String privacy;
  final String guidelines;
  final Map<String, String> raw;

  factory LegalPolicyVersionConfig.defaults() {
    return LegalPolicyVersionConfig(
      terms: LegalPolicyVersions.terms,
      privacy: LegalPolicyVersions.privacy,
      guidelines: LegalPolicyVersions.guidelines,
      raw: Map<String, String>.from(LegalPolicyVersions.defaults),
    );
  }

  String? forKey(String? key) {
    if (key == null || key.isEmpty) {
      return null;
    }
    return raw[key];
  }
}

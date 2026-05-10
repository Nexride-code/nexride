/// Regulatory / Play Store compliance versioning for rider consent records.
class RiderComplianceConstants {
  RiderComplianceConstants._();

  /// Bump when legal copies change so existing users re-accept via [RiderComplianceService.needsTermsAcceptance].
  static const String termsVersion = '1.0';
}

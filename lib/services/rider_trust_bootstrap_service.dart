import 'package:firebase_database/firebase_database.dart' as rtdb;

import '../support/rider_trust_support.dart';
import '../support/startup_rtdb_support.dart';
import 'rider_device_fingerprint_service.dart';
import 'rider_trust_rules_service.dart';

class RiderTrustBootstrapBundle {
  const RiderTrustBootstrapBundle({
    required this.userProfile,
    required this.verification,
    required this.riskFlags,
    required this.paymentFlags,
    required this.reputation,
    required this.deviceFingerprints,
    required this.trustSummary,
    required this.installFingerprint,
    required this.accessDecision,
  });

  final Map<String, dynamic> userProfile;
  final Map<String, dynamic> verification;
  final Map<String, dynamic> riskFlags;
  final Map<String, dynamic> paymentFlags;
  final Map<String, dynamic> reputation;
  final Map<String, dynamic> deviceFingerprints;
  final Map<String, dynamic> trustSummary;
  final String installFingerprint;
  final RiderTrustAccessDecision accessDecision;
}

class RiderTrustBootstrapService {
  const RiderTrustBootstrapService();

  rtdb.DatabaseReference get _rootRef => rtdb.FirebaseDatabase.instance.ref();

  RiderDeviceFingerprintService get _fingerprintService =>
      const RiderDeviceFingerprintService();

  RiderTrustRulesService get _rulesService => const RiderTrustRulesService();

  static Map<String, dynamic> get defaultRules =>
      RiderTrustRulesService.defaultRules;

  Future<RiderTrustBootstrapBundle> ensureRiderTrustState({
    required String riderId,
    required Map<String, dynamic> existingUser,
    String? fallbackName,
    String? fallbackEmail,
    String? fallbackPhone,
    Map<String, dynamic>? preloadedRules,
  }) async {
    final installFingerprint = await _fingerprintService
        .getInstallFingerprint();
    final rules = preloadedRules ?? await _rulesService.fetchRules();
    final riskSnapshot = await runOptionalStartupRead<rtdb.DataSnapshot>(
      source: 'rider_trust_bootstrap.risk_flags',
      path: 'rider_risk_flags/$riderId',
      action: () => _rootRef.child('rider_risk_flags/$riderId').get(),
    );
    final paymentSnapshot = await runOptionalStartupRead<rtdb.DataSnapshot>(
      source: 'rider_trust_bootstrap.payment_flags',
      path: 'rider_payment_flags/$riderId',
      action: () => _rootRef.child('rider_payment_flags/$riderId').get(),
    );
    final reputationSnapshot = await runOptionalStartupRead<rtdb.DataSnapshot>(
      source: 'rider_trust_bootstrap.reputation',
      path: 'rider_reputation/$riderId',
      action: () => _rootRef.child('rider_reputation/$riderId').get(),
    );
    final deviceFingerprintSnapshot =
        await runOptionalStartupRead<rtdb.DataSnapshot>(
          source: 'rider_trust_bootstrap.device_fingerprints',
          path: 'rider_device_fingerprints/$riderId',
          action: () =>
              _rootRef.child('rider_device_fingerprints/$riderId').get(),
        );

    final verification = buildRiderVerificationDefaults(
      existingUser['verification'],
    )..['riderId'] = riderId;
    final riskFlags = buildRiderRiskFlagsDefaults(riskSnapshot?.value)
      ..['riderId'] = riderId;
    final paymentFlags = buildRiderPaymentFlagsDefaults(
      paymentSnapshot?.value,
      cancellationFeeNgn:
          (rules['cancellationFeeNgn'] as num?)?.toInt() ??
          kDefaultCancellationFeeNgn,
    )..['riderId'] = riderId;
    final reputation = buildRiderReputationDefaults(reputationSnapshot?.value)
      ..['riderId'] = riderId;
    final deviceFingerprints = buildRiderDeviceFingerprintsDefaults(
      deviceFingerprintSnapshot?.value,
      installFingerprint: installFingerprint,
      email: existingUser['email']?.toString(),
      phone: existingUser['phone']?.toString(),
    )..['riderId'] = riderId;

    final accessDecision = _rulesService.evaluateAccess(
      verification: verification,
      riskFlags: riskFlags,
      paymentFlags: paymentFlags,
      rules: rules,
    );
    final trustSummary = buildRiderTrustSummary(
      verification: verification,
      riskFlags: riskFlags,
      paymentFlags: paymentFlags,
      reputation: reputation,
      accessDecision: accessDecision.toMap(),
    );
    final userProfile = buildRiderProfileDefaults(
      riderId: riderId,
      existing: existingUser,
      installFingerprint: installFingerprint,
      existingRiskFlags: riskFlags,
      existingPaymentFlags: paymentFlags,
      existingReputation: reputation,
      existingDeviceFingerprints: deviceFingerprints,
      accessDecision: accessDecision.toMap(),
      fallbackName: fallbackName,
      fallbackEmail: fallbackEmail,
      fallbackPhone: fallbackPhone,
    );

    return RiderTrustBootstrapBundle(
      userProfile: userProfile,
      verification: verification,
      riskFlags: riskFlags,
      paymentFlags: paymentFlags,
      reputation: reputation,
      deviceFingerprints: deviceFingerprints,
      trustSummary: trustSummary,
      installFingerprint: installFingerprint,
      accessDecision: accessDecision,
    );
  }
}

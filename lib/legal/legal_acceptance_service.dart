import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import 'legal_models.dart';
import 'legal_policy_analytics_service.dart';
import 'legal_policy_registry_service.dart';
import 'legal_versions.dart';

class LegalAcceptanceSnapshot {
  const LegalAcceptanceSnapshot({
    required this.termsAccepted,
    required this.ageConfirmed,
    this.acceptedTermsVersion,
    this.acceptedPrivacyVersion,
    this.acceptedGuidelinesVersion,
    this.legacyTermsVersion,
    this.fetchFailed = false,
  });

  final bool termsAccepted;
  final bool ageConfirmed;
  final String? acceptedTermsVersion;
  final String? acceptedPrivacyVersion;
  final String? acceptedGuidelinesVersion;
  final String? legacyTermsVersion;
  final bool fetchFailed;

  bool needsReacceptance(LegalPolicyVersionConfig config) {
    if (fetchFailed) {
      return false;
    }
    if (!termsAccepted || !ageConfirmed) {
      return true;
    }
    final termsOk = _versionMatches(acceptedTermsVersion, config.terms) ||
        _versionMatches(legacyTermsVersion, config.terms);
    final privacyOk = _versionMatches(acceptedPrivacyVersion, config.privacy);
    final guidelinesOk =
        _versionMatches(acceptedGuidelinesVersion, config.guidelines);
    return !(termsOk && privacyOk && guidelinesOk);
  }

  static bool _versionMatches(String? stored, String required) {
    final s = (stored ?? '').trim();
    final r = required.trim();
    if (s.isEmpty || r.isEmpty) {
      return false;
    }
    return s == r;
  }
}

/// Firestore-backed acceptance for core legal documents.
class LegalAcceptanceService {
  LegalAcceptanceService._();
  static final LegalAcceptanceService instance = LegalAcceptanceService._();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final LegalPolicyRegistryService _registry =
      LegalPolicyRegistryService.instance;
  final LegalPolicyAnalyticsService _analytics =
      LegalPolicyAnalyticsService.instance;

  CollectionReference<Map<String, dynamic>> get _users =>
      _firestore.collection('users');

  Future<LegalAcceptanceSnapshot> fetchSnapshot(String uid) async {
    final id = uid.trim();
    if (id.isEmpty) {
      return const LegalAcceptanceSnapshot(
        termsAccepted: false,
        ageConfirmed: false,
        fetchFailed: true,
      );
    }
    try {
      final doc = await _users
          .doc(id)
          .get(const GetOptions(source: Source.serverAndCache))
          .timeout(const Duration(seconds: 12));
      return _fromDoc(doc);
    } catch (error) {
      debugPrint('[LegalAcceptance] fetch failed: $error');
      try {
        final cached =
            await _users.doc(id).get(const GetOptions(source: Source.cache));
        return _fromDoc(cached);
      } catch (_) {
        return const LegalAcceptanceSnapshot(
          termsAccepted: false,
          ageConfirmed: false,
          fetchFailed: true,
        );
      }
    }
  }

  LegalAcceptanceSnapshot _fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    if (!doc.exists || doc.data() == null) {
      return const LegalAcceptanceSnapshot(
        termsAccepted: false,
        ageConfirmed: false,
      );
    }
    final m = doc.data()!;
    bool readBool(String k) {
      final v = m[k];
      if (v is bool) {
        return v;
      }
      if (v is String) {
        return v.toLowerCase() == 'true';
      }
      return false;
    }

    return LegalAcceptanceSnapshot(
      termsAccepted: readBool('termsAccepted'),
      ageConfirmed: readBool('ageConfirmed'),
      acceptedTermsVersion: m['accepted_terms_version']?.toString() ??
          m['termsVersion']?.toString(),
      acceptedPrivacyVersion: m['accepted_privacy_version']?.toString(),
      acceptedGuidelinesVersion: m['accepted_guidelines_version']?.toString(),
      legacyTermsVersion: m['termsVersion']?.toString(),
    );
  }

  Future<void> saveCoreAcceptance({
    required String uid,
    required String context,
  }) async {
    final id = uid.trim();
    if (id.isEmpty) {
      return;
    }
    final versions = await _registry.loadVersions();
    final payload = <String, dynamic>{
      'termsAccepted': true,
      'termsAcceptedAt': FieldValue.serverTimestamp(),
      'ageConfirmed': true,
      'ageConfirmedAt': FieldValue.serverTimestamp(),
      'termsVersion': versions.terms,
      'accepted_terms_version': versions.terms,
      'accepted_terms_at': FieldValue.serverTimestamp(),
      'accepted_privacy_version': versions.privacy,
      'accepted_privacy_at': FieldValue.serverTimestamp(),
      'accepted_guidelines_version': versions.guidelines,
      'accepted_guidelines_at': FieldValue.serverTimestamp(),
    };
    await _users.doc(id).set(payload, SetOptions(merge: true));

    for (final entry in <MapEntry<LegalPolicyId, String>>[
      MapEntry(LegalPolicyId.termsOfService, versions.terms),
      MapEntry(LegalPolicyId.privacyPolicy, versions.privacy),
      MapEntry(LegalPolicyId.communityGuidelines, versions.guidelines),
    ]) {
      await _analytics.logPolicyAccepted(
        policyId: entry.key,
        version: entry.value,
        audience: 'rider',
        context: context,
      );
    }
  }

  Future<bool> needsReacceptance(String uid) async {
    final snapshot = await fetchSnapshot(uid);
    final versions = await _registry.loadVersions();
    return snapshot.needsReacceptance(versions);
  }
}

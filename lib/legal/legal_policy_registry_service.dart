import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

import 'legal_versions.dart';

/// Loads admin-configurable policy versions from RTDB with local fallbacks.
class LegalPolicyRegistryService {
  LegalPolicyRegistryService._();
  static final LegalPolicyRegistryService instance =
      LegalPolicyRegistryService._();

  LegalPolicyVersionConfig? _cached;
  DateTime? _cachedAt;

  static const Duration _cacheTtl = Duration(minutes: 15);
  static const String _rtdbPath = 'app_config/legal_policy_versions';

  Future<LegalPolicyVersionConfig> loadVersions() async {
    final now = DateTime.now();
    if (_cached != null &&
        _cachedAt != null &&
        now.difference(_cachedAt!) < _cacheTtl) {
      return _cached!;
    }

    debugPrint('LEGAL_POLICY_READ path=$_rtdbPath');
    try {
      final snap = await FirebaseDatabase.instance
          .ref(_rtdbPath)
          .get()
          .timeout(const Duration(seconds: 6));
      if (snap.exists && snap.value is Map) {
        final raw = Map<String, String>.from(
          (snap.value as Map).map(
            (key, value) => MapEntry(key.toString(), value.toString()),
          ),
        );
        final config = LegalPolicyVersionConfig(
          terms: raw['terms'] ?? LegalPolicyVersions.terms,
          privacy: raw['privacy'] ?? LegalPolicyVersions.privacy,
          guidelines: raw['guidelines'] ?? LegalPolicyVersions.guidelines,
          raw: <String, String>{...LegalPolicyVersions.defaults, ...raw},
        );
        _cached = config;
        _cachedAt = now;
        debugPrint('LEGAL_POLICY_VERSIONS_OK source=rtdb');
        return config;
      }
    } catch (error) {
      debugPrint('LEGAL_POLICY_VERSIONS_FALLBACK error=$error');
    }

    final fallback = LegalPolicyVersionConfig.defaults();
    _cached = fallback;
    _cachedAt = now;
    return fallback;
  }

  void invalidateCache() {
    _cached = null;
    _cachedAt = null;
  }
}

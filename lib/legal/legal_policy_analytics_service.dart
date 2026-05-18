import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/foundation.dart';

import 'legal_models.dart';

/// Policy engagement analytics (`policy_opened`, `policy_scrolled`, `policy_accepted`).
class LegalPolicyAnalyticsService {
  LegalPolicyAnalyticsService._();
  static final LegalPolicyAnalyticsService instance =
      LegalPolicyAnalyticsService._();

  final FirebaseAnalytics _analytics = FirebaseAnalytics.instance;

  Future<void> logPolicyOpened({
    required LegalPolicyId policyId,
    required String audience,
    String? version,
    String? source,
  }) async {
    await _safeLog('policy_opened', <String, Object>{
      'policy_id': legalPolicyIdAnalyticsValue(policyId),
      'audience': audience,
      if (version != null && version.isNotEmpty) 'policy_version': version,
      if (source != null && source.isNotEmpty) 'source': source,
    });
  }

  Future<void> logPolicyScrolled({
    required LegalPolicyId policyId,
    required int scrollPercent,
    required String audience,
  }) async {
    await _safeLog('policy_scrolled', <String, Object>{
      'policy_id': legalPolicyIdAnalyticsValue(policyId),
      'scroll_percent': scrollPercent.clamp(0, 100),
      'audience': audience,
    });
  }

  Future<void> logPolicyAccepted({
    required LegalPolicyId policyId,
    required String version,
    required String audience,
    String? context,
  }) async {
    await _safeLog('policy_accepted', <String, Object>{
      'policy_id': legalPolicyIdAnalyticsValue(policyId),
      'policy_version': version,
      'audience': audience,
      if (context != null && context.isNotEmpty) 'context': context,
    });
  }

  Future<void> _safeLog(String name, Map<String, Object> params) async {
    try {
      await _analytics.logEvent(name: name, parameters: params);
    } catch (error) {
      debugPrint('LEGAL_ANALYTICS_FAIL event=$name error=$error');
    }
  }
}

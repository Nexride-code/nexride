import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/rider_trip_deep_link_service.dart';

/// Rider sign-out: Firebase auth + local caches.
class RiderSessionService {
  RiderSessionService._();

  static final RiderSessionService instance = RiderSessionService._();

  Future<void> signOut({String reason = 'user_logout'}) async {
    debugPrint('RIDER_SESSION sign_out_start reason=$reason');
    try {
      await RiderTripDeepLinkService.instance.clearPendingLink();
    } catch (e, st) {
      debugPrint('RIDER_SESSION clear_pending_link failed: $e\n$st');
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('rider_pending_trip_deep_link');
    } catch (e, st) {
      debugPrint('RIDER_SESSION prefs_clear failed: $e\n$st');
    }
    await FirebaseAuth.instance.signOut();
    debugPrint('RIDER_SESSION sign_out_complete');
  }
}

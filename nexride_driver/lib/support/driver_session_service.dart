import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../services/driver_pending_offer_launch_store.dart';
import 'driver_startup_logs.dart';

/// Centralized driver sign-out: auth, local intent caches, push token hygiene.
class DriverSessionService {
  DriverSessionService._();

  static final DriverSessionService instance = DriverSessionService._();

  Future<void> signOut({String reason = 'user_logout'}) async {
    driverFlowLog('DRIVER_STARTUP_FLOW', {'phase': 'sign_out_start', 'reason': reason});
    try {
      DriverPendingOfferLaunchStore.instance.clearPendingLaunchIntent();
    } catch (e, st) {
      debugPrint('DRIVER_SESSION clear_pending_offer failed: $e\n$st');
    }
    try {
      await FirebaseAuth.instance.signOut();
    } catch (e, st) {
      driverFlowLog('DRIVER_LISTENER_ERROR', {
        'phase': 'sign_out_auth',
        'error': e.toString(),
      });
      debugPrintStack(stackTrace: st);
      rethrow;
    }
    driverFlowLog('DRIVER_STARTUP_FLOW', {'phase': 'sign_out_complete'});
  }
}

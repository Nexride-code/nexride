import 'package:flutter/foundation.dart';

/// Tracks optional startup degradation (Firebase/profile/FCM) after bootstrap.
class DriverStartupCoordinator {
  DriverStartupCoordinator._();

  static final DriverStartupCoordinator instance = DriverStartupCoordinator._();

  bool _pendingDegradedSessionSnack = false;

  /// True when startup completed with incomplete optional data (e.g. slow bootstrap shell).
  bool get hasPendingDegradedSessionSnack => _pendingDegradedSessionSnack;

  void markDegradedSessionData({String? reason}) {
    driverStartupLog('degraded_session_data reason=${reason ?? 'unknown'}');
    _pendingDegradedSessionSnack = true;
  }

  /// Returns true once if the app should show the "safe default state" snackbar.
  bool consumeDegradedSessionSnack() {
    if (!_pendingDegradedSessionSnack) {
      return false;
    }
    _pendingDegradedSessionSnack = false;
    return true;
  }
}

void driverStartupLog(String step) {
  debugPrint(
    '[driver_startup] $step t=${DateTime.now().toIso8601String()}',
  );
}

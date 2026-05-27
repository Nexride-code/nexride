import 'package:flutter/foundation.dart';

import 'nex_trace.dart';

/// Lightweight guard for RTDB listener / timer pressure on map screens.
class RtdbResourceGuard {
  RtdbResourceGuard._();

  static const int maxActiveTimers = 10;
  static const int maxActiveRtdbListeners = 30;

  static int activeTimerCount = 0;
  static int activeListenerCount = 0;
  static DateTime? _lastGuardLogAt;

  static void onListenerAttached({
    String path = '',
    String listenerOwner = '',
    String? rideId,
    String? role,
    String? source,
  }) {
    activeListenerCount++;
    NexTrace.rtdbListenerAttach(
      path: path,
      listenerOwner: listenerOwner,
      rideId: rideId,
      role: role,
      source: source,
    );
    _logIfExceeded();
  }

  static void onListenerDisposed({
    String path = '',
    String listenerOwner = '',
    String? rideId,
    String? role,
    String? source,
  }) {
    if (activeListenerCount > 0) {
      activeListenerCount--;
    }
    NexTrace.rtdbListenerDispose(
      path: path,
      listenerOwner: listenerOwner,
      rideId: rideId,
      role: role,
      source: source,
    );
  }

  static void onTimerAttached() {
    activeTimerCount++;
    _logIfExceeded();
  }

  static void onTimerDisposed() {
    if (activeTimerCount > 0) {
      activeTimerCount--;
    }
  }

  static void _logIfExceeded() {
    if (activeTimerCount <= maxActiveTimers &&
        activeListenerCount <= maxActiveRtdbListeners) {
      return;
    }
    final now = DateTime.now();
    if (_lastGuardLogAt != null &&
        now.difference(_lastGuardLogAt!) < const Duration(seconds: 10)) {
      return;
    }
    _lastGuardLogAt = now;
    debugPrint(
      'RESOURCE_GUARD timers=$activeTimerCount listeners=$activeListenerCount',
    );
  }

  static void logActiveSubscriptions({
    required int total,
    required String source,
  }) {
    debugPrint('ACTIVE_SUBSCRIPTIONS count=$total source=$source');
    if (total > maxActiveRtdbListeners) {
      debugPrint(
        'RESOURCE_GUARD listeners=$total timers=$activeTimerCount '
        'source=$source',
      );
    }
  }
}

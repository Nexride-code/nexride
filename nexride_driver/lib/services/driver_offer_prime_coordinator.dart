import 'dart:async';

import 'package:flutter/widgets.dart';

/// When FCM or app resume signals a new offer, the map screen registers a
/// handler to scan [driver_offer_queue] and open the ride popup — RTDB child
/// events may have already fired while the app was backgrounded.
class DriverOfferPrimeCoordinator {
  DriverOfferPrimeCoordinator._();

  static final DriverOfferPrimeCoordinator instance =
      DriverOfferPrimeCoordinator._();

  void Function(String rideId)? _handler;

  void register(void Function(String rideId) onPrimeOfferQueue) {
    _handler = onPrimeOfferQueue;
  }

  void unregister() {
    _handler = null;
  }

  /// Run once after layout and again shortly after (navigation cold-start).
  /// [rideId] is the FCM-supplied offer rideId, or empty if unknown.
  void requestPrime({String rideId = ''}) {
    final handler = _handler;
    if (handler == null) {
      return;
    }
    final capturedRideId = rideId;
    void run() {
      final h = _handler;
      if (h != null) {
        h(capturedRideId);
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      run();
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 450), run),
      );
    });
  }
}

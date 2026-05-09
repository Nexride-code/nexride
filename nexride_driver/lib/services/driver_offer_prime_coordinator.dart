import 'dart:async';

import 'package:flutter/widgets.dart';

/// When FCM or app resume signals a new offer, the map screen registers a
/// handler to scan [driver_offer_queue] and open the ride popup — RTDB child
/// events may have already fired while the app was backgrounded.
class DriverOfferPrimeCoordinator {
  DriverOfferPrimeCoordinator._();

  static final DriverOfferPrimeCoordinator instance =
      DriverOfferPrimeCoordinator._();

  VoidCallback? _handler;

  void register(VoidCallback onPrimeOfferQueue) {
    _handler = onPrimeOfferQueue;
  }

  void unregister() {
    _handler = null;
  }

  /// Run once after layout and again shortly after (navigation cold-start).
  void requestPrime() {
    final handler = _handler;
    if (handler == null) {
      return;
    }
    void run() {
      final h = _handler;
      if (h != null) {
        h();
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

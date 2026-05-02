import 'dart:async';

import '../trip_sync/trip_state_machine.dart';

enum SimulatedApiStatus { idle, loading, success, failed }

class SimulatedApiResult {
  const SimulatedApiResult({
    required this.ok,
    required this.message,
    this.errorCode = '',
  });

  final bool ok;
  final String message;
  final String errorCode;
}

class BackendAcceptRequest {
  const BackendAcceptRequest({
    required this.rideId,
    required this.driverId,
    required this.driverServiceTypes,
    required this.rideSnapshot,
  });

  final String rideId;
  final String driverId;
  final Set<String> driverServiceTypes;
  final Map<String, dynamic> rideSnapshot;
}

class BackendCompleteTripRequest {
  const BackendCompleteTripRequest({
    required this.rideId,
    required this.rideSnapshot,
    required this.serviceType,
  });

  final String rideId;
  final Map<String, dynamic> rideSnapshot;
  final String serviceType;
}

class BackendCreditWalletRequest {
  const BackendCreditWalletRequest({
    required this.rideId,
    required this.walletId,
    required this.amount,
    required this.transactionType,
  });

  final String rideId;
  final String walletId;
  final double amount;
  final String transactionType;
}

class BackendVerifyPaymentRequest {
  const BackendVerifyPaymentRequest({
    required this.rideId,
    required this.reference,
    required this.amount,
  });

  final String rideId;
  final String reference;
  final double amount;
}

class LocalBackendSimulationService {
  LocalBackendSimulationService();

  final Set<String> _walletCreditedRideIds = <String>{};
  final Set<String> _acceptInFlightRideIds = <String>{};

  Future<SimulatedApiResult> acceptTrip(BackendAcceptRequest request) async {
    if (request.rideId.trim().isEmpty || request.driverId.trim().isEmpty) {
      return const SimulatedApiResult(
        ok: false,
        message: 'Driver or ride details are missing.',
        errorCode: 'invalid_input',
      );
    }
    if (_acceptInFlightRideIds.contains(request.rideId)) {
      return const SimulatedApiResult(
        ok: false,
        message: 'Accept already in progress for this request.',
        errorCode: 'duplicate_accept',
      );
    }
    _acceptInFlightRideIds.add(request.rideId);
    try {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final canonical =
          TripStateMachine.canonicalStateFromSnapshot(request.rideSnapshot);
      final rideService = _serviceTypeKey(request.rideSnapshot['service_type']);
      if (!request.driverServiceTypes.contains(rideService)) {
        return const SimulatedApiResult(
          ok: false,
          message: 'Your account cannot accept this request type.',
          errorCode: 'service_not_allowed',
        );
      }
      if (canonical == TripLifecycleState.tripCompleted ||
          canonical == TripLifecycleState.tripCancelled) {
        return const SimulatedApiResult(
          ok: false,
          message: 'This request is no longer available.',
          errorCode: 'terminal_state',
        );
      }
      return const SimulatedApiResult(
        ok: true,
        message: 'Request is available for accept.',
      );
    } finally {
      _acceptInFlightRideIds.remove(request.rideId);
    }
  }

  Future<SimulatedApiResult> completeTrip(
      BackendCompleteTripRequest request) async {
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final canonical = TripStateMachine.canonicalStateFromSnapshot(
      request.rideSnapshot,
    );
    final reason = TripStateMachine.invalidTransitionReason(
      fromCanonicalState: canonical,
      toCanonicalState: TripLifecycleState.completed,
    );
    if (reason != null) {
      return SimulatedApiResult(
        ok: false,
        message: 'Trip cannot be completed from current state.',
        errorCode: reason,
      );
    }
    return const SimulatedApiResult(
        ok: true, message: 'Trip can be completed.');
  }

  Future<SimulatedApiResult> creditWallet(
      BackendCreditWalletRequest request) async {
    await Future<void>.delayed(const Duration(milliseconds: 150));
    if (request.amount <= 0) {
      return const SimulatedApiResult(
        ok: false,
        message: 'Wallet credit amount must be greater than zero.',
        errorCode: 'invalid_amount',
      );
    }
    if (_walletCreditedRideIds.contains(request.rideId)) {
      return const SimulatedApiResult(
        ok: false,
        message: 'Wallet already credited for this trip.',
        errorCode: 'duplicate_wallet_credit',
      );
    }
    _walletCreditedRideIds.add(request.rideId);
    return const SimulatedApiResult(ok: true, message: 'Wallet credited.');
  }

  Future<SimulatedApiResult> verifyPayment(
      BackendVerifyPaymentRequest request) async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    if (request.reference.trim().isEmpty || request.amount <= 0) {
      return const SimulatedApiResult(
        ok: false,
        message: 'Payment verification failed.',
        errorCode: 'payment_invalid',
      );
    }
    return const SimulatedApiResult(
      ok: true,
      message: 'Payment verified by backend simulation.',
    );
  }

  String _serviceTypeKey(dynamic rawValue) {
    final normalized = rawValue?.toString().trim().toLowerCase() ?? '';
    if (normalized == 'dispatch' ||
        normalized == 'dispatch_delivery' ||
        normalized == 'dispatch/delivery') {
      return 'dispatch_delivery';
    }
    return 'ride';
  }
}

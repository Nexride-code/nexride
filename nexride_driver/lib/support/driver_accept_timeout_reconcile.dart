/// Pure reconciliation when the acceptRide callable times out client-side.
enum DriverAcceptTimeoutReconcileOutcome {
  success,
  retryAllowed,
  alreadyTaken,
  failed,
}

class DriverAcceptTimeoutReconcileResult {
  const DriverAcceptTimeoutReconcileResult({
    required this.outcome,
    this.reason = '',
  });

  final DriverAcceptTimeoutReconcileOutcome outcome;
  final String reason;

  bool get isSuccess => outcome == DriverAcceptTimeoutReconcileOutcome.success;
  bool get retryAllowed =>
      outcome == DriverAcceptTimeoutReconcileOutcome.retryAllowed;
}

String _norm(String? raw) => raw?.trim() ?? '';

bool _uidAssigned(Map<String, dynamic>? ride, String driverId) {
  if (ride == null || driverId.isEmpty) {
    return false;
  }
  for (final key in <String>[
    'driver_id',
    'matched_driver_id',
    'accepted_driver_id',
  ]) {
    final v = _norm(ride[key]?.toString());
    if (v.isNotEmpty && v == driverId) {
      return true;
    }
  }
  return false;
}

String? _assignedOtherDriver(Map<String, dynamic>? ride, String driverId) {
  if (ride == null) {
    return null;
  }
  for (final key in <String>[
    'driver_id',
    'matched_driver_id',
    'accepted_driver_id',
  ]) {
    final v = _norm(ride[key]?.toString());
    if (v.isEmpty ||
        v == driverId ||
        v.toLowerCase() == 'waiting' ||
        v.toLowerCase() == 'null') {
      continue;
    }
    return v;
  }
  return null;
}

bool _rideStillSearching(Map<String, dynamic>? ride) {
  if (ride == null) {
    return false;
  }
  final trip = _norm(ride['trip_state']?.toString()).toLowerCase();
  final status = _norm(ride['status']?.toString()).toLowerCase();
  const openTrip = <String>{
    'searching',
    'requesting',
    'requested',
    'matching',
    'awaiting_match',
    'offered',
    'offer_pending',
    'pending_driver_acceptance',
  };
  const openStatus = <String>{
    'searching',
    'requesting',
    'matching',
    'awaiting_match',
    'offered',
    'pending_driver_acceptance',
  };
  return openTrip.contains(trip) || openStatus.contains(status);
}

DriverAcceptTimeoutReconcileResult reconcileAcceptAfterCallableTimeout({
  required String driverId,
  required Map<String, dynamic>? rideData,
  required Map<String, dynamic>? driverActiveRideData,
  required bool offerQueueExists,
}) {
  final did = _norm(driverId);
  if (did.isEmpty) {
    return const DriverAcceptTimeoutReconcileResult(
      outcome: DriverAcceptTimeoutReconcileOutcome.failed,
      reason: 'driver_id_missing',
    );
  }

  if (_uidAssigned(rideData, did)) {
    return const DriverAcceptTimeoutReconcileResult(
      outcome: DriverAcceptTimeoutReconcileOutcome.success,
      reason: 'assigned_to_driver',
    );
  }

  final activeRideId = _norm(driverActiveRideData?['ride_id']?.toString());
  final targetRideId = _norm(
    rideData?['ride_id']?.toString() ?? rideData?['rideId']?.toString(),
  );
  if (activeRideId.isNotEmpty &&
      targetRideId.isNotEmpty &&
      activeRideId == targetRideId) {
    return const DriverAcceptTimeoutReconcileResult(
      outcome: DriverAcceptTimeoutReconcileOutcome.success,
      reason: 'driver_active_ride_pointer',
    );
  }

  final other = _assignedOtherDriver(rideData, did);
  if (other != null) {
    return const DriverAcceptTimeoutReconcileResult(
      outcome: DriverAcceptTimeoutReconcileOutcome.alreadyTaken,
      reason: 'assigned_to_other_driver',
    );
  }

  if (_rideStillSearching(rideData) && offerQueueExists) {
    return const DriverAcceptTimeoutReconcileResult(
      outcome: DriverAcceptTimeoutReconcileOutcome.retryAllowed,
      reason: 'searching_with_queue',
    );
  }

  if (_uidAssigned(rideData, did)) {
    return const DriverAcceptTimeoutReconcileResult(
      outcome: DriverAcceptTimeoutReconcileOutcome.success,
      reason: 'assigned_to_driver_late_read',
    );
  }

  return const DriverAcceptTimeoutReconcileResult(
    outcome: DriverAcceptTimeoutReconcileOutcome.failed,
    reason: 'no_assignment_and_no_retry',
  );
}

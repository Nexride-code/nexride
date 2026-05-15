import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart' as rtdb;
import 'package:flutter/foundation.dart';

import '../trip_sync/trip_state_machine.dart';
import 'rider_ride_cloud_functions_service.dart';

class RiderActiveTripSession {
  const RiderActiveTripSession({
    required this.rideId,
    required this.status,
    required this.tripState,
    required this.riderId,
    required this.driverId,
    required this.pickupAddress,
    required this.destinationAddress,
    required this.updatedAt,
    required this.rideData,
  });

  final String rideId;
  final String status;
  final String tripState;
  final String riderId;
  final String driverId;
  final String pickupAddress;
  final String destinationAddress;
  final int updatedAt;
  final Map<String, dynamic> rideData;
}

class RiderActiveTripSessionService {
  RiderActiveTripSessionService._();

  static final RiderActiveTripSessionService instance =
      RiderActiveTripSessionService._();

  final ValueNotifier<RiderActiveTripSession?> sessionNotifier =
      ValueNotifier<RiderActiveTripSession?>(null);
  final rtdb.DatabaseReference _rideRequestsRef =
      rtdb.FirebaseDatabase.instance.ref('ride_requests');

  StreamSubscription<rtdb.DatabaseEvent>? _rideSubscription;
  String? _attachedRideId;
  bool _isRestoring = false;
  static const Duration _staleSearchingRestoreTimeout = Duration(minutes: 3);
  // A driver-assigned ride that hasn't progressed to arriving/on_trip in 30 min is stale.
  static const Duration _staleAssignedTimeout = Duration(minutes: 30);

  static const Set<String> _activeStatuses = <String>{
    'requested',
    'searching',
    'searching_driver',
    'matching',
    // Treat only driver-committed/active-trip states as active for UI gating.
    'pending_driver_action',
    'assigned',
    'accepted',
    'arriving',
    'arrived',
    'on_trip',
  };

  static const Set<String> _terminalStatuses = <String>{
    'cancelled',
    'driver_cancelled',
    'rider_cancelled',
    'completed',
    'expired',
  };

  RiderActiveTripSession? get currentSession => sessionNotifier.value;

  /// Cancel before the trip is in progress (matches map-screen policy).
  bool allowsRiderBannerCancel(RiderActiveTripSession session) {
    final st = session.status.trim().toLowerCase();
    if (st == 'on_trip') {
      return false;
    }
    if (_terminalStatuses.contains(st)) {
      return false;
    }
    return true;
  }

  Future<void> cancelActiveTripViaCloudFunction(
    RiderRideCloudFunctionsService rideCloud, {
    String cancelReason = 'rider_cancelled',
  }) async {
    final session = sessionNotifier.value;
    if (session == null) {
      return;
    }
    await rideCloud.cancelRideRequest(
      rideId: session.rideId,
      cancelReason: cancelReason,
    );
    clearSession(
      reason: 'rider_cancel_request',
      source: 'cancel_via_cf',
    );
  }

  bool get hasActiveTrip {
    final session = sessionNotifier.value;
    if (session == null) {
      return false;
    }
    return _activeStatuses.contains(session.status);
  }

  Future<void> restoreActiveTripForCurrentUser({
    String source = 'manual_restore',
  }) async {
    if (_isRestoring) {
      return;
    }
    final riderId = FirebaseAuth.instance.currentUser?.uid.trim();
    if (riderId == null || riderId.isEmpty) {
      clearSession(reason: 'missing_auth_uid', source: source);
      return;
    }

    _isRestoring = true;
    try {
      final snapshot = await _rideRequestsRef
          .orderByChild('rider_id')
          .equalTo(riderId)
          .get();
      if (!snapshot.exists || snapshot.value is! Map) {
        clearSession(reason: 'restore_no_ride_found', source: source);
        return;
      }

      final rides = Map<Object?, Object?>.from(snapshot.value as Map);
      String? latestRideId;
      Map<String, dynamic>? latestRideData;
      var latestTs = -1;
      rides.forEach((dynamic rawId, dynamic rawValue) {
        if (rawValue is! Map) {
          return;
        }
        final rideData = Map<String, dynamic>.from(rawValue);
        final status = _canonicalRiderUiStatus(rideData);
        if (_terminalStatuses.contains(status)) {
          return;
        }
        if (!_activeStatuses.contains(status)) {
          return;
        }
        if (_isStaleSearchingRideForRecovery(status: status, rideData: rideData)) {
          debugPrint(
            '[RIDER_ACTIVE_TRIP_RESTORE] source=$source '
            'rideId=${rawId?.toString() ?? ''} '
            'status=$status action=ignore_stale_searching',
          );
          return;
        }
        if (_isStaleAssignedRideForRecovery(status: status, rideData: rideData)) {
          debugPrint(
            '[RIDER_ACTIVE_TRIP_RESTORE] source=$source '
            'rideId=${rawId?.toString() ?? ''} '
            'status=$status action=ignore_stale_assigned',
          );
          return;
        }
        final ts = _activityTs(rideData);
        if (ts >= latestTs) {
          latestTs = ts;
          latestRideId = rawId?.toString();
          latestRideData = rideData;
        }
      });

      if (latestRideId == null || latestRideData == null) {
        clearSession(reason: 'restore_active_not_found', source: source);
        return;
      }
      debugPrint(
        '[RIDER_ACTIVE_TRIP_RESTORE] source=$source rideId=$latestRideId status=${_canonicalRiderUiStatus(latestRideData!)}',
      );
      await attachToRide(
        latestRideId!,
        seedData: latestRideData,
        source: 'restore:$source',
      );
    } catch (error) {
      debugPrint('[RIDER_ACTIVE_TRIP_RESTORE] source=$source error=$error');
    } finally {
      _isRestoring = false;
    }
  }

  Future<void> attachToRide(
    String rideId, {
    Map<String, dynamic>? seedData,
    String source = 'manual_attach',
  }) async {
    final normalizedRideId = rideId.trim();
    if (normalizedRideId.isEmpty) {
      return;
    }
    if (_attachedRideId == normalizedRideId && _rideSubscription != null) {
      if (seedData != null) {
        _emitUpdate(normalizedRideId, seedData, source: source);
      }
      return;
    }

    await _rideSubscription?.cancel();
    _rideSubscription = null;
    _attachedRideId = normalizedRideId;
    debugPrint(
      '[RIDER_ACTIVE_TRIP_ATTACH] source=$source rideId=$normalizedRideId',
    );
    if (seedData != null) {
      _emitUpdate(normalizedRideId, seedData, source: '$source:seed');
    }

    _rideSubscription = _rideRequestsRef.child(normalizedRideId).onValue.listen(
      (rtdb.DatabaseEvent event) {
        if (!event.snapshot.exists || event.snapshot.value is! Map) {
          clearSession(
            reason: 'listener_missing_or_invalid',
            source: 'listener:$normalizedRideId',
          );
          return;
        }
        final data = Map<String, dynamic>.from(event.snapshot.value as Map);
        _emitUpdate(normalizedRideId, data, source: 'listener');
      },
      onError: (Object error) {
        debugPrint(
          '[RIDER_ACTIVE_TRIP_UPDATE] source=listener rideId=$normalizedRideId error=$error',
        );
      },
    );
  }

  void updateFromRideSnapshot(
    String rideId,
    Map<String, dynamic> rideData, {
    String source = 'external_snapshot',
  }) {
    final normalizedRideId = rideId.trim();
    if (normalizedRideId.isEmpty) {
      return;
    }
    _emitUpdate(normalizedRideId, rideData, source: source);
  }

  void clearSession({
    required String reason,
    String source = 'manual_clear',
    bool cancelListener = true,
  }) {
    if (cancelListener) {
      unawaited(_rideSubscription?.cancel());
      _rideSubscription = null;
      _attachedRideId = null;
    }
    if (sessionNotifier.value != null) {
      debugPrint('[RIDER_ACTIVE_TRIP_CLEAR] source=$source reason=$reason');
    }
    sessionNotifier.value = null;
  }

  void _emitUpdate(
    String rideId,
    Map<String, dynamic> rideData, {
    required String source,
  }) {
    final status = _canonicalRiderUiStatus(rideData);
    final tripState = _readText(rideData['trip_state']);
    // Suppress stale assigned/accepted rides — driver was assigned but never
    // progressed to arriving/on_trip within the expected window.
    if (_isStaleAssignedRideForRecovery(status: status, rideData: rideData)) {
      debugPrint(
        '[RIDER_ACTIVE_TRIP_UPDATE] source=$source rideId=$rideId status=$status '
        'action=suppress_stale_assigned',
      );
      clearSession(
        reason: 'stale_assigned_suppressed',
        source: source,
        cancelListener: false,
      );
      return;
    }
    if (_terminalStatuses.contains(status)) {
      if (_readText(rideData['cancel_reason']) == 'driver_cancelled') {
        debugPrint(
          '[RIDER_DRIVER_CANCELLED] rideId=$rideId trip_state=$tripState status=$status',
        );
      }
      debugPrint(
        '[RIDER_TERMINAL_STATE] rideId=$rideId status=$status trip_state=$tripState',
      );
      clearSession(
        reason: 'terminal_state:$status',
        source: source,
        cancelListener: false,
      );
      return;
    }

    final session = RiderActiveTripSession(
      rideId: rideId,
      status: status,
      tripState: tripState,
      riderId: _readText(rideData['rider_id']),
      driverId: _rideDriverId(rideData),
      pickupAddress: _readText(rideData['pickup_address']),
      destinationAddress: _readText(rideData['destination_address']),
      updatedAt: _activityTs(rideData),
      rideData: Map<String, dynamic>.from(rideData),
    );
    sessionNotifier.value = session;
    debugPrint(
      '[RIDER_ACTIVE_TRIP_UPDATE] source=$source rideId=$rideId status=$status trip_state=$tripState',
    );
  }

  static int _activityTs(Map<String, dynamic> rideData) {
    for (final key in <String>['updated_at', 'accepted_at', 'created_at']) {
      final value = rideData[key];
      if (value is num) {
        return value.toInt();
      }
      final parsed = int.tryParse(value?.toString() ?? '');
      if (parsed != null && parsed > 0) {
        return parsed;
      }
    }
    return 0;
  }

  static String _readText(dynamic value) {
    return value?.toString().trim() ?? '';
  }

  static String _rideDriverId(Map<String, dynamic> rideData) {
    final direct = _readText(rideData['driver_id']);
    if (direct.isNotEmpty && direct.toLowerCase() != 'waiting') {
      return direct;
    }
    return _readText(rideData['matched_driver_id']);
  }

  static String _canonicalRiderUiStatus(Map<String, dynamic> rideData) {
    return TripStateMachine.riderUiStatusFromRideData(rideData);
  }

  static bool _isStaleSearchingRideForRecovery({
    required String status,
    required Map<String, dynamic> rideData,
  }) {
    if (status != 'searching' && status != 'requested') {
      return false;
    }
    final driverId = _rideDriverId(rideData);
    if (driverId.isNotEmpty) {
      return false;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final updatedAt = _activityTs(rideData);
    if (updatedAt <= 0) {
      return false;
    }
    return now - updatedAt > _staleSearchingRestoreTimeout.inMilliseconds;
  }

  /// A driver-assigned ride is stale when it has been in accepted/assigned state
  /// for longer than [_staleAssignedTimeout] without progressing to arriving or on_trip.
  static bool _isStaleAssignedRideForRecovery({
    required String status,
    required Map<String, dynamic> rideData,
  }) {
    const assignedStatuses = <String>{
      'accepted',
      'assigned',
      'pending_driver_action',
    };
    if (!assignedStatuses.contains(status)) {
      return false;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    // Prefer accepted_at; fall back to updated_at / created_at.
    int ts = 0;
    for (final key in <String>['accepted_at', 'updated_at', 'created_at']) {
      final v = rideData[key];
      final parsed = v is num ? v.toInt() : int.tryParse(v?.toString() ?? '');
      if (parsed != null && parsed > 0) {
        ts = parsed;
        break;
      }
    }
    if (ts <= 0) {
      return false;
    }
    return now - ts > _staleAssignedTimeout.inMilliseconds;
  }
}

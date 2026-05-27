import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart' as rtdb;
import 'package:flutter/foundation.dart';

import '../support/nex_trace.dart';
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

  static const Set<String> _restorableTripStates = TripStateMachine.restorableStates;

  RiderActiveTripSession? get currentSession => sessionNotifier.value;

  /// Cancel before the trip is in progress (matches map-screen policy).
  bool allowsRiderBannerCancel(RiderActiveTripSession session) {
    final canon = TripStateMachine.normalizeTripState(session.tripState);
    if (canon == TripLifecycleState.onTrip) {
      return false;
    }
    if (TripStateMachine.isTerminal(canon)) {
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
    final canon = TripStateMachine.normalizeTripState(session.tripState);
    return _restorableTripStates.contains(canon);
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

    NexTrace.log(
      event: 'SESSION_RESTORE',
      uid: riderId,
      role: 'rider',
      source: source,
    );

    _isRestoring = true;
    try {
      NexTrace.mark('session_restore_read');
      final snapshot = await _rideRequestsRef
          .orderByChild('rider_id')
          .equalTo(riderId)
          .get();
      NexTrace.rtdbRead(
        path: 'ride_requests[orderByChild=rider_id]',
        role: 'rider',
        source: source,
        elapsedMs: NexTrace.elapsedMs('session_restore_read'),
      );
      final rides = <String, dynamic>{};
      if (snapshot.exists && snapshot.value is Map) {
        final raw = Map<Object?, Object?>.from(snapshot.value as Map);
        raw.forEach((id, value) {
          if (id != null && value is Map) {
            rides[id.toString()] = Map<String, dynamic>.from(value);
          }
        });
      }
      final ptrSnap = await rtdb.FirebaseDatabase.instance
          .ref('rider_active_trip/$riderId')
          .get();
      final ptrVal = ptrSnap.value;
      if (ptrVal is Map) {
        final ptrMap = Map<String, dynamic>.from(ptrVal);
        final ptrRideId = _readText(ptrMap['ride_id'] ?? ptrMap['rideId']);
        if (ptrRideId.isNotEmpty) {
          final directSnap = await _rideRequestsRef.child(ptrRideId).get();
          if (directSnap.exists && directSnap.value is Map) {
            rides[ptrRideId] =
                Map<String, dynamic>.from(directSnap.value as Map);
          }
        }
      }
      if (rides.isEmpty) {
        clearSession(reason: 'restore_no_ride_found', source: source);
        return;
      }
      String? latestRideId;
      Map<String, dynamic>? latestRideData;
      var latestTs = -1;
      rides.forEach((rawId, rawValue) {
        final rideData = rawValue is Map<String, dynamic>
            ? rawValue
            : rawValue is Map
                ? Map<String, dynamic>.from(rawValue)
                : null;
        if (rideData == null) {
          return;
        }
        final riderIdOnRide = _readText(rideData['rider_id']);
        if (riderIdOnRide.isNotEmpty && riderIdOnRide != riderId) {
          return;
        }
        final canon = TripStateMachine.normalizeTripState(rideData['trip_state']);
        if (TripStateMachine.isTerminal(canon)) {
          return;
        }
        if (!_restorableTripStates.contains(canon)) {
          return;
        }
        final status = _canonicalRiderUiStatus(rideData);
        if (_isStaleSearchingRideForRecovery(
          tripState: canon,
          rideData: rideData,
        )) {
          debugPrint(
            '[RIDER_ACTIVE_TRIP_RESTORE] source=$source '
            'rideId=${rawId?.toString() ?? ''} '
            'status=$status action=ignore_stale_searching',
          );
          return;
        }
        if (_isStaleAssignedRideForRecovery(tripState: canon, rideData: rideData)) {
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
    bool bindRtdbListener = true,
  }) async {
    final normalizedRideId = rideId.trim();
    if (normalizedRideId.isEmpty) {
      return;
    }
    if (seedData != null) {
      final canon = TripStateMachine.canonicalStateFromSnapshot(seedData);
      if (TripStateMachine.isTerminal(canon)) {
        clearSession(
          reason: 'attach_reject_terminal_seed',
          source: source,
        );
        debugPrint(
          '[RIDER_ACTIVE_TRIP_ATTACH_REJECTED] rideId=$normalizedRideId '
          'source=$source canonical=$canon',
        );
        return;
      }
    }
    if (_attachedRideId == normalizedRideId &&
        (_rideSubscription != null || !bindRtdbListener)) {
      if (seedData != null) {
        _emitUpdate(normalizedRideId, seedData, source: source);
      }
      if (!bindRtdbListener && _rideSubscription != null) {
        await releaseRtdbListener(
          rideId: normalizedRideId,
          reason: 'map_screen_owns_listener',
        );
      }
      return;
    }

    await _rideSubscription?.cancel();
    _rideSubscription = null;
    _attachedRideId = normalizedRideId;
    debugPrint(
      '[RIDER_ACTIVE_TRIP_ATTACH] source=$source rideId=$normalizedRideId '
      'bindRtdbListener=$bindRtdbListener',
    );
    if (seedData != null) {
      _emitUpdate(normalizedRideId, seedData, source: '$source:seed');
    }
    if (!bindRtdbListener) {
      return;
    }

    NexTrace.rtdbListenerAttach(
      path: 'ride_requests/$normalizedRideId',
      listenerOwner: 'RiderActiveTripSessionService',
      rideId: normalizedRideId,
      role: 'rider',
      source: source,
    );
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

  /// MapScreen owns the primary ride listener during an active trip.
  Future<void> releaseRtdbListener({
    required String rideId,
    String reason = 'external_owner',
  }) async {
    final normalizedRideId = rideId.trim();
    if (normalizedRideId.isEmpty) {
      return;
    }
    if (_attachedRideId != normalizedRideId || _rideSubscription == null) {
      return;
    }
    await _rideSubscription!.cancel();
    _rideSubscription = null;
    NexTrace.rtdbListenerDispose(
      path: 'ride_requests/$normalizedRideId',
      listenerOwner: 'RiderActiveTripSessionService',
      rideId: normalizedRideId,
      role: 'rider',
      source: reason,
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
    final tripState = TripStateMachine.normalizeTripState(rideData['trip_state']);
    if (TripStateMachine.isTerminal(tripState)) {
      clearSession(
        reason: 'terminal_trip_state:$tripState',
        source: source,
        cancelListener: false,
      );
      return;
    }
    // Suppress stale assigned rides — driver was assigned but never progressed.
    if (_isStaleAssignedRideForRecovery(tripState: tripState, rideData: rideData)) {
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
    required String tripState,
    required Map<String, dynamic> rideData,
  }) {
    if (tripState != TripLifecycleState.searching) {
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
    required String tripState,
    required Map<String, dynamic> rideData,
  }) {
    if (tripState != TripLifecycleState.assigned) {
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

import 'package:firebase_database/firebase_database.dart' as rtdb;
import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../support/realtime_database_error_support.dart';
import 'support_ticket_bridge_service.dart';

class DriverTripSafetyService {
  DriverTripSafetyService({rtdb.FirebaseDatabase? database})
      : _database = database ?? rtdb.FirebaseDatabase.instance;

  final rtdb.FirebaseDatabase _database;

  rtdb.DatabaseReference get _rootRef => _database.ref();
  SupportTicketBridgeService get _supportTicketBridge =>
      const SupportTicketBridgeService();

  Future<void> logRideStateChange({
    required String rideId,
    required String riderId,
    required String driverId,
    required String serviceType,
    required String status,
    required String source,
    Map<String, dynamic>? rideData,
  }) async {
    // ride_requests + route_log mirrors are Cloud Function authority only.
    return;
  }

  Future<void> logCheckpoint({
    required String rideId,
    required String riderId,
    required String driverId,
    required String serviceType,
    required String status,
    required LatLng position,
    required String source,
  }) async {
    final checkpointRef =
        _rootRef.child('trip_route_logs/$rideId/checkpoints').push();
    final payload = <String, dynamic>{
      'trip_route_logs/$rideId/checkpoints/${checkpointRef.key}':
          <String, dynamic>{
        'checkpointId': checkpointRef.key,
        'rideId': rideId,
        'riderId': riderId,
        'driverId': driverId,
        'serviceType': serviceType,
        'status': status,
        'source': source,
        'lat': position.latitude,
        'lng': position.longitude,
        'createdAt': rtdb.ServerValue.timestamp,
      },
      'trip_route_logs/$rideId/lastCheckpoint': <String, dynamic>{
        'lat': position.latitude,
        'lng': position.longitude,
        'status': status,
        'source': source,
        'updatedAt': rtdb.ServerValue.timestamp,
      },
      'trip_route_logs/$rideId/updatedAt': rtdb.ServerValue.timestamp,
    };

    if (!kDebugMode) {
      return;
    }

    await runOptionalRealtimeDatabaseWrite(
      source: 'trip_safety.logCheckpoint',
      path: 'trip_route_logs/$rideId/checkpoints',
      operation: 'multi_path_update',
      rideId: rideId,
      dedupeKey: 'trip_checkpoint|$rideId|$status|$source',
      action: () => _rootRef.update(payload),
    );

    await _syncSharedTripCheckpoint(
      rideId: rideId,
      status: status,
      position: position,
    );
  }

  Future<void> createSafetyFlag({
    required String rideId,
    required String riderId,
    required String driverId,
    required String serviceType,
    required String flagType,
    required String source,
    required String message,
    double? distanceFromRouteMeters,
    String? status,
    String? severity,
  }) async {
    final tolerance = await _configuredToleranceMeters();
    final flagRef = _rootRef.child('trip_safety_flags').push();
    await flagRef.set(<String, dynamic>{
      'flagId': flagRef.key,
      'rideId': rideId,
      'riderId': riderId,
      'driverId': driverId,
      'serviceType': serviceType,
      'flagType': flagType,
      'source': source,
      'status': status ?? 'manual_review',
      'severity': severity ?? 'medium',
      'message': message,
      'distanceFromRouteMeters': distanceFromRouteMeters,
      'configuredToleranceMeters': tolerance,
      'createdAt': rtdb.ServerValue.timestamp,
      'updatedAt': rtdb.ServerValue.timestamp,
    });
  }

  Future<void> createTripDispute({
    required String rideId,
    required String riderId,
    required String driverId,
    required String serviceType,
    required String reason,
    required String message,
    required String source,
  }) async {
    final disputeRef = _rootRef.child('trip_disputes').push();
    await disputeRef.set(<String, dynamic>{
      'disputeId': disputeRef.key,
      'rideId': rideId,
      'riderId': riderId,
      'driverId': driverId,
      'serviceType': serviceType,
      'reason': reason,
      'message': message,
      'source': source,
      'status': 'pending',
      'createdAt': rtdb.ServerValue.timestamp,
      'updatedAt': rtdb.ServerValue.timestamp,
    });

    try {
      await _supportTicketBridge.upsertTripDisputeTicket(
        sourceReference: disputeRef.key ?? rideId,
        rideId: rideId,
        riderId: riderId,
        driverId: driverId,
        serviceType: serviceType,
        reason: reason,
        message: message,
        source: source,
        createdByType: 'driver',
      );
    } catch (_) {}
  }

  Future<void> _syncSharedTripStatus({
    required String rideId,
    required String status,
    Map<String, dynamic>? rideData,
  }) async {
    final shareMeta = await _activeShareMetaForRide(rideId);
    if (shareMeta == null) {
      return;
    }

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final updates = <String, dynamic>{
      'status': status,
      'updated_at': rtdb.ServerValue.timestamp,
    };

    final tripState = rideData?['trip_state']?.toString().trim() ?? '';
    if (tripState.isNotEmpty) {
      updates['trip_state'] = tripState;
    }

    final acceptedAt = _asInt(rideData?['accepted_at']);
    if (acceptedAt != null) {
      updates['accepted_at'] = acceptedAt;
    }

    final arrivingAt = _asInt(rideData?['arriving_at']);
    if (arrivingAt != null) {
      updates['arriving_at'] = arrivingAt;
    }

    final arrivedAt = _asInt(rideData?['arrived_at']);
    if (arrivedAt != null) {
      updates['arrived_at'] = arrivedAt;
    }

    final startedAt = _asInt(rideData?['started_at']);
    if (startedAt != null) {
      updates['started_at'] = startedAt;
    }

    final completedAt = _asInt(rideData?['completed_at']);
    if (completedAt != null) {
      updates['completed_at'] = completedAt;
    }

    final cancelledAt = _asInt(rideData?['cancelled_at']);
    if (cancelledAt != null) {
      updates['cancelled_at'] = cancelledAt;
    }

    if (acceptedAt == null && status == 'accepted') {
      updates['accepted_at'] = nowMs;
    }
    if (arrivingAt == null && status == 'arriving') {
      updates['arriving_at'] = nowMs;
    }
    if (arrivedAt == null && status == 'arrived') {
      updates['arrived_at'] = nowMs;
    }
    if (startedAt == null && (status == 'in_progress' || status == 'on_trip')) {
      updates['started_at'] = nowMs;
    }
    if (completedAt == null && status == 'completed') {
      updates['completed_at'] = nowMs;
    }
    if (cancelledAt == null && status == 'cancelled') {
      updates['cancelled_at'] = nowMs;
    }

    try {
      await _rootRef.child('shared_trips/${shareMeta.token}').update(updates);
    } catch (error) {
      if (!isRealtimeDatabasePermissionDenied(error)) {
        rethrow;
      }
    }
  }

  Future<void> _syncSharedTripCheckpoint({
    required String rideId,
    required String status,
    required LatLng position,
  }) async {
    final shareMeta = await _activeShareMetaForRide(rideId);
    if (shareMeta == null) {
      return;
    }

    try {
      await _rootRef.child('shared_trips/${shareMeta.token}').update({
        'status': status,
        'live_location': <String, dynamic>{
          'lat': position.latitude,
          'lng': position.longitude,
          'updated_at': rtdb.ServerValue.timestamp,
        },
        'updated_at': rtdb.ServerValue.timestamp,
      });
    } catch (error) {
      if (!isRealtimeDatabasePermissionDenied(error)) {
        rethrow;
      }
    }
  }

  Future<_DriverShareMeta?> _activeShareMetaForRide(String rideId) async {
    if (rideId.trim().isEmpty) {
      return null;
    }

    final snapshot = await _rootRef.child('ride_requests/$rideId/share').get();
    final shareData = _asStringDynamicMap(snapshot.value);
    if (shareData == null || shareData['enabled'] != true) {
      return null;
    }

    final token = shareData['token']?.toString().trim() ?? '';
    final expiresAt = _asInt(shareData['expires_at']) ?? 0;
    if (token.isEmpty) {
      return null;
    }

    if (expiresAt > 0 && expiresAt <= DateTime.now().millisecondsSinceEpoch) {
      return null;
    }

    return _DriverShareMeta(token: token);
  }

  Map<String, dynamic>? _asStringDynamicMap(dynamic value) {
    if (value is! Map) {
      return null;
    }

    return value.map<String, dynamic>(
      (key, nestedValue) => MapEntry(key.toString(), nestedValue),
    );
  }

  int? _asInt(dynamic value) {
    if (value is int) {
      return value;
    }

    if (value is num) {
      return value.toInt();
    }

    if (value is String) {
      return int.tryParse(value);
    }

    return null;
  }

  Future<void> logRouteConsistencyCheck({
    required String rideId,
    required String riderId,
    required String driverId,
    required String serviceType,
    required String source,
    required Map<String, dynamic> riderRouteBasis,
    required Map<String, dynamic> driverRouteBasis,
    required List<String> mismatchReasons,
  }) async {
    if (!kDebugMode) {
      return;
    }
    final checkRef = _rootRef
        .child('trip_route_logs/$rideId/routeConsistency/checks')
        .push();
    final isAligned = mismatchReasons.isEmpty;
    final reviewStatus = isAligned ? 'aligned' : 'manual_review';

    final payload = <String, dynamic>{
      'trip_route_logs/$rideId/routeConsistency/driverLastCheck':
          <String, dynamic>{
        'checkId': checkRef.key,
        'rideId': rideId,
        'riderId': riderId,
        'driverId': driverId,
        'serviceType': serviceType,
        'source': source,
        'status': reviewStatus,
        'isAligned': isAligned,
        'mismatchReasons': mismatchReasons,
        'riderRouteBasis': riderRouteBasis,
        'driverRouteBasis': driverRouteBasis,
        'createdAt': rtdb.ServerValue.timestamp,
      },
      'trip_route_logs/$rideId/routeConsistency/checks/${checkRef.key}':
          <String, dynamic>{
        'checkId': checkRef.key,
        'rideId': rideId,
        'riderId': riderId,
        'driverId': driverId,
        'serviceType': serviceType,
        'source': source,
        'status': reviewStatus,
        'isAligned': isAligned,
        'mismatchReasons': mismatchReasons,
        'riderRouteBasis': riderRouteBasis,
        'driverRouteBasis': driverRouteBasis,
        'createdAt': rtdb.ServerValue.timestamp,
        'updatedAt': rtdb.ServerValue.timestamp,
      },
      'trip_route_logs/$rideId/updatedAt': rtdb.ServerValue.timestamp,
    };
    await runOptionalRealtimeDatabaseWrite(
      source: 'trip_safety.logRouteConsistencyCheck',
      path: 'trip_route_logs/$rideId/routeConsistency',
      operation: 'multi_path_update',
      rideId: rideId,
      action: () => _rootRef.update(payload),
    );
  }

  /// Settlement, commission, and payout fields are written only by Cloud Functions
  /// (`completeTrip`, payment webhooks, `closeJob`). Client is read-only for mirrors.
  Future<void> updateSettlementHook({
    required String rideId,
    required String riderId,
    required String driverId,
    required String serviceType,
    required String source,
    required String settlementStatus,
    required String completionState,
    required String paymentMethod,
    String? reviewStatus,
    int? reportedOutstandingAmountNgn,
    String? note,
    Map<String, dynamic>? evidence,
    Map<String, dynamic>? rideData,
    Map<String, dynamic>? settlement,
  }) async {
    // Backend authority only — no RTDB writes from the driver app.
  }

  Future<double> _configuredToleranceMeters() async {
    final snapshot = await _rootRef.child('app_config/driver_trust_rules').get();
    if (snapshot.value is! Map) {
      return 250;
    }
    final rules = Map<String, dynamic>.from(snapshot.value as Map);
    final value = rules['offRouteToleranceMeters'];
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '') ?? 250;
  }

  Map<String, dynamic> _map(dynamic value) {
    if (value is Map) {
      return value.map<String, dynamic>(
        (dynamic key, dynamic entryValue) =>
            MapEntry(key.toString(), entryValue),
      );
    }
    return <String, dynamic>{};
  }

  String _text(dynamic value) {
    if (value == null || value is Map || value is List) {
      return '';
    }
    return value.toString().trim();
  }

  double? _doubleOrNull(dynamic value) {
    if (value is double) {
      return value;
    }
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '');
  }

}

class _DriverShareMeta {
  const _DriverShareMeta({required this.token});

  final String token;
}

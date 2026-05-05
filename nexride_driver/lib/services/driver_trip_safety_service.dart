import 'package:firebase_database/firebase_database.dart' as rtdb;
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../support/driver_profile_support.dart';
import '../support/realtime_database_error_support.dart';
import 'ride_cloud_functions_service.dart';
import 'support_ticket_bridge_service.dart';

class DriverTripSafetyService {
  DriverTripSafetyService({rtdb.FirebaseDatabase? database})
      : _database = database ?? rtdb.FirebaseDatabase.instance;

  final rtdb.FirebaseDatabase _database;

  rtdb.DatabaseReference get _rootRef => _database.ref();
  RideCloudFunctionsService get _rideCloud => RideCloudFunctionsService();
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
    final eventRef = _rootRef.child('trip_route_logs/$rideId/events').push();
    final payload = <String, dynamic>{
      'trip_route_logs/$rideId/rideId': rideId,
      'trip_route_logs/$rideId/riderId': riderId,
      'trip_route_logs/$rideId/driverId': driverId,
      'trip_route_logs/$rideId/serviceType': serviceType,
      'trip_route_logs/$rideId/status': status,
      'trip_route_logs/$rideId/trip_state': rideData?['trip_state'],
      'trip_route_logs/$rideId/updatedAt': rtdb.ServerValue.timestamp,
      'trip_route_logs/$rideId/events/${eventRef.key}': <String, dynamic>{
        'eventId': eventRef.key,
        'rideId': rideId,
        'riderId': riderId,
        'driverId': driverId,
        'serviceType': serviceType,
        'status': status,
        'trip_state': rideData?['trip_state'],
        'source': source,
        'pickupAddress': rideData?['pickup_address'],
        'destinationAddress': rideData?['destination_address'] ??
            rideData?['final_destination_address'],
        'createdAt': rtdb.ServerValue.timestamp,
      },
      'ride_requests/$rideId/route_log_updated_at': rtdb.ServerValue.timestamp,
      'ride_requests/$rideId/route_log_last_event_at':
          rtdb.ServerValue.timestamp,
      'ride_requests/$rideId/route_log_last_event_status': status,
      'ride_requests/$rideId/route_log_last_event_source': source,
      'ride_requests/$rideId/has_route_logs': true,
    };

    await runOptionalRealtimeDatabaseWrite(
      source: 'trip_safety.logRideStateChange',
      path: 'trip_route_logs/$rideId+ride_requests/$rideId(route_log)',
      operation: 'multi_path_update',
      rideId: rideId,
      action: () => _rootRef.update(payload),
    );

    await _syncSharedTripStatus(
      rideId: rideId,
      status: status,
      rideData: rideData,
    );
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
      'ride_requests/$rideId/route_log_updated_at': rtdb.ServerValue.timestamp,
      'ride_requests/$rideId/route_log_last_checkpoint_at':
          rtdb.ServerValue.timestamp,
      'ride_requests/$rideId/route_log_last_checkpoint_status': status,
      'ride_requests/$rideId/has_route_logs': true,
      'ride_requests/$rideId/has_route_checkpoints': true,
      if (status == 'on_trip')
        'ride_requests/$rideId/has_started_route_checkpoints': true,
      if (status == 'on_trip')
        'ride_requests/$rideId/route_log_trip_started_checkpoint_at':
            rtdb.ServerValue.timestamp,
      if (status == 'on_trip')
        'ride_requests/$rideId/route_log_timeout_at': null,
    };

    await runOptionalRealtimeDatabaseWrite(
      source: 'trip_safety.logCheckpoint',
      path: 'trip_route_logs/$rideId+ride_requests/$rideId(route_log)',
      operation: 'multi_path_update',
      rideId: rideId,
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

    final normalizedFlag = flagType.trim().toLowerCase();
    final normalizedSeverity = (severity ?? '').trim().toLowerCase();
    final shouldEscalate =
        normalizedFlag.contains('sos') ||
        normalizedSeverity == 'critical' ||
        normalizedSeverity == 'high';
    if (shouldEscalate) {
      try {
        await _rideCloud.escalateSafetyIncident(
          rideId: rideId,
          riderId: riderId,
          driverId: driverId,
          serviceType: serviceType,
          flagType: flagType,
          details: message,
          sourceFlagId: flagRef.key ?? '',
        );
      } catch (_) {}
    }
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
    final eventRef =
        _rootRef.child('trip_settlement_hooks/$rideId/events').push();
    final amountDue = reportedOutstandingAmountNgn ?? 0;
    final normalizedEvidence = _map(evidence);
    final normalizedRideData = _map(rideData);
    final normalizedSettlement = _map(
      settlement ?? normalizedRideData['settlement'],
    );
    final grossFare = _firstPositiveDouble(<dynamic>[
      normalizedSettlement['grossFareNgn'],
      normalizedSettlement['grossFare'],
      normalizedRideData['grossFare'],
      normalizedRideData['fare'],
    ]);
    final normalizedSettlementStatus = settlementStatus.trim().isEmpty
        ? 'trip_completed'
        : settlementStatus.trim();
    final normalizedReviewStatus = (reviewStatus ?? 'not_required').trim();
    final modelSnapshot = _map(normalizedSettlement['businessModelSnapshot']);
    final selectedModel =
        (modelSnapshot['selectedModel'] ?? modelSnapshot['selected_model'])
            ?.toString()
            .trim()
            .toLowerCase();
    if (selectedModel == 'subscription' && normalizedSettlement.isNotEmpty) {
      final grossFromSettlement = _firstPositiveDouble(<dynamic>[
        normalizedSettlement['grossFareNgn'],
        normalizedSettlement['grossFare'],
        grossFare,
      ]);
      normalizedSettlement['commissionAmountNgn'] = 0;
      normalizedSettlement['commissionAmount'] = 0;
      normalizedSettlement['commission'] = 0;
      normalizedSettlement['driverPayoutNgn'] = grossFromSettlement;
      normalizedSettlement['driverPayout'] = grossFromSettlement;
      normalizedSettlement['netEarningNgn'] = grossFromSettlement;
      normalizedSettlement['netEarning'] = grossFromSettlement;
      normalizedSettlement['appliedModel'] = 'subscription';
      normalizedSettlement['effectiveModel'] = 'subscription';
    }
    final countsTowardWallet =
        driverSettlementCountsTowardWallet(normalizedSettlementStatus);
    final driverTripRecord = _buildDriverTripRecord(
      rideId: rideId,
      riderId: riderId,
      driverId: driverId,
      serviceType: serviceType,
      paymentMethod: paymentMethod,
      settlementStatus: normalizedSettlementStatus,
      reviewStatus: normalizedReviewStatus,
      amountDue: amountDue,
      grossFare: grossFare,
      rideData: normalizedRideData,
      settlement: normalizedSettlement,
      countsTowardWallet: countsTowardWallet,
    );

    final safeDriverUpdates = <String, dynamic>{
      'trip_route_logs/$rideId/settlement': <String, dynamic>{
        'rideId': rideId,
        'paymentMethod':
            paymentMethod.trim().isEmpty ? 'unspecified' : paymentMethod.trim(),
        'settlementStatus': normalizedSettlementStatus,
        'completionState': completionState,
        'reviewStatus': normalizedReviewStatus,
        'reportedOutstandingAmountNgn': amountDue,
        if (normalizedSettlement.isNotEmpty) ...normalizedSettlement,
        'updatedAt': rtdb.ServerValue.timestamp,
      },
      if (normalizedSettlement.isNotEmpty) ...<String, dynamic>{
        'ride_requests/$rideId/settlement': normalizedSettlement,
        'ride_requests/$rideId/grossFare':
            normalizedSettlement['grossFareNgn'] ?? grossFare,
        'ride_requests/$rideId/commission':
            normalizedSettlement['commissionAmountNgn'] ?? 0,
        'ride_requests/$rideId/commissionAmount':
            normalizedSettlement['commissionAmountNgn'] ?? 0,
        'ride_requests/$rideId/driverPayout':
            normalizedSettlement['driverPayoutNgn'] ?? 0,
        'ride_requests/$rideId/netEarning':
            normalizedSettlement['netEarningNgn'] ?? 0,
        'ride_requests/$rideId/updated_at': rtdb.ServerValue.timestamp,
      },
      if (driverId.trim().isNotEmpty &&
          driverTripRecord.isNotEmpty) ...<String, dynamic>{
        'drivers/$driverId/trips/$rideId': driverTripRecord,
        'drivers/$driverId/earnings/updated_at': rtdb.ServerValue.timestamp,
        'drivers/$driverId/wallet/last_updated': rtdb.ServerValue.timestamp,
        'drivers/$driverId/updated_at': rtdb.ServerValue.timestamp,
      },
      'trip_route_logs/$rideId/updatedAt': rtdb.ServerValue.timestamp,
    };

    await runOptionalRealtimeDatabaseWrite(
      source: 'trip_safety.updateSettlementHook.primary',
      path: 'trip_route_logs+ride_requests+drivers+driver_trips',
      operation: 'settlement_multi_path_update',
      rideId: rideId,
      action: () => _rootRef.update(safeDriverUpdates),
    );

    final adminMirrorUpdates = <String, dynamic>{
      'trip_settlement_hooks/$rideId/rideId': rideId,
      'trip_settlement_hooks/$rideId/riderId': riderId,
      'trip_settlement_hooks/$rideId/driverId': driverId,
      'trip_settlement_hooks/$rideId/serviceType': serviceType,
      'trip_settlement_hooks/$rideId/paymentMethod':
          paymentMethod.trim().isEmpty ? 'unspecified' : paymentMethod.trim(),
      'trip_settlement_hooks/$rideId/settlementStatus':
          normalizedSettlementStatus,
      'trip_settlement_hooks/$rideId/completionState': completionState,
      'trip_settlement_hooks/$rideId/reviewStatus': normalizedReviewStatus,
      'trip_settlement_hooks/$rideId/reportedOutstandingAmountNgn': amountDue,
      'trip_settlement_hooks/$rideId/fareEstimateNgn':
          grossFare > 0 ? grossFare : (normalizedRideData['fare'] ?? 0),
      if (normalizedSettlement.isNotEmpty)
        'trip_settlement_hooks/$rideId/settlement': normalizedSettlement,
      'trip_settlement_hooks/$rideId/supportedSettlementModes': <String>[
        'card',
        'flutterwave',
        'bank_transfer',
        'online_wallet',
      ],
      'trip_settlement_hooks/$rideId/lastSource': source,
      'trip_settlement_hooks/$rideId/lastNote': (note ?? '').trim(),
      'trip_settlement_hooks/$rideId/evidence': normalizedEvidence,
      'trip_settlement_hooks/$rideId/createdAt':
          normalizedRideData['created_at'] ?? rtdb.ServerValue.timestamp,
      'trip_settlement_hooks/$rideId/updatedAt': rtdb.ServerValue.timestamp,
      'trip_settlement_hooks/$rideId/events/${eventRef.key}': <String, dynamic>{
        'eventId': eventRef.key,
        'rideId': rideId,
        'riderId': riderId,
        'driverId': driverId,
        'serviceType': serviceType,
        'source': source,
        'paymentMethod':
            paymentMethod.trim().isEmpty ? 'unspecified' : paymentMethod.trim(),
        'settlementStatus': normalizedSettlementStatus,
        'completionState': completionState,
        'reviewStatus': normalizedReviewStatus,
        'reportedOutstandingAmountNgn': amountDue,
        'note': (note ?? '').trim(),
        'evidence': normalizedEvidence,
        if (normalizedSettlement.isNotEmpty) 'settlement': normalizedSettlement,
        'createdAt': rtdb.ServerValue.timestamp,
      },
      if (driverId.trim().isNotEmpty &&
          driverTripRecord.isNotEmpty) ...<String, dynamic>{
        'driver_trips/$driverId/$rideId': driverTripRecord,
        'driver_earnings/$driverId/records/$rideId': driverTripRecord,
        'driver_earnings/$driverId/updatedAt': rtdb.ServerValue.timestamp,
      },
    };

    try {
      await _rootRef.update(adminMirrorUpdates);
    } catch (error) {
      if (!isRealtimeDatabasePermissionDenied(error)) {
        rethrow;
      }
    }
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

  double _firstPositiveDouble(List<dynamic> candidates) {
    for (final candidate in candidates) {
      final value = _doubleOrNull(candidate);
      if (value != null && value > 0) {
        return value;
      }
    }
    return 0;
  }

  Map<String, dynamic> _buildDriverTripRecord({
    required String rideId,
    required String riderId,
    required String driverId,
    required String serviceType,
    required String paymentMethod,
    required String settlementStatus,
    required String reviewStatus,
    required int amountDue,
    required double grossFare,
    required Map<String, dynamic> rideData,
    required Map<String, dynamic> settlement,
    required bool countsTowardWallet,
  }) {
    if (driverId.trim().isEmpty || grossFare <= 0) {
      return const <String, dynamic>{};
    }

    return <String, dynamic>{
      'rideId': rideId,
      'trip_id': rideId,
      'riderId': riderId,
      'driverId': driverId,
      'serviceType': serviceType,
      'paymentMethod':
          paymentMethod.trim().isEmpty ? 'unspecified' : paymentMethod.trim(),
      'fare': settlement['grossFareNgn'] ?? grossFare,
      'grossFare': settlement['grossFareNgn'] ?? grossFare,
      'commission': settlement['commissionAmountNgn'] ?? 0,
      'commissionAmount': settlement['commissionAmountNgn'] ?? 0,
      'driverPayout': settlement['driverPayoutNgn'] ?? 0,
      'netEarning': settlement['netEarningNgn'] ?? 0,
      'settlementStatus': settlementStatus,
      'reviewStatus': reviewStatus,
      'reportedOutstandingAmountNgn': amountDue,
      'countsTowardWallet': countsTowardWallet,
      'city': _text(rideData['market']).isNotEmpty
          ? _text(rideData['market'])
          : _text(rideData['city']),
      'pickup_address': _text(rideData['pickup_address']),
      'destination_address': _text(rideData['destination_address']).isNotEmpty
          ? _text(rideData['destination_address'])
          : _text(rideData['final_destination_address']),
      'distance_km': _doubleOrNull(rideData['distance_km']) ?? 0,
      'duration_min': _doubleOrNull(rideData['duration_min']) ?? 0,
      'fare_breakdown': _map(rideData['fare_breakdown']),
      'settlement': settlement,
      'businessModel': _map(settlement['businessModelSnapshot']),
      'completed_at': rtdb.ServerValue.timestamp,
      'completedAt': rtdb.ServerValue.timestamp,
      'timestamp': rtdb.ServerValue.timestamp,
      'updated_at': rtdb.ServerValue.timestamp,
      'updatedAt': rtdb.ServerValue.timestamp,
    };
  }
}

class _DriverShareMeta {
  const _DriverShareMeta({required this.token});

  final String token;
}

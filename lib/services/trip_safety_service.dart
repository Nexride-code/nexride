import 'package:firebase_database/firebase_database.dart' as rtdb;
import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../support/startup_rtdb_support.dart';
import 'rider_ride_cloud_functions_service.dart';
import 'rider_trust_rules_service.dart';
import 'support_ticket_bridge_service.dart';

class TripSafetyTelemetryService {
  TripSafetyTelemetryService({rtdb.FirebaseDatabase? database})
    : _database = database ?? rtdb.FirebaseDatabase.instance;

  final rtdb.FirebaseDatabase _database;

  rtdb.DatabaseReference get _rootRef => _database.ref();

  RiderTrustRulesService get _rulesService => const RiderTrustRulesService();
  SupportTicketBridgeService get _supportTicketBridge =>
      const SupportTicketBridgeService();

  Future<void> registerRideRequest({
    required String rideId,
    required String riderId,
    required String serviceType,
    required Map<String, dynamic> ridePayload,
    required List<LatLng> expectedRoutePoints,
  }) async {
    final routePoints = expectedRoutePoints
        .map(
          (LatLng point) => <String, double>{
            'lat': point.latitude,
            'lng': point.longitude,
          },
        )
        .toList();

    final routeBasis = <String, dynamic>{
      'serviceType': serviceType,
      'market': ridePayload['market'] ?? ridePayload['city'],
      'pickup': ridePayload['pickup'],
      'destination': ridePayload['destination'],
      'finalDestination': ridePayload['final_destination'],
      'stops': ridePayload['stops'] ?? <dynamic>[],
      'distanceKm': ridePayload['distance_km'],
      'fareEstimate': ridePayload['fare'],
      'fareBreakdown': ridePayload['fare_breakdown'] ?? <String, dynamic>{},
      'expectedRoutePoints': routePoints,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    };
    final now = DateTime.now().millisecondsSinceEpoch;
    try {
      await RiderRideCloudFunctionsService.instance.patchRideRequestMetadata(
        rideId: rideId,
        patch: <String, dynamic>{
          'route_basis': routeBasis,
          'route_log_updated_at': now,
          'route_log_last_event_at': now,
          'route_log_last_event_status':
              ridePayload['status']?.toString() ?? 'searching',
          'route_log_last_event_source': 'rider_request_created',
          'has_route_logs': true,
        },
      );
    } catch (_) {}

    try {
      await _rootRef.update(<String, dynamic>{
        'trip_route_logs/$rideId': <String, dynamic>{
          'rideId': rideId,
          'riderId': riderId,
          'driverId': ridePayload['driver_id'] ?? '',
          'serviceType': serviceType,
          'status': ridePayload['status'] ?? 'searching',
          'trip_state': ridePayload['trip_state'],
          'routeBasis': <String, dynamic>{
            'market': ridePayload['market'] ?? ridePayload['city'],
            'pickupAddress': ridePayload['pickup_address'],
            'destinationAddress': ridePayload['destination_address'],
            'stopCount': ridePayload['stop_count'] ?? 1,
            'distanceKm': ridePayload['distance_km'],
            'fareEstimate': ridePayload['fare'],
            'fareBreakdown':
                ridePayload['fare_breakdown'] ?? <String, dynamic>{},
            'expectedRoutePoints': routePoints,
          },
          'createdAt': rtdb.ServerValue.timestamp,
          'updatedAt': rtdb.ServerValue.timestamp,
        },
      });
    } catch (e) {
      if (isPermissionDeniedError(e)) {
        debugPrint(
          'RIDER_TELEMETRY_SKIPPED_PERMISSION_DENIED '
          'phase=registerRideRequest_root rideId=$rideId',
        );
      } else {
        rethrow;
      }
    }

    await logRideStateChange(
      rideId: rideId,
      riderId: riderId,
      driverId: ridePayload['driver_id']?.toString() ?? '',
      serviceType: serviceType,
      status: ridePayload['status']?.toString() ?? 'searching',
      source: 'rider_request_created',
      rideData: ridePayload,
    );
  }

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
    final now = DateTime.now().millisecondsSinceEpoch;
    try {
      await _rootRef.update(<String, dynamic>{
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
          'destinationAddress':
              rideData?['destination_address'] ??
              rideData?['final_destination_address'],
          'createdAt': rtdb.ServerValue.timestamp,
        },
      });
    } catch (e) {
      if (isPermissionDeniedError(e)) {
        debugPrint(
          'RIDER_TELEMETRY_SKIPPED_PERMISSION_DENIED '
          'phase=logRideStateChange rideId=$rideId',
        );
        return;
      }
      rethrow;
    }
    try {
      await RiderRideCloudFunctionsService.instance.patchRideRequestMetadata(
        rideId: rideId,
        patch: <String, dynamic>{
          'route_log_updated_at': now,
          'route_log_last_event_at': now,
          'route_log_last_event_status': status,
          'route_log_last_event_source': source,
          'has_route_logs': true,
        },
      );
    } catch (_) {}
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
    final checkpointRef = _rootRef
        .child('trip_route_logs/$rideId/checkpoints')
        .push();
    try {
      await _rootRef.update(<String, dynamic>{
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
      });
    } catch (e) {
      if (isPermissionDeniedError(e)) {
        debugPrint(
          'RIDER_TELEMETRY_SKIPPED_PERMISSION_DENIED '
          'phase=logCheckpoint rideId=$rideId',
        );
        return;
      }
      rethrow;
    }
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
    final rules = await _rulesService.fetchRules();
    final tolerance =
        (rules['offRouteToleranceMeters'] as num?)?.toDouble() ?? 250;
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
        await RiderRideCloudFunctionsService.instance.escalateSafetyIncident(
          rideId: rideId,
          riderId: riderId,
          driverId: driverId,
          flagType: flagType,
          details: message,
          sourceFlagId: flagRef.key ?? '',
        );
      } catch (error) {
        debugPrint('RIDER_SOS_ESCALATE_FAIL error=$error');
      }
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
      );
    } catch (_) {}
  }
}

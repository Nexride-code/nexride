import 'package:firebase_database/firebase_database.dart' as rtdb;
import 'package:google_maps_flutter/google_maps_flutter.dart';

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

    await _rootRef.update(<String, dynamic>{
      'ride_requests/$rideId/route_basis': <String, dynamic>{
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
        'createdAt': rtdb.ServerValue.timestamp,
        'updatedAt': rtdb.ServerValue.timestamp,
      },
      'ride_requests/$rideId/route_log_updated_at': rtdb.ServerValue.timestamp,
      'ride_requests/$rideId/route_log_last_event_at':
          rtdb.ServerValue.timestamp,
      'ride_requests/$rideId/route_log_last_event_status':
          ridePayload['status'] ?? 'searching',
      'ride_requests/$rideId/route_log_last_event_source':
          'rider_request_created',
      'ride_requests/$rideId/has_route_logs': true,
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
          'fareBreakdown': ridePayload['fare_breakdown'] ?? <String, dynamic>{},
          'expectedRoutePoints': routePoints,
        },
        'createdAt': rtdb.ServerValue.timestamp,
        'updatedAt': rtdb.ServerValue.timestamp,
      },
    });

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
      'ride_requests/$rideId/route_log_updated_at': rtdb.ServerValue.timestamp,
      'ride_requests/$rideId/route_log_last_event_at':
          rtdb.ServerValue.timestamp,
      'ride_requests/$rideId/route_log_last_event_status': status,
      'ride_requests/$rideId/route_log_last_event_source': source,
      'ride_requests/$rideId/has_route_logs': true,
    });
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

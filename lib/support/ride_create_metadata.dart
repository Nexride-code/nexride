import 'package:firebase_database/firebase_database.dart' as rtdb;

/// Keys allowed on `createRideRequest.ride_metadata` (must match Cloud Function).
const Set<String> kRideCreateMetadataAllow = {
  'stops',
  'stop_count',
  'rider_trust_snapshot',
  'route_basis',
  'pickup_address',
  'destination_address',
  'final_destination',
  'final_destination_address',
  'city',
  'country',
  'country_code',
  'area',
  'zone',
  'community',
  'pickup_area',
  'pickup_zone',
  'pickup_community',
  'destination_area',
  'destination_zone',
  'destination_community',
  'service_area',
  'pickup_scope',
  'destination_scope',
  'fare_breakdown',
  'requested_at',
  'search_timeout_at',
  'request_expires_at',
  'payment_context',
  'settlement_status',
  'support_status',
  'destination',
  'state_machine_version',
  'duration_min',
  'cancel_reason',
  'pricing_snapshot',
  'packagePhotoUrl',
  'packagePhotoSubmittedAt',
  'payment_placeholder',
  'search_started_at',
  'pickupConfirmedAt',
  'deliveredAt',
  'dispatch_details',
};

Map<String, dynamic> rideMetadataSubset(Map<String, dynamic> src) {
  final out = <String, dynamic>{};
  for (final MapEntry<String, dynamic> e in src.entries) {
    if (!kRideCreateMetadataAllow.contains(e.key)) {
      continue;
    }
    final v = e.value;
    if (v is rtdb.ServerValue) {
      continue;
    }
    out[e.key] = v;
  }
  return out;
}

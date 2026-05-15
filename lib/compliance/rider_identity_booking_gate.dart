import '../services/rider_compliance_service.dart';

/// UX copy for selfie / approval gate (maps to callable [reason] strings too).
String? riderIdentityServerRejectionUserMessage(String? reason) {
  switch ((reason ?? '').trim()) {
    case 'identity_selfie_missing':
      return 'Submit a selfie and wait for NexRide approval before booking.';
    case 'identity_pending_review':
      return 'Your selfie is awaiting review. You can book after NexRide approves your identity.';
    case 'identity_rejected':
      return 'Identity verification was not approved. Submit a new selfie from the verification screen.';
    case 'identity_gate_unavailable':
    case 'identity_denied':
      return 'Unable to verify your identity right now. Check your connection and try again.';
    case 'pickup_mismatch_service_city':
    case 'pickup_outside_selected_service_area':
      return 'Your pickup is in a different NexRide service area than the one you selected. '
          'Use “Switch service area” when it appears, or open “Choose service area” and pick the area that contains your pickup.';
    case 'no_service_area_for_pickup':
      return 'NexRide is not available in this pickup area yet.';
    case 'location_required':
    case 'location_required_for_service_area':
      return 'Turn on location permission for pickup, or drop a pin / search to set your pickup manually.';
    case 'pickup_outside_enabled_city':
    case 'service_area_unsupported':
    case 'rollout_hint_invalid':
    case 'rollout_denied':
      return 'That pickup is outside the NexRide service area for your selected city. Adjust your pickup or choose a different service area.';
    default:
      return null;
  }
}

String riderRequestButtonIdentityBlockSubtitle(RiderComplianceSnapshot snap) {
  switch (snap.identityPhase) {
    case RiderIdentityBookingPhase.approved:
      return '';
    case RiderIdentityBookingPhase.missingSelfie:
      return 'Upload a selfie to verify your identity.';
    case RiderIdentityBookingPhase.pendingReview:
      return 'Awaiting NexRide approval of your selfie.';
    case RiderIdentityBookingPhase.rejected:
      return 'Selfie not approved — retake photo to retry.';
    case RiderIdentityBookingPhase.statusUnavailable:
      return 'Unable to verify identity status. Retry when online.';
  }
}

String riderMapIdentityBannerPrimaryLine(RiderComplianceSnapshot snap) {
  switch (snap.identityPhase) {
    case RiderIdentityBookingPhase.approved:
      return '';
    case RiderIdentityBookingPhase.missingSelfie:
      return 'Please complete identity verification to book a ride.';
    case RiderIdentityBookingPhase.pendingReview:
      return 'Identity verification pending. You cannot book until NexRide approves your selfie.';
    case RiderIdentityBookingPhase.rejected:
      return 'Selfie rejected. Submit a new photo to request review again.';
    case RiderIdentityBookingPhase.statusUnavailable:
      return 'Could not verify your identity status. Check your connection and reopen the map.';
  }
}

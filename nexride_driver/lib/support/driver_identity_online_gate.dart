// Go-online gate based on driver identity / KYC verification status.

String _normStatus(Map<String, dynamic> profile) {
  final raw = profile['identity_verification_status'] ??
      profile['verificationStatus'] ??
      profile['verification_status'];
  return raw?.toString().trim().toLowerCase() ?? '';
}

/// Returns true only when the driver's identity has been explicitly approved.
/// Pending, submitted, and under-review statuses are blocked — the driver must
/// wait for admin approval before going online.
bool driverIdentityVerificationAllowsOnline(Map<String, dynamic> profile) {
  final st = _normStatus(profile);
  return st == 'approved' ||
      st == 'verified' ||
      st == 'accepted' ||
      st == 'cleared' ||
      st == 'complete' ||
      st == 'completed';
}

String driverIdentityVerificationGateMessage(Map<String, dynamic> profile) {
  final st = _normStatus(profile);
  if (st.isEmpty) {
    return 'Complete identity verification in the Verification section before going online.';
  }
  if (st == 'rejected' || st == 'denied') {
    return 'Identity verification was not approved. Open Verification to resubmit or contact support.';
  }
  if (st == 'suspended' || st == 'blocked') {
    return 'This account cannot go online until verification is restored. Contact support.';
  }
  if (st == 'pending' ||
      st == 'submitted' ||
      st == 'under_review' ||
      st == 'in_review' ||
      st == 'manual_review' ||
      st == 'pending_review') {
    return 'Your identity verification is under review. You will be notified once approved.';
  }
  return 'Identity verification required before going online. Open Verification to complete it.';
}

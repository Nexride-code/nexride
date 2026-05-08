// KYC gate: set driverKycGateEnabled = false in driver_app_config.dart to bypass until Smile Identity / Prembly is wired.

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart' as rtdb;
import 'package:flutter/foundation.dart';

import '../config/driver_app_config.dart';

// REMOVE before full public launch — test accounts skip RTDB `kyc_approved` / `kyc_admin_override`.
const List<String> kKycBypassEmails = <String>[
  'lexemm01@gmail.com',
];

/// RTDB patch keys for `users/{driverId}/kyc_status` derived from verification uploads.
Map<String, Object?> driverKycStatusPatchForUserNode({
  required String driverId,
  required Map<String, dynamic> normalizedVerification,
}) {
  final docs = Map<String, dynamic>.from(
    normalizedVerification['documents'] as Map? ?? <String, dynamic>{},
  );

  bool submitted(String key) {
    final row = docs[key];
    if (row is! Map) return false;
    return row['status']?.toString().trim().toLowerCase() == 'submitted';
  }

  final ninDone = submitted('nin');
  final bvnDone = submitted('bvn');
  final selfieDone = submitted('selfie');
  final pendingCore = ninDone && bvnDone && selfieDone;

  return <String, Object?>{
    'users/$driverId/kyc_status/nin_verified': false,
    'users/$driverId/kyc_status/bvn_verified': false,
    'users/$driverId/kyc_status/face_matched': false,
    'users/$driverId/kyc_status/kyc_approved': false,
    'users/$driverId/kyc_status/reviewed_at': 0,
    'users/$driverId/kyc_status/submission_status':
        pendingCore ? 'pending_review' : 'incomplete',
    'users/$driverId/kyc_status/manual_review_only': true,
    'users/$driverId/kyc_status/launch_note':
        'Provider API not connected yet (Smile Identity or Prembly recommended). '
            'Admin approval required before public launch.',
    'users/$driverId/kyc_status/updated_at': rtdb.ServerValue.timestamp,
  };
}

Future<bool> driverPassesKycGateForGoOnline(String driverId) async {
  if (!DriverFeatureFlags.driverKycGateEnabled) {
    return true;
  }
  final uid = driverId.trim();
  if (uid.isEmpty) {
    return false;
  }
  final emailRaw = FirebaseAuth.instance.currentUser?.email?.trim() ?? '';
  final emailNorm = emailRaw.toLowerCase();
  final bypassSet =
      kKycBypassEmails.map((e) => e.trim().toLowerCase()).toSet();
  if (emailNorm.isNotEmpty && bypassSet.contains(emailNorm)) {
    debugPrint('KYC gate bypassed for test account: $emailRaw');
    return true;
  }
  final snap =
      await rtdb.FirebaseDatabase.instance.ref('users/$uid/kyc_status').get();
  if (!snap.exists || snap.value is! Map) {
    return false;
  }
  final m = Map<String, dynamic>.from(snap.value as Map);
  if (m['kyc_admin_override'] == true) {
    return true;
  }
  return m['kyc_approved'] == true;
}

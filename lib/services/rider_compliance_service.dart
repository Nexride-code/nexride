import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';

import '../compliance/rider_compliance_constants.dart';
import '../compliance/rider_policy_text.dart';

import 'rider_ride_cloud_functions_service.dart';

/// Booking unlock requires admin-approved identity (Firestore), not selfie upload alone.
enum RiderIdentityBookingPhase {
  approved,
  missingSelfie,
  pendingReview,
  rejected,
  statusUnavailable,
}

/// Firestore-backed rider compliance (terms + identity selfie).
class RiderComplianceSnapshot {
  const RiderComplianceSnapshot({
    required this.selfieUploaded,
    required this.termsAccepted,
    required this.ageConfirmed,
    this.termsVersion,
    this.verificationStatus,
    this.fetchFailed = false,
  });

  final bool selfieUploaded;
  final bool termsAccepted;
  final bool ageConfirmed;
  final String? termsVersion;
  final String? verificationStatus;
  final bool fetchFailed;

  static String _normStatus(String? raw) =>
      (raw ?? '').trim().toLowerCase();

  RiderIdentityBookingPhase get identityPhase {
    if (fetchFailed) {
      return RiderIdentityBookingPhase.statusUnavailable;
    }
    if (!selfieUploaded) {
      return RiderIdentityBookingPhase.missingSelfie;
    }
    final status = _normStatus(verificationStatus);
    if (status == 'approved') {
      return RiderIdentityBookingPhase.approved;
    }
    if (status == 'rejected') {
      return RiderIdentityBookingPhase.rejected;
    }
    return RiderIdentityBookingPhase.pendingReview;
  }

  bool get blocksRideBooking =>
      identityPhase != RiderIdentityBookingPhase.approved;

  bool get needsTermsAcceptance {
    if (fetchFailed) {
      return false;
    }
    if (termsAccepted != true || ageConfirmed != true) {
      return true;
    }
    final v = (termsVersion ?? '').trim();
    return v.isEmpty || v != RiderComplianceConstants.termsVersion;
  }
}

enum RiderPolicyDocumentKind { terms, privacy, community }

String riderPolicyDocumentAnalyticsValue(RiderPolicyDocumentKind kind) {
  switch (kind) {
    case RiderPolicyDocumentKind.terms:
      return 'terms';
    case RiderPolicyDocumentKind.privacy:
      return 'privacy';
    case RiderPolicyDocumentKind.community:
      return 'community';
  }
}

String riderPolicyDocumentTitle(RiderPolicyDocumentKind kind) {
  switch (kind) {
    case RiderPolicyDocumentKind.terms:
      return 'Terms of Service';
    case RiderPolicyDocumentKind.privacy:
      return 'Privacy Policy';
    case RiderPolicyDocumentKind.community:
      return 'Community Guidelines';
  }
}

String riderPolicyDocumentBody(RiderPolicyDocumentKind kind) {
  switch (kind) {
    case RiderPolicyDocumentKind.terms:
      return RiderPolicyText.termsOfService;
    case RiderPolicyDocumentKind.privacy:
      return RiderPolicyText.privacyPolicy;
    case RiderPolicyDocumentKind.community:
      return RiderPolicyText.communityGuidelines;
  }
}

class RiderComplianceService {
  RiderComplianceService._();
  static final RiderComplianceService instance = RiderComplianceService._();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAnalytics _analytics = FirebaseAnalytics.instance;

  CollectionReference<Map<String, dynamic>> get _users =>
      _firestore.collection('users');

  Future<RiderComplianceSnapshot> fetchSnapshot(String uid) async {
    final id = uid.trim();
    if (id.isEmpty) {
      return const RiderComplianceSnapshot(
        selfieUploaded: false,
        termsAccepted: false,
        ageConfirmed: false,
        fetchFailed: true,
      );
    }
    try {
      final doc = await _users
          .doc(id)
          .get(const GetOptions(source: Source.serverAndCache))
          .timeout(const Duration(seconds: 12));
      return _snapshotFromDoc(doc);
    } catch (e, st) {
      debugPrint('[RiderCompliance] fetch failed: $e');
      debugPrintStack(label: '[RiderCompliance] fetch stack', stackTrace: st);
      try {
        final cached = await _users.doc(id).get(
              const GetOptions(source: Source.cache),
            );
        return _snapshotFromDoc(cached);
      } catch (_) {
        return const RiderComplianceSnapshot(
          selfieUploaded: false,
          termsAccepted: false,
          ageConfirmed: false,
          fetchFailed: true,
        );
      }
    }
  }

  RiderComplianceSnapshot _snapshotFromDoc(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    if (!doc.exists || doc.data() == null) {
      return const RiderComplianceSnapshot(
        selfieUploaded: false,
        termsAccepted: false,
        ageConfirmed: false,
      );
    }
    final m = doc.data()!;
    bool readBool(String k) {
      final v = m[k];
      if (v is bool) {
        return v;
      }
      if (v is String) {
        return v.toLowerCase() == 'true';
      }
      return false;
    }

    return RiderComplianceSnapshot(
      selfieUploaded: readBool('selfieUploaded'),
      termsAccepted: readBool('termsAccepted'),
      ageConfirmed: readBool('ageConfirmed'),
      termsVersion: m['termsVersion']?.toString(),
      verificationStatus: m['verificationStatus']?.toString(),
    );
  }

  Future<void> saveSignupConsent({
    required String uid,
  }) async {
    final id = uid.trim();
    if (id.isEmpty) {
      return;
    }
    await _users.doc(id).set(<String, dynamic>{
      'termsAccepted': true,
      'termsAcceptedAt': FieldValue.serverTimestamp(),
      'termsVersion': RiderComplianceConstants.termsVersion,
      'ageConfirmed': true,
      'ageConfirmedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    await _analytics.logEvent(
      name: 'TERMS_ACCEPTED',
      parameters: <String, Object>{
        'terms_version': RiderComplianceConstants.termsVersion,
      },
    );
    await _analytics.logEvent(
      name: 'AGE_GATE_PASSED',
      parameters: <String, Object>{
        'context': 'signup',
      },
    );
  }

  Future<void> saveUpdatedTermsAcceptance({required String uid}) async {
    final id = uid.trim();
    if (id.isEmpty) {
      return;
    }
    await _users.doc(id).set(<String, dynamic>{
      'termsAccepted': true,
      'termsAcceptedAt': FieldValue.serverTimestamp(),
      'termsVersion': RiderComplianceConstants.termsVersion,
      'ageConfirmed': true,
      'ageConfirmedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    await _analytics.logEvent(
      name: 'TERMS_ACCEPTED',
      parameters: <String, Object>{
        'terms_version': RiderComplianceConstants.termsVersion,
        'context': 'updated_terms_modal',
      },
    );
    await _analytics.logEvent(
      name: 'AGE_GATE_PASSED',
      parameters: <String, Object>{
        'context': 'updated_terms_modal',
      },
    );
  }

  Future<void> logPolicyViewed(RiderPolicyDocumentKind kind) async {
    await _analytics.logEvent(
      name: 'TERMS_VIEWED',
      parameters: <String, Object>{
        'document': riderPolicyDocumentAnalyticsValue(kind),
      },
    );
  }

  Future<void> uploadSelfieAndMarkPending({
    required String uid,
    required File imageFile,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || user.uid != uid) {
      throw StateError('not_signed_in');
    }

    await _analytics.logEvent(name: 'SELFIE_UPLOAD_STARTED');

    final storageRef = FirebaseStorage.instance
        .ref()
        .child('user_verification')
        .child(uid)
        .child('selfie.jpg');

    try {
      await storageRef.putFile(
        imageFile,
        SettableMetadata(contentType: 'image/jpeg'),
      );
    } catch (e) {
      await _analytics.logEvent(
        name: 'SELFIE_UPLOAD_FAILED',
        parameters: <String, Object>{
          'reason': e.runtimeType.toString(),
        },
      );
      rethrow;
    }

    await _users.doc(uid).set(<String, dynamic>{
      'selfieUploaded': true,
      'selfieUploadedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    await _analytics.logEvent(name: 'SELFIE_UPLOAD_SUCCESS');

    try {
      await RiderRideCloudFunctionsService.instance.riderNotifySelfieSubmittedForReview();
    } catch (e, st) {
      debugPrint('[RiderCompliance] riderNotifySelfieSubmittedForReview failed: $e');
      debugPrintStack(
        label: '[RiderCompliance] notify selfie stack',
        stackTrace: st,
      );
    }
  }
}

/// Opens analytics for policy sheet — call from UI before showing copy.
Future<void> riderComplianceLogPolicyView(RiderPolicyDocumentKind kind) {
  return RiderComplianceService.instance.logPolicyViewed(kind);
}

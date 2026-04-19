import 'package:firebase_database/firebase_database.dart' as rtdb;

import '../support/rider_trust_support.dart';
import 'rider_trust_rules_service.dart';
import 'rider_verification_provider_adapters.dart';
import 'rider_verification_upload_service.dart';

class RiderVerificationSubmissionBundle {
  const RiderVerificationSubmissionBundle({
    required this.verification,
    required this.identityDocument,
    required this.selfieDocument,
    required this.deviceFingerprints,
    required this.trustSummary,
    required this.uploadedFile,
  });

  final Map<String, dynamic> verification;
  final Map<String, dynamic> identityDocument;
  final Map<String, dynamic> selfieDocument;
  final Map<String, dynamic> deviceFingerprints;
  final Map<String, dynamic> trustSummary;
  final RiderVerificationUploadedFile uploadedFile;
}

class RiderVerificationWorkflowService {
  const RiderVerificationWorkflowService();

  RiderVerificationUploadService get _uploadService =>
      const RiderVerificationUploadService();

  RiderTrustRulesService get _rulesService => const RiderTrustRulesService();

  rtdb.DatabaseReference get _rootRef => rtdb.FirebaseDatabase.instance.ref();

  Future<RiderVerificationSubmissionBundle> submitVerificationPackage({
    required String riderId,
    required Map<String, dynamic> riderProfile,
    required Map<String, dynamic> verification,
    required Map<String, dynamic> riskFlags,
    required Map<String, dynamic> paymentFlags,
    required Map<String, dynamic> reputation,
    required Map<String, dynamic> deviceFingerprints,
    required RiderIdentityMethod identityMethod,
    required String identityNumber,
    required String note,
    required RiderVerificationSelectedAsset selfieAsset,
    void Function(double progress)? onUploadProgress,
  }) async {
    final uploadedFile = await _uploadService.uploadSelfie(
      riderId: riderId,
      asset: selfieAsset,
      onProgress: onUploadProgress,
    );

    final plans = RiderVerificationProviderRegistry.plansForSubmission(
      riderId: riderId,
      identityMethod: identityMethod,
      identityNumber: identityNumber,
      fileReference: uploadedFile.fileReference,
    );
    final identityPlan = _planForCheckType(
      plans: plans,
      riderId: riderId,
      identityMethod: identityMethod,
      identityNumber: identityNumber,
      fileReference: uploadedFile.fileReference,
      checkType: identityMethod.checkType,
    );
    final livenessPlan = _planForCheckType(
      plans: plans,
      riderId: riderId,
      identityMethod: identityMethod,
      identityNumber: identityNumber,
      fileReference: uploadedFile.fileReference,
      checkType: 'liveness_verification',
    );
    final faceMatchPlan = _planForCheckType(
      plans: plans,
      riderId: riderId,
      identityMethod: identityMethod,
      identityNumber: identityNumber,
      fileReference: uploadedFile.fileReference,
      checkType: 'face_match_verification',
    );

    final identityFingerprint = riderTrustFingerprint(
      '${identityMethod.key}:$identityNumber',
    );

    final identityDocument = <String, dynamic>{
      'riderId': riderId,
      'documentType': 'identity',
      'label': 'Identity number',
      'verificationType': '${identityMethod.key}_identity',
      'documentMethod': identityMethod.key,
      'documentNumber': identityNumber,
      'maskedDocumentNumber': riderMaskedSensitiveNumber(identityNumber),
      'numberFingerprint': identityFingerprint,
      'provider': identityPlan.provider,
      'providerReference': identityPlan.providerReference,
      'status': 'submitted',
      'result': 'pending_review',
      'failureReason': '',
      'note': note,
      'reviewedAt': null,
      'reviewedBy': '',
      'submittedAt': rtdb.ServerValue.timestamp,
      'createdAt': rtdb.ServerValue.timestamp,
      'updatedAt': rtdb.ServerValue.timestamp,
    };
    final selfieDocument = <String, dynamic>{
      'riderId': riderId,
      'documentType': 'selfie',
      'label': 'Selfie / face verification',
      'verificationType': 'selfie_face_verification',
      'documentMethod': 'selfie_capture',
      'documentNumber': '',
      'maskedDocumentNumber': '',
      'numberFingerprint': '',
      'fileUrl': uploadedFile.fileUrl,
      'fileReference': uploadedFile.fileReference,
      'fileName': uploadedFile.fileName,
      'mimeType': uploadedFile.mimeType,
      'uploadSource': uploadedFile.source,
      'fileSizeBytes': uploadedFile.fileSizeBytes,
      'provider': livenessPlan.provider,
      'providerReference': livenessPlan.providerReference,
      'status': 'submitted',
      'result': 'pending_review',
      'failureReason': '',
      'note': note,
      'reviewedAt': null,
      'reviewedBy': '',
      'submittedAt': rtdb.ServerValue.timestamp,
      'createdAt': rtdb.ServerValue.timestamp,
      'updatedAt': rtdb.ServerValue.timestamp,
    };

    final nextVerification = buildRiderVerificationDefaults(<String, dynamic>{
      ...verification,
      'riderId': riderId,
      'identityMethod': identityMethod.key,
      'overallStatus': 'manual_review',
      'status': 'manual_review',
      'documents': <String, dynamic>{
        'identity': identityDocument,
        'selfie': selfieDocument,
      },
      'checks': <String, dynamic>{
        'identity': <String, dynamic>{
          'checkType': identityMethod.checkType,
          'provider': identityPlan.provider,
          'providerReference': identityPlan.providerReference,
          'status': identityPlan.status,
          'result': identityPlan.result,
          'failureReason': identityPlan.failureReason,
          'createdAt': rtdb.ServerValue.timestamp,
          'updatedAt': rtdb.ServerValue.timestamp,
        },
        'liveness': <String, dynamic>{
          'checkType': 'liveness_verification',
          'provider': livenessPlan.provider,
          'providerReference': livenessPlan.providerReference,
          'status': livenessPlan.status,
          'result': livenessPlan.result,
          'failureReason': livenessPlan.failureReason,
          'createdAt': rtdb.ServerValue.timestamp,
          'updatedAt': rtdb.ServerValue.timestamp,
        },
        'face_match': <String, dynamic>{
          'checkType': 'face_match_verification',
          'provider': faceMatchPlan.provider,
          'providerReference': faceMatchPlan.providerReference,
          'status': faceMatchPlan.status,
          'result': faceMatchPlan.result,
          'failureReason': faceMatchPlan.failureReason,
          'createdAt': rtdb.ServerValue.timestamp,
          'updatedAt': rtdb.ServerValue.timestamp,
        },
      },
      'createdAt': verification['createdAt'] ?? rtdb.ServerValue.timestamp,
      'updatedAt': rtdb.ServerValue.timestamp,
      'lastSubmittedAt': rtdb.ServerValue.timestamp,
    })..['riderId'] = riderId;

    final nextDeviceFingerprints = <String, dynamic>{
      ...deviceFingerprints,
      'riderId': riderId,
      'identityFingerprint': identityFingerprint,
      'updatedAt': rtdb.ServerValue.timestamp,
    };

    final rules = await _rulesService.fetchRules();
    final decision = _rulesService.evaluateAccess(
      verification: nextVerification,
      riskFlags: riskFlags,
      paymentFlags: paymentFlags,
      rules: rules,
    );
    final trustSummary = buildRiderTrustSummary(
      verification: nextVerification,
      riskFlags: riskFlags,
      paymentFlags: paymentFlags,
      reputation: reputation,
      accessDecision: decision.toMap(),
    );

    await _rootRef.update(<String, dynamic>{
      'users/$riderId/verification': nextVerification,
      'users/$riderId/installFingerprint':
          nextDeviceFingerprints['installFingerprint'],
      'users/$riderId/updated_at': rtdb.ServerValue.timestamp,
      'rider_documents/$riderId/identity': identityDocument,
      'rider_documents/$riderId/selfie': selfieDocument,
      'rider_verifications/$riderId': <String, dynamic>{
        'riderId': riderId,
        ...nextVerification,
        'updatedAt': rtdb.ServerValue.timestamp,
      },
      'rider_device_fingerprints/$riderId': nextDeviceFingerprints,
    });

    return RiderVerificationSubmissionBundle(
      verification: nextVerification,
      identityDocument: identityDocument,
      selfieDocument: selfieDocument,
      deviceFingerprints: nextDeviceFingerprints,
      trustSummary: trustSummary,
      uploadedFile: uploadedFile,
    );
  }

  RiderVerificationCheckPlan _planForCheckType({
    required List<RiderVerificationCheckPlan> plans,
    required String riderId,
    required RiderIdentityMethod identityMethod,
    required String identityNumber,
    required String fileReference,
    required String checkType,
  }) {
    for (final plan in plans) {
      if (plan.checkType == checkType) {
        return plan;
      }
    }

    return RiderVerificationProviderRegistry.adapterForCheckType(
      checkType,
    ).createCheckPlan(
      RiderVerificationCheckRequest(
        riderId: riderId,
        identityMethod: identityMethod,
        identityNumber: identityNumber,
        fileReference: fileReference,
        checkType: checkType,
      ),
    );
  }
}

import 'package:firebase_database/firebase_database.dart' as rtdb;

import '../support/driver_profile_support.dart';
import '../support/driver_kyc_gate_support.dart';
import '../support/realtime_database_error_support.dart';
import 'driver_verification_upload_service.dart';
import 'verification_provider_adapters.dart';

class DriverVerificationSubmissionBundle {
  const DriverVerificationSubmissionBundle({
    required this.profileVerification,
    required this.driverDocumentRecord,
    required this.aggregateVerificationRecord,
    required this.verificationChecks,
    required this.verificationAudits,
    required this.uploadedFile,
  });

  final Map<String, dynamic> profileVerification;
  final Map<String, dynamic> driverDocumentRecord;
  final Map<String, dynamic> aggregateVerificationRecord;
  final List<Map<String, dynamic>> verificationChecks;
  final List<Map<String, dynamic>> verificationAudits;
  final DriverVerificationUploadedFile uploadedFile;
}

class DriverVerificationWorkflowService {
  const DriverVerificationWorkflowService();

  DriverVerificationUploadService get _uploadService =>
      const DriverVerificationUploadService();

  rtdb.DatabaseReference get _rootRef => rtdb.FirebaseDatabase.instance.ref();

  Future<DriverVerificationSubmissionBundle> submitDocumentPackage({
    required String driverId,
    required Map<String, dynamic> driverProfile,
    required Map<String, dynamic> verification,
    required DriverRequiredDocument document,
    required DriverVerificationSelectedAsset asset,
    required String documentNumber,
    required String note,
    void Function(double progress)? onUploadProgress,
  }) async {
    final uploadedFile = await _uploadService.uploadDocument(
      driverId: driverId,
      document: document,
      asset: asset,
      onProgress: onUploadProgress,
    );

    final bundle = _prepareDocumentSubmission(
      driverId: driverId,
      driverProfile: driverProfile,
      verification: verification,
      document: document,
      uploadedFile: uploadedFile,
      documentNumber: documentNumber,
      note: note,
    );

    final updates = <String, dynamic>{
      'drivers/$driverId/verification': bundle.profileVerification,
      'drivers/$driverId/updated_at': rtdb.ServerValue.timestamp,
      'driver_documents/$driverId/${document.key}': bundle.driverDocumentRecord,
      'driver_verifications/$driverId': bundle.aggregateVerificationRecord,
      ...driverKycStatusPatchForUserNode(
        driverId: driverId,
        normalizedVerification: normalizedDriverVerification(
          bundle.profileVerification,
        ),
      ),
    };

    final adminMirrorUpdates = <String, dynamic>{};
    for (final check in bundle.verificationChecks) {
      final checkRef = _rootRef.child('verification_checks').push();
      adminMirrorUpdates['verification_checks/${checkRef.key}'] =
          <String, dynamic>{
        ...check,
        'checkId': checkRef.key,
      };
    }

    for (final audit in bundle.verificationAudits) {
      final auditRef = _rootRef.child('verification_audits').push();
      adminMirrorUpdates['verification_audits/${auditRef.key}'] =
          <String, dynamic>{
        ...audit,
        'auditId': auditRef.key,
      };
    }

    await _rootRef.update(updates);
    if (adminMirrorUpdates.isNotEmpty) {
      try {
        await _rootRef.update(adminMirrorUpdates);
      } catch (error) {
        if (!isRealtimeDatabasePermissionDenied(error)) {
          rethrow;
        }
      }
    }
    return bundle;
  }

  DriverVerificationSubmissionBundle _prepareDocumentSubmission({
    required String driverId,
    required Map<String, dynamic> driverProfile,
    required Map<String, dynamic> verification,
    required DriverRequiredDocument document,
    required DriverVerificationUploadedFile uploadedFile,
    required String documentNumber,
    required String note,
  }) {
    final normalizedProfile = buildDriverProfileDefaults(
      driverId: driverId,
      existing: driverProfile,
      fallbackName: driverProfile['name']?.toString(),
      fallbackEmail: driverProfile['email']?.toString(),
      fallbackPhone: driverProfile['phone']?.toString(),
    );
    final normalizedVerification = normalizedDriverVerification(verification);
    final currentDocuments = Map<String, dynamic>.from(
      normalizedVerification['documents'] as Map<String, dynamic>,
    );

    final plannedChecks = VerificationProviderRegistry.plannedChecksForDocument(
      driverId: driverId,
      documentType: document.key,
      checkTypes: document.checkTypes,
      reference: uploadedFile.fileReference,
      documentNumber: documentNumber,
    );
    final primaryPlan = plannedChecks.isNotEmpty ? plannedChecks.first : null;

    final nextDocument = normalizedDriverDocument(
      document,
      currentDocuments[document.key],
    )..addAll(<String, dynamic>{
        'createdAt': currentDocuments[document.key]?['createdAt'] ??
            rtdb.ServerValue.timestamp,
        'status': 'submitted',
        'documentNumber': documentNumber,
        'reference': uploadedFile.fileReference,
        'fileUrl': uploadedFile.fileUrl,
        'fileReference': uploadedFile.fileReference,
        'fileName': uploadedFile.fileName,
        'mimeType': uploadedFile.mimeType,
        'uploadSource': uploadedFile.source,
        'fileSizeBytes': uploadedFile.fileSizeBytes,
        'note': note,
        'submittedAt': rtdb.ServerValue.timestamp,
        'updatedAt': rtdb.ServerValue.timestamp,
        'reviewedAt': null,
        'reviewedBy': '',
        'reviewNote': '',
        'verificationProvider': primaryPlan?.providerKey ?? '',
        'verificationProviderLabel':
            primaryPlan?.providerLabel ?? document.providerHint,
        'providerReference': primaryPlan?.providerReference ?? '',
        'result': 'awaiting_review',
        'failureReason': '',
        'checkTypes': document.checkTypes,
        'requiredForServices': document.requiredForServices,
        'reviewWindowDays': kDriverVerificationReviewDays,
        'officialVerificationLive': false,
      });

    currentDocuments[document.key] = nextDocument;

    final nextVerification = normalizedDriverVerification(
      <String, dynamic>{
        ...normalizedVerification,
        'documents': currentDocuments,
        'createdAt':
            normalizedVerification['createdAt'] ?? rtdb.ServerValue.timestamp,
        'reviewWindowDays': kDriverVerificationReviewDays,
        'lastSubmittedAt': rtdb.ServerValue.timestamp,
        'updatedAt': rtdb.ServerValue.timestamp,
      },
    );

    final verificationChecks = plannedChecks
        .map(
          (VerificationCheckPlan plan) => <String, dynamic>{
            'driverId': driverId,
            'documentType': document.key,
            'documentNumber': documentNumber,
            'fileUrl': uploadedFile.fileUrl,
            'fileReference': uploadedFile.fileReference,
            'fileName': uploadedFile.fileName,
            'submittedAt': rtdb.ServerValue.timestamp,
            'verificationProvider': plan.providerKey,
            'providerReference': plan.providerReference,
            'status': plan.status,
            'result': plan.result,
            'failureReason': plan.failureReason,
            'reviewedAt': null,
            'reviewedBy': '',
            'createdAt': rtdb.ServerValue.timestamp,
            'updatedAt': rtdb.ServerValue.timestamp,
            'checkType': plan.checkType,
            'providerLabel': plan.providerLabel,
            'summary': plan.summary,
          },
        )
        .toList();

    final driverDocumentRecord = <String, dynamic>{
      'driverId': driverId,
      'driverName': normalizedProfile['name'],
      'documentType': document.key,
      'documentNumber': documentNumber,
      'fileUrl': uploadedFile.fileUrl,
      'fileReference': uploadedFile.fileReference,
      'fileName': uploadedFile.fileName,
      'mimeType': uploadedFile.mimeType,
      'uploadSource': uploadedFile.source,
      'fileSizeBytes': uploadedFile.fileSizeBytes,
      'label': document.label,
      'submittedAt': rtdb.ServerValue.timestamp,
      'verificationProvider': primaryPlan?.providerKey ?? '',
      'providerReference': primaryPlan?.providerReference ?? '',
      'status': 'submitted',
      'result': 'awaiting_review',
      'failureReason': '',
      'reviewedAt': null,
      'reviewedBy': '',
      'createdAt': currentDocuments[document.key]?['createdAt'] ??
          rtdb.ServerValue.timestamp,
      'updatedAt': rtdb.ServerValue.timestamp,
      'reference': uploadedFile.fileReference,
      'note': note,
      'requiredForServices': document.requiredForServices,
      'checkTypes': document.checkTypes,
      'reviewWindowDays': kDriverVerificationReviewDays,
      'providerLabel': primaryPlan?.providerLabel ?? document.providerHint,
      'officialVerificationLive': false,
    };

    final aggregateVerificationRecord = <String, dynamic>{
      'driverId': driverId,
      'driverName': normalizedProfile['name'],
      'phone': normalizedProfile['phone'],
      'email': normalizedProfile['email'],
      'businessModel': normalizedDriverBusinessModel(
        normalizedProfile['businessModel'],
      )['selectedModel'],
      ...nextVerification,
      'createdAt':
          normalizedVerification['createdAt'] ?? rtdb.ServerValue.timestamp,
      'updatedAt': rtdb.ServerValue.timestamp,
    };

    final verificationAudits = <Map<String, dynamic>>[
      <String, dynamic>{
        'driverId': driverId,
        'documentType': document.key,
        'documentNumber': documentNumber,
        'fileReference': uploadedFile.fileReference,
        'action': 'document_submitted',
        'submittedAt': rtdb.ServerValue.timestamp,
        'verificationProvider': primaryPlan?.providerKey ?? '',
        'providerReference': primaryPlan?.providerReference ?? '',
        'status': 'submitted',
        'result': 'awaiting_review',
        'failureReason': '',
        'reviewedAt': null,
        'reviewedBy': '',
        'createdAt': rtdb.ServerValue.timestamp,
        'updatedAt': rtdb.ServerValue.timestamp,
      },
      ...plannedChecks.map(
        (VerificationCheckPlan plan) => <String, dynamic>{
          'driverId': driverId,
          'documentType': document.key,
          'documentNumber': documentNumber,
          'fileReference': uploadedFile.fileReference,
          'action': 'verification_check_registered',
          'submittedAt': rtdb.ServerValue.timestamp,
          'verificationProvider': plan.providerKey,
          'providerReference': plan.providerReference,
          'status': plan.status,
          'result': plan.result,
          'failureReason': plan.failureReason,
          'reviewedAt': null,
          'reviewedBy': '',
          'createdAt': rtdb.ServerValue.timestamp,
          'updatedAt': rtdb.ServerValue.timestamp,
          'checkType': plan.checkType,
        },
      ),
    ];

    return DriverVerificationSubmissionBundle(
      profileVerification: nextVerification,
      driverDocumentRecord: driverDocumentRecord,
      aggregateVerificationRecord: aggregateVerificationRecord,
      verificationChecks: verificationChecks,
      verificationAudits: verificationAudits,
      uploadedFile: uploadedFile,
    );
  }
}

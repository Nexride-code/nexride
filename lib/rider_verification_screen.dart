import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart' as rtdb;
import 'package:flutter/material.dart';

import 'config/rider_app_config.dart';
import 'rider_verification_submission_screen.dart';
import 'services/rider_trust_bootstrap_service.dart';
import 'support/rider_trust_support.dart';
import 'support/startup_rtdb_support.dart';

class RiderVerificationScreen extends StatefulWidget {
  const RiderVerificationScreen({super.key, required this.riderId});

  final String riderId;

  @override
  State<RiderVerificationScreen> createState() =>
      _RiderVerificationScreenState();
}

class _RiderVerificationScreenState extends State<RiderVerificationScreen> {
  static const Color _gold = Color(0xFFB57A2A);
  static const Color _cream = Color(0xFFF7F2EA);
  static const Color _dark = Color(0xFF111111);

  final rtdb.DatabaseReference _rootRef = rtdb.FirebaseDatabase.instance.ref();
  final RiderTrustBootstrapService _bootstrapService =
      const RiderTrustBootstrapService();

  Map<String, dynamic> _riderProfile = <String, dynamic>{};
  Map<String, dynamic> _verification = buildRiderVerificationDefaults(null);
  Map<String, dynamic> _riskFlags = buildRiderRiskFlagsDefaults(null);
  Map<String, dynamic> _paymentFlags = buildRiderPaymentFlagsDefaults(null);
  Map<String, dynamic> _reputation = buildRiderReputationDefaults(null);
  Map<String, dynamic> _deviceFingerprints = <String, dynamic>{
    'installFingerprint': '',
  };
  Map<String, dynamic> _trustSummary = <String, dynamic>{};
  bool _loading = true;
  bool _openingSubmission = false;

  @override
  void initState() {
    super.initState();
    _loadRiderTrust();
  }

  void _showMessage(String message) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger == null) {
        return;
      }
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    });
  }

  Future<void> _loadRiderTrust() async {
    debugPrint('[RiderVerification] load riderId=${widget.riderId}');
    try {
      final userSnapshot = await runOptionalStartupRead<rtdb.DataSnapshot>(
        source: 'rider_verification.user_profile',
        path: 'users/${widget.riderId}',
        action: () => _rootRef.child('users/${widget.riderId}').get(),
      );
      final existingUser = userSnapshot?.value is Map
          ? Map<String, dynamic>.from(userSnapshot!.value as Map)
          : <String, dynamic>{};

      final bundle = await _bootstrapService.ensureRiderTrustState(
        riderId: widget.riderId,
        existingUser: existingUser,
        fallbackName: FirebaseAuth.instance.currentUser?.email
            ?.split('@')
            .first,
        fallbackEmail: FirebaseAuth.instance.currentUser?.email,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _riderProfile = bundle.userProfile;
        _verification = bundle.verification;
        _riskFlags = bundle.riskFlags;
        _paymentFlags = bundle.paymentFlags;
        _reputation = bundle.reputation;
        _deviceFingerprints = bundle.deviceFingerprints;
        _trustSummary = bundle.trustSummary;
        _loading = false;
      });

      unawaited(_persistRiderTrustBootstrap(existingUser, bundle));
    } catch (error, stackTrace) {
      debugPrint('[RiderVerification] load failed: $error');
      debugPrintStack(
        label: '[RiderVerification] load stack',
        stackTrace: stackTrace,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
      });
    }
  }

  Future<void> _persistRiderTrustBootstrap(
    Map<String, dynamic> existingUser,
    RiderTrustBootstrapBundle bundle,
  ) async {
    try {
      await persistRiderOwnedBootstrap(
        rootRef: _rootRef,
        riderId: widget.riderId,
        userProfile: <String, dynamic>{
          ...existingUser,
          ...bundle.userProfile,
          'created_at':
              existingUser['created_at'] ?? rtdb.ServerValue.timestamp,
        },
        verification: bundle.verification,
        deviceFingerprints: bundle.deviceFingerprints,
        source: 'rider_verification.bootstrap_write',
      );
    } catch (error, stackTrace) {
      debugPrint('[RiderVerification] persist failed: $error');
      debugPrintStack(
        label: '[RiderVerification] persist stack',
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _openSubmissionFlow() async {
    if (_openingSubmission) {
      return;
    }

    debugPrint('[RiderVerification] open submission flow');
    setState(() {
      _openingSubmission = true;
    });

    RiderVerificationSubmissionResult? result;
    try {
      result = await Navigator.of(context)
          .push<RiderVerificationSubmissionResult>(
            MaterialPageRoute<RiderVerificationSubmissionResult>(
              builder: (_) => RiderVerificationSubmissionScreen(
                riderId: widget.riderId,
                riderProfile: _riderProfile,
                verification: _verification,
                riskFlags: _riskFlags,
                paymentFlags: _paymentFlags,
                reputation: _reputation,
                deviceFingerprints: _deviceFingerprints,
              ),
            ),
          );
    } finally {
      if (mounted) {
        setState(() {
          _openingSubmission = false;
        });
      }
    }

    if (!mounted || result == null) {
      return;
    }
    final resolvedResult = result;

    setState(() {
      _verification = buildRiderVerificationDefaults(
        resolvedResult.verification,
      );
      _trustSummary = resolvedResult.trustSummary;
      _deviceFingerprints = resolvedResult.deviceFingerprints;
      _riderProfile = <String, dynamic>{
        ..._riderProfile,
        'verification': resolvedResult.verification,
        'trustSummary': resolvedResult.trustSummary,
      };
    });

    _showMessage(resolvedResult.successMessage);
  }

  String _formatTimestamp(dynamic rawValue) {
    final timestamp = rawValue is num
        ? rawValue.toInt()
        : int.tryParse(rawValue?.toString() ?? '');
    if (timestamp == null || timestamp <= 0) {
      return 'Not submitted yet';
    }
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp).toLocal();
    final month = <String>[
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ][date.month - 1];
    return '${date.day} $month ${date.year}';
  }

  Widget _buildStatusChip({required String label, required Color color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w800,
          fontSize: 12,
        ),
      ),
    );
  }

  Widget _buildMetricCard({
    required String value,
    required String label,
    Color? valueColor,
  }) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              value,
              style: TextStyle(
                color: valueColor ?? Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.76),
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRequirementCard({
    required RiderVerificationRequirement requirement,
    required Map<String, dynamic> document,
    required String detailText,
  }) {
    final status = document['status']?.toString() ?? 'unverified';
    final color = riderVerificationStatusColor(status);
    final statusLabel = riderVerificationStatusLabel(status);
    final documentNumber = document['maskedDocumentNumber']?.toString() ?? '';
    final fileName = document['fileName']?.toString() ?? '';

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(26),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x12000000),
            blurRadius: 18,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Container(
                  width: 54,
                  height: 54,
                  decoration: BoxDecoration(
                    color: _gold.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(requirement.icon, color: _gold),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        requirement.label,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        requirement.description,
                        style: TextStyle(
                          color: Colors.black.withValues(alpha: 0.64),
                          height: 1.45,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                _buildStatusChip(label: statusLabel, color: color),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              detailText,
              style: TextStyle(
                color: Colors.black.withValues(alpha: 0.72),
                fontWeight: FontWeight.w600,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: <Widget>[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: _cream,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const Icon(
                        Icons.schedule_outlined,
                        size: 16,
                        color: _gold,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Updated ${_formatTimestamp(document['updatedAt'] ?? document['submittedAt'])}',
                        style: TextStyle(
                          color: Colors.black.withValues(alpha: 0.72),
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                if (documentNumber.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: _cream,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      documentNumber,
                      style: TextStyle(
                        color: Colors.black.withValues(alpha: 0.72),
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                  ),
                if (fileName.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: _cream,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      fileName,
                      style: TextStyle(
                        color: Colors.black.withValues(alpha: 0.72),
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final verificationStatus =
        _verification['overallStatus']?.toString() ?? 'unverified';
    final isApproved = RiderVerificationCopy.isApprovedStatus(
      verificationStatus,
    );
    final identityDocument = Map<String, dynamic>.from(
      (_verification['documents'] as Map<String, dynamic>? ??
                  const <String, dynamic>{})['identity']
              as Map? ??
          const <String, dynamic>{},
    );
    final selfieDocument = Map<String, dynamic>.from(
      (_verification['documents'] as Map<String, dynamic>? ??
                  const <String, dynamic>{})['selfie']
              as Map? ??
          const <String, dynamic>{},
    );
    final verificationColor = riderVerificationStatusColor(verificationStatus);
    final verifiedBadge = _verification['verifiedBadgeEligible'] == true;
    final riskStatus = _riskFlags['status']?.toString() ?? 'clear';
    final cashStatus =
        _paymentFlags['cashAccessStatus']?.toString() ?? 'enabled';
    final rating = (_reputation['averageRating'] as num?)?.toDouble() ?? 5.0;
    final ratingCount = (_reputation['ratingCount'] as int?) ?? 0;

    return Scaffold(
      backgroundColor: _cream,
      appBar: AppBar(
        backgroundColor: _gold,
        foregroundColor: Colors.black,
        centerTitle: true,
        title: const Text(RiderVerificationCopy.trustScreenTitle),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                color: _gold,
                onRefresh: _loadRiderTrust,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
                  children: <Widget>[
                    Container(
                      padding: const EdgeInsets.all(22),
                      decoration: BoxDecoration(
                        color: _dark,
                        borderRadius: BorderRadius.circular(30),
                        boxShadow: const <BoxShadow>[
                          BoxShadow(
                            color: Color(0x26000000),
                            blurRadius: 22,
                            offset: Offset(0, 14),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Text(
                                      '${RiderVerificationCopy.title} ${riderVerificationStatusLabel(verificationStatus)}',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 27,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      verifiedBadge
                                          ? 'Your account passed ${RiderVerificationCopy.titleLowercase} and shows a trusted badge.'
                                          : 'Submit your identity details and selfie. Reviews may take up to 3 days while ${RiderVerificationCopy.titleLowercase} checks are validated.',
                                      style: TextStyle(
                                        color: Colors.white.withValues(
                                          alpha: 0.76,
                                        ),
                                        height: 1.55,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              _buildStatusChip(
                                label: riderVerificationStatusLabel(
                                  verificationStatus,
                                ),
                                color: verificationColor,
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(999),
                            child: LinearProgressIndicator(
                              minHeight: 9,
                              value: riderVerificationProgressValue(
                                _verification,
                              ),
                              backgroundColor: Colors.white.withValues(
                                alpha: 0.10,
                              ),
                              valueColor: const AlwaysStoppedAnimation<Color>(
                                _gold,
                              ),
                            ),
                          ),
                          if (verifiedBadge) ...<Widget>[
                            const SizedBox(height: 14),
                            _buildStatusChip(
                              label: 'Verified rider badge active',
                              color: const Color(0xFF198754),
                            ),
                          ],
                          const SizedBox(height: 16),
                          Row(
                            children: <Widget>[
                              _buildMetricCard(
                                value: rating.toStringAsFixed(1),
                                label: ratingCount <= 0
                                    ? 'Rider rating baseline'
                                    : '$ratingCount driver ratings',
                              ),
                              const SizedBox(width: 12),
                              _buildMetricCard(
                                value:
                                    '${(riderVerificationProgressValue(_verification) * 100).round()}%',
                                label: 'Verification progress',
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    if (RiderFeatureFlags.showTrustWarnings) ...<Widget>[
                      const SizedBox(height: 18),
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(26),
                          boxShadow: const <BoxShadow>[
                            BoxShadow(
                              color: Color(0x10000000),
                              blurRadius: 14,
                              offset: Offset(0, 8),
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            const Text(
                              'Account trust overview',
                              style: TextStyle(
                                fontSize: 21,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              riderTrustSummaryMessage(_trustSummary),
                              style: TextStyle(
                                color: Colors.black.withValues(alpha: 0.66),
                                height: 1.5,
                              ),
                            ),
                            const SizedBox(height: 16),
                            Wrap(
                              spacing: 10,
                              runSpacing: 10,
                              children: <Widget>[
                                _buildStatusChip(
                                  label: riderRiskStatusLabel(riskStatus),
                                  color: riderRiskStatusColor(riskStatus),
                                ),
                                _buildStatusChip(
                                  label: riderCashAccessLabel(cashStatus),
                                  color: riderCashAccessColor(cashStatus),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 18),
                    _buildRequirementCard(
                      requirement: kRiderVerificationRequirements.first,
                      document: identityDocument,
                      detailText:
                          identityDocument['maskedDocumentNumber']
                                  ?.toString()
                                  .isNotEmpty ==
                              true
                          ? '${_verification['identityMethodLabel'] ?? 'Identity'} submitted for review.'
                          : 'Add your NIN or BVN so the identity review can start.',
                    ),
                    _buildRequirementCard(
                      requirement: kRiderVerificationRequirements.last,
                      document: selfieDocument,
                      detailText:
                          selfieDocument['fileName']?.toString().isNotEmpty ==
                              true
                          ? 'Your selfie is on file for liveness and face-match review.'
                          : 'Upload a clear selfie so the face verification workflow can start.',
                    ),
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(26),
                        boxShadow: const <BoxShadow>[
                          BoxShadow(
                            color: Color(0x10000000),
                            blurRadius: 14,
                            offset: Offset(0, 8),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          const Text(
                            'Provider readiness',
                            style: TextStyle(
                              fontSize: 21,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'NIN, BVN, liveness, and face-match adapters are prepared in the backend so approved KYC providers can be connected later without changing the app experience.',
                            style: TextStyle(
                              color: Colors.black.withValues(alpha: 0.66),
                              height: 1.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (!isApproved) ...<Widget>[
                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _openingSubmission
                              ? null
                              : _openSubmissionFlow,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _gold,
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                            ),
                          ),
                          icon: const Icon(Icons.verified_user_outlined),
                          label: Text(
                            _openingSubmission
                                ? 'Opening...'
                                : 'Complete ${RiderVerificationCopy.title}',
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
      ),
    );
  }
}

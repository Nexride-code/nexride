import 'dart:async';

import 'package:firebase_database/firebase_database.dart' as rtdb;
import 'package:flutter/material.dart';

import '../config/driver_app_config.dart';
import 'driver_document_submission_screen.dart';
import '../support/driver_profile_support.dart';
import '../support/realtime_database_error_support.dart';

class DriverVerificationScreen extends StatefulWidget {
  const DriverVerificationScreen({
    super.key,
    required this.driverId,
  });

  final String driverId;

  @override
  State<DriverVerificationScreen> createState() =>
      _DriverVerificationScreenState();
}

class _DriverVerificationScreenState extends State<DriverVerificationScreen> {
  final rtdb.DatabaseReference _rootRef = rtdb.FirebaseDatabase.instance.ref();

  Map<String, dynamic> _driverProfile = <String, dynamic>{};
  Map<String, dynamic> _verification = normalizedDriverVerification(null);
  bool _loading = true;
  String? _activeDocumentKey;

  @override
  void initState() {
    super.initState();
    _loadVerification();
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

  Future<void> _loadVerification() async {
    final profilePath = 'drivers/${widget.driverId}';
    debugPrint('[DriverVerification] load driverId=${widget.driverId}');
    try {
      final snapshot = await runOptionalRealtimeDatabaseRead<rtdb.DataSnapshot>(
        source: 'driver_verification.load_profile',
        path: profilePath,
        action: () => _rootRef.child(profilePath).get(),
      );
      final rawProfile = snapshot?.value is Map
          ? Map<String, dynamic>.from(snapshot!.value as Map)
          : <String, dynamic>{};

      final normalizedProfile = buildDriverProfileRecord(
        driverId: widget.driverId,
        existing: rawProfile,
      );
      final normalizedVerification = normalizedDriverVerification(
        normalizedProfile['verification'],
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _driverProfile = normalizedProfile;
        _verification = normalizedVerification;
        _loading = false;
      });

      unawaited(
        _persistVerificationSnapshot(
          normalizedProfile: normalizedProfile,
          normalizedVerification: normalizedVerification,
        ),
      );
    } catch (error, stackTrace) {
      debugPrint('[DriverVerification] load failed: $error');
      debugPrintStack(
        label: '[DriverVerification] load stack',
        stackTrace: stackTrace,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _driverProfile = buildDriverProfileRecord(
          driverId: widget.driverId,
          existing: const <String, dynamic>{},
        );
        _verification = normalizedDriverVerification(null);
        _loading = false;
      });
      _showMessage(
        realtimeDatabaseDebugMessage(
          'Verification details could not be refreshed right now. We opened the screen with safe defaults.',
          path: profilePath,
          error: error,
        ),
      );
    }
  }

  Future<void> _persistVerificationSnapshot({
    required Map<String, dynamic> normalizedProfile,
    required Map<String, dynamic> normalizedVerification,
  }) async {
    final updatePath = 'drivers/${widget.driverId}/businessModel + '
        'drivers/${widget.driverId}/verification + '
        'driver_verifications/${widget.driverId}';
    try {
      await _rootRef.update(<String, dynamic>{
        'drivers/${widget.driverId}/businessModel':
            normalizedProfile['businessModel'],
        'drivers/${widget.driverId}/verification': normalizedVerification,
        'drivers/${widget.driverId}/updated_at': rtdb.ServerValue.timestamp,
        'driver_verifications/${widget.driverId}':
            buildDriverVerificationAdminPayload(
          driverId: widget.driverId,
          driverProfile: normalizedProfile,
          verification: normalizedVerification,
        )..['updatedAt'] = rtdb.ServerValue.timestamp,
      });
    } catch (error, stackTrace) {
      debugPrint('[DriverVerification] persist failed: $error');
      debugPrintStack(
        label: '[DriverVerification] persist stack',
        stackTrace: stackTrace,
      );
      _showMessage(
        realtimeDatabaseDebugMessage(
          'Verification details are visible, but background sync could not finish just now.',
          path: updatePath,
          error: error,
        ),
      );
    }
  }

  Future<void> _openDocumentFlow(DriverRequiredDocument document) async {
    if (_activeDocumentKey != null) {
      return;
    }

    final documents = Map<String, dynamic>.from(
      _verification['documents'] as Map<String, dynamic>? ??
          <String, dynamic>{},
    );
    final currentDocument = Map<String, dynamic>.from(
      documents[document.key] as Map? ?? <String, dynamic>{},
    );

    debugPrint('[DriverVerification] open document flow key=${document.key}');
    setState(() {
      _activeDocumentKey = document.key;
    });

    DriverDocumentSubmissionResult? result;
    try {
      result = await Navigator.of(context).push<DriverDocumentSubmissionResult>(
        MaterialPageRoute<DriverDocumentSubmissionResult>(
          builder: (_) => DriverDocumentSubmissionScreen(
            driverId: widget.driverId,
            driverProfile: _driverProfile,
            verification: _verification,
            document: document,
            currentDocument: currentDocument,
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _activeDocumentKey = null;
        });
      }
    }

    if (!mounted || result == null) {
      return;
    }
    final resolvedResult = result;

    debugPrint('[DriverVerification] document updated key=${document.key}');
    setState(() {
      _verification = normalizedDriverVerification(
        resolvedResult.updatedVerification,
      );
      _driverProfile = buildDriverProfileDefaults(
        driverId: widget.driverId,
        existing: resolvedResult.updatedDriverProfile,
      );
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

  String _documentActionLabel(String status) {
    return switch (status) {
      'approved' => 'Update file',
      'rejected' => 'Resubmit',
      'submitted' || 'checking' || 'manual_review' => 'Edit submission',
      _ => 'Upload document',
    };
  }

  String _documentStatusMessage(String status) {
    return switch (status) {
      'approved' =>
        'This document is approved. You can still replace it if details change.',
      'rejected' =>
        'This document needs attention. Update it and submit again for review.',
      'submitted' =>
        'Your submission was received and is waiting to be reviewed.',
      'checking' =>
        'This document is being checked and may be sent to a provider later.',
      'manual_review' =>
        'This document is with the review team for verification and accuracy checks.',
      _ => 'Upload this document to move your account closer to approval.',
    };
  }

  String _serviceApprovalSummary(String status) {
    return switch (status) {
      'approved' => 'Ready for dispatch to this service category.',
      'rejected' => 'Requires updated documents before activation.',
      'submitted' =>
        'Submission received. This service category is waiting for review.',
      'checking' => 'Checks are in progress for this service category.',
      'manual_review' =>
        'Manual review is in progress for this service category.',
      _ => 'Required documents are still missing for this service category.',
    };
  }

  Widget _buildStatusChip({
    required String label,
    required Color color,
    bool compact = false,
  }) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 10 : 12,
        vertical: compact ? 6 : 8,
      ),
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
          fontSize: compact ? 11 : 12,
        ),
      ),
    );
  }

  Widget _buildKeyStat({
    required String value,
    required String label,
  }) {
    return Container(
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
            style: const TextStyle(
              color: Colors.white,
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
    );
  }

  Widget _buildServiceApprovalCard(
    String serviceType,
    Map<String, dynamic> approval,
  ) {
    final status = approval['status']?.toString() ?? 'missing';
    final color = driverServiceApprovalStatusColor(status);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: color.withValues(alpha: 0.15)),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x11000000),
            blurRadius: 12,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  driverScopeLabel(serviceType),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              _buildStatusChip(
                label: driverServiceApprovalStatusLabel(status),
                color: color,
                compact: true,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            _serviceApprovalSummary(status),
            style: TextStyle(
              color: Colors.black.withValues(alpha: 0.64),
              height: 1.45,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDocumentMetaPill({
    required IconData icon,
    required String label,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: kDriverCream,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 16, color: kDriverGold),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.black.withValues(alpha: 0.72),
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDocumentCard(DriverRequiredDocument document) {
    final documents = Map<String, dynamic>.from(
      _verification['documents'] as Map<String, dynamic>? ??
          <String, dynamic>{},
    );
    final currentDocument = Map<String, dynamic>.from(
      documents[document.key] as Map? ?? <String, dynamic>{},
    );
    final status = currentDocument['status']?.toString() ?? 'missing';
    final fileName = currentDocument['fileName']?.toString().trim() ?? '';
    final documentNumber =
        currentDocument['documentNumber']?.toString().trim() ?? '';
    final updatedLabel = _formatTimestamp(
      currentDocument['updatedAt'] ?? currentDocument['submittedAt'],
    );
    final isBusy = _activeDocumentKey == document.key;
    final color = driverDocumentStatusColor(status);

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
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(26),
          onTap: isBusy ? null : () => unawaited(_openDocumentFlow(document)),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final compactHeader = constraints.maxWidth < 420;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    if (compactHeader) ...<Widget>[
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Container(
                            width: 54,
                            height: 54,
                            decoration: BoxDecoration(
                              color: kDriverGold.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Icon(document.icon, color: kDriverGold),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  document.label,
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  document.description,
                                  style: TextStyle(
                                    color: Colors.black.withValues(alpha: 0.64),
                                    height: 1.45,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _buildStatusChip(
                        label: driverDocumentStatusLabel(status),
                        color: color,
                      ),
                    ] else
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Container(
                            width: 54,
                            height: 54,
                            decoration: BoxDecoration(
                              color: kDriverGold.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Icon(document.icon, color: kDriverGold),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  document.label,
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  document.description,
                                  style: TextStyle(
                                    color: Colors.black.withValues(alpha: 0.64),
                                    height: 1.45,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          _buildStatusChip(
                            label: driverDocumentStatusLabel(status),
                            color: color,
                          ),
                        ],
                      ),
                    const SizedBox(height: 16),
                    Text(
                      _documentStatusMessage(status),
                      style: TextStyle(
                        color: Colors.black.withValues(alpha: 0.72),
                        fontWeight: FontWeight.w600,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: <Widget>[
                        _buildDocumentMetaPill(
                          icon: Icons.schedule_outlined,
                          label: 'Updated $updatedLabel',
                        ),
                        if (fileName.isNotEmpty)
                          _buildDocumentMetaPill(
                            icon: Icons.attachment_outlined,
                            label: fileName,
                          ),
                        if (documentNumber.isNotEmpty)
                          _buildDocumentMetaPill(
                            icon: Icons.pin_outlined,
                            label: documentNumber,
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        minHeight: 8,
                        value: driverDocumentProgressValue(status),
                        backgroundColor: Colors.black.withValues(alpha: 0.06),
                        valueColor: AlwaysStoppedAnimation<Color>(color),
                      ),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: isBusy
                            ? null
                            : () => unawaited(_openDocumentFlow(document)),
                        icon: Icon(
                          status == 'missing'
                              ? Icons.file_upload_outlined
                              : Icons.edit_outlined,
                        ),
                        label: Text(
                          isBusy ? 'Opening...' : _documentActionLabel(status),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final status = _verification['status']?.toString() ?? 'missing';
    final overallStatus =
        _verification['overallStatus']?.toString() ?? 'incomplete';
    final requiredCount =
        int.tryParse(_verification['requiredCount']?.toString() ?? '') ??
            kDriverRequiredDocuments.length;
    final submittedCount =
        int.tryParse(_verification['submittedCount']?.toString() ?? '') ?? 0;
    final approvedCount =
        int.tryParse(_verification['approvedCount']?.toString() ?? '') ?? 0;
    final serviceApprovals = Map<String, dynamic>.from(
      _verification['serviceApprovals'] as Map<String, dynamic>? ??
          <String, dynamic>{},
    );
    final approvedServices = driverApprovedServiceLabels(_verification);

    return Scaffold(
      backgroundColor: kDriverCream,
      appBar: AppBar(
        backgroundColor: kDriverGold,
        foregroundColor: Colors.black,
        centerTitle: true,
        title: const Text('Driver Verification'),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                color: kDriverGold,
                onRefresh: _loadVerification,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
                  children: <Widget>[
                    Container(
                      padding: const EdgeInsets.all(22),
                      decoration: BoxDecoration(
                        color: kDriverDark,
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
                                      'Verification ${driverVerificationStatusLabel(overallStatus)}',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 27,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      driverVerificationEligibilityMessage(
                                        _verification,
                                      ),
                                      style: TextStyle(
                                        color: Colors.white
                                            .withValues(alpha: 0.76),
                                        height: 1.55,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              _buildStatusChip(
                                label: driverVerificationStatusLabel(status),
                                color: driverVerificationStatusColor(status),
                              ),
                            ],
                          ),
                          const SizedBox(height: 18),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(999),
                            child: LinearProgressIndicator(
                              minHeight: 9,
                              value: driverVerificationProgressValue(
                                  _verification),
                              backgroundColor:
                                  Colors.white.withValues(alpha: 0.10),
                              valueColor: const AlwaysStoppedAnimation<Color>(
                                  kDriverGold),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Reviews may take up to 3 days. Documents are reviewed for accuracy and compliance before any service category is approved.',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.78),
                              height: 1.5,
                            ),
                          ),
                          if (approvedServices.isNotEmpty) ...<Widget>[
                            const SizedBox(height: 12),
                            Text(
                              'Approved service categories: ${approvedServices.join(', ')}',
                              style: const TextStyle(
                                color: Color(0xFFF7E7C9),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                          const SizedBox(height: 16),
                          LayoutBuilder(
                            builder: (
                              BuildContext context,
                              BoxConstraints constraints,
                            ) {
                              final statWidth = constraints.maxWidth < 520
                                  ? constraints.maxWidth
                                  : (constraints.maxWidth - 12) / 2;
                              return Wrap(
                                spacing: 12,
                                runSpacing: 12,
                                children: <Widget>[
                                  SizedBox(
                                    width: statWidth,
                                    child: _buildKeyStat(
                                      value: '$submittedCount/$requiredCount',
                                      label: 'Documents submitted',
                                    ),
                                  ),
                                  SizedBox(
                                    width: statWidth,
                                    child: _buildKeyStat(
                                      value: '$approvedCount',
                                      label: 'Documents approved',
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ],
                      ),
                    ),
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
                            'Checklist overview',
                            style: TextStyle(
                              fontSize: 21,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Complete each document card below. Once submitted, NexRide stores the upload securely, records review checks, and keeps an audit trail for future support and admin review.',
                            style: TextStyle(
                              color: Colors.black.withValues(alpha: 0.66),
                              height: 1.5,
                            ),
                          ),
                        ],
                      ),
                    ),
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
                            'Service readiness',
                            style: TextStyle(
                              fontSize: 21,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            DriverFeatureFlags.driverVerificationRequired
                                ? 'Approval is tracked separately for rides, dispatch and delivery, groceries and mart, and restaurants and food. Drivers stay offline until an approved service category is available.'
                                : 'Approval is tracked separately for rides, dispatch and delivery, groceries and mart, and restaurants and food. Driver verification remains active in the backend, but it does not block going online while this flag is off.',
                            style: TextStyle(
                              color: Colors.black.withValues(alpha: 0.66),
                              height: 1.5,
                            ),
                          ),
                          const SizedBox(height: 16),
                          LayoutBuilder(
                            builder: (
                              BuildContext context,
                              BoxConstraints constraints,
                            ) {
                              final crossAxisCount = constraints.maxWidth >= 880
                                  ? 3
                                  : constraints.maxWidth >= 520
                                      ? 2
                                      : 1;
                              final aspectRatio =
                                  crossAxisCount == 1 ? 2.15 : 1.38;
                              return GridView.count(
                                physics: const NeverScrollableScrollPhysics(),
                                shrinkWrap: true,
                                crossAxisCount: crossAxisCount,
                                crossAxisSpacing: 12,
                                mainAxisSpacing: 12,
                                childAspectRatio: aspectRatio,
                                children: kDriverServiceTypes
                                    .map(
                                      (String serviceType) =>
                                          _buildServiceApprovalCard(
                                        serviceType,
                                        Map<String, dynamic>.from(
                                          serviceApprovals[serviceType]
                                                  as Map? ??
                                              <String, dynamic>{},
                                        ),
                                      ),
                                    )
                                    .toList(),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    ...kDriverRequiredDocuments.map(_buildDocumentCard),
                  ],
                ),
              ),
      ),
    );
  }
}

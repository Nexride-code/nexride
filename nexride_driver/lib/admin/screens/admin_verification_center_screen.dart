import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../admin_config.dart';
import '../admin_rbac.dart';
import '../models/admin_audit_event.dart';
import '../models/admin_models.dart';
import '../platform/admin_action_policy.dart';
import '../platform/admin_error_code.dart';
import '../services/admin_action_executor.dart';
import '../widgets/admin_components.dart';
import '../widgets/admin_sensitive_action_dialog.dart';

/// Phase 2D — `/admin/verification`: riders, drivers, merchants (unified list + actions).
class AdminVerificationCenterScreen extends StatefulWidget {
  const AdminVerificationCenterScreen({super.key, required this.session});

  final AdminSession session;

  @override
  State<AdminVerificationCenterScreen> createState() =>
      _AdminVerificationCenterScreenState();
}

class _AdminVerificationCenterScreenState extends State<AdminVerificationCenterScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  FirebaseFunctions get _fn =>
      FirebaseFunctions.instanceFor(region: 'us-central1');

  static const AdminActionExecutor _mutations = AdminActionExecutor();

  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _rows = const <Map<String, dynamic>>[];
  String _statusFilter = 'pending';

  static const List<String> _tabUserTypes = <String>[
    'rider',
    'driver',
    'merchant',
    'all',
  ];

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: _tabUserTypes.length, vsync: this);
    _tabs.addListener(_onTab);
    _load();
  }

  void _onTab() {
    if (_tabs.indexIsChanging) return;
    _load();
  }

  @override
  void dispose() {
    _tabs.removeListener(_onTab);
    _tabs.dispose();
    super.dispose();
  }

  Map<String, dynamic> _asMap(dynamic v) {
    if (v is Map) {
      return v.map((k, dynamic val) => MapEntry(k.toString(), val));
    }
    return <String, dynamic>{};
  }

  String _text(dynamic v) => v?.toString().trim() ?? '';

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final callable = _fn.httpsCallable(
        'adminListVerificationUploads',
        options: HttpsCallableOptions(timeout: const Duration(seconds: 60)),
      );
      final result = await callable.call(<String, dynamic>{
        'userType': _tabUserTypes[_tabs.index],
        'status': _statusFilter,
        'limit': 200,
      });
      final data = _asMap(result.data);
      if (data['success'] != true) {
        throw StateError(_text(data['reason']).isEmpty ? 'load_failed' : _text(data['reason']));
      }
      final raw = data['rows'];
      final list = <Map<String, dynamic>>[];
      if (raw is List) {
        for (final item in raw) {
          if (item is Map) {
            list.add(item.map((k, v) => MapEntry(k.toString(), v)));
          }
        }
      }
      if (!mounted) return;
      setState(() {
        _rows = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _promptNoteAndRun(
    Future<void> Function(String note) run,
  ) async {
    final noteController = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Note to user'),
        content: TextField(
          controller: noteController,
          maxLines: 4,
          decoration: const InputDecoration(
            labelText: 'Required for reject / resubmission (min 8 chars)',
            border: OutlineInputBorder(),
          ),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Submit')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final note = noteController.text.trim();
    if (note.length < 8) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Note is required (min 8 characters).')),
      );
      return;
    }
    await run(note);
  }

  Future<void> _approve(Map<String, dynamic> row) async {
    final String? reason = await showAdminSensitiveActionDialog(
      context,
      title: 'Approve verification document',
      message:
          'Enter an internal rationale for approving this document. It is stored on the server audit trail.',
      confirmLabel: 'Approve',
      minReasonLength: 8,
    );
    if (reason == null) {
      return;
    }
    await _mutations.run<void>(
      context: context,
      actionName: 'verification_document_approve',
      cooldown: AdminActionPolicy.verificationActionCooldown,
      invoke: () =>
          _invokeDocumentReview(row, verb: 'approve', approvalNote: reason),
      successMessage: 'Document approved',
      emitAudit: ({
        required bool success,
        Object? value,
        Object? error,
        required String correlationId,
      }) {
        return _verificationAudit(
          action: 'verification_document_approve',
          row: row,
          success: success,
          afterSuccess: 'approved',
          error: error,
          correlationId: correlationId,
          extra: <String, dynamic>{'note': reason},
        );
      },
      onSuccess: (_) {
        unawaited(_load());
      },
    );
  }

  Future<void> _reject(Map<String, dynamic> row) async {
    await _promptNoteAndRun((String note) async {
      await _mutations.run<void>(
        context: context,
        actionName: 'verification_document_reject',
        cooldown: AdminActionPolicy.verificationActionCooldown,
        invoke: () => _invokeDocumentReview(row, verb: 'reject', rejectionNote: note),
        successMessage: 'Document rejected',
        emitAudit: ({
          required bool success,
          Object? value,
          Object? error,
          required String correlationId,
        }) {
          return _verificationAudit(
            action: 'verification_document_reject',
            row: row,
            success: success,
            afterSuccess: 'rejected',
            error: error,
            correlationId: correlationId,
            extra: <String, dynamic>{'note': note},
          );
        },
        onSuccess: (_) {
          unawaited(_load());
        },
      );
    });
  }

  Future<void> _resubmit(Map<String, dynamic> row) async {
    await _promptNoteAndRun((String note) async {
      await _mutations.run<void>(
        context: context,
        actionName: 'verification_document_require_resubmit',
        cooldown: AdminActionPolicy.verificationActionCooldown,
        invoke: () =>
            _invokeDocumentReview(row, verb: 'require_resubmit', rejectionNote: note),
        successMessage: 'Resubmission requested',
        emitAudit: ({
          required bool success,
          Object? value,
          Object? error,
          required String correlationId,
        }) {
          return _verificationAudit(
            action: 'verification_document_require_resubmit',
            row: row,
            success: success,
            afterSuccess: 'resubmission_required',
            error: error,
            correlationId: correlationId,
            extra: <String, dynamic>{'note': note},
          );
        },
        onSuccess: (_) {
          unawaited(_load());
        },
      );
    });
  }

  AdminAuditEvent _verificationAudit({
    required String action,
    required Map<String, dynamic> row,
    required bool success,
    required String afterSuccess,
    Object? error,
    required String correlationId,
    Map<String, dynamic> extra = const <String, dynamic>{},
  }) {
    final User? actor = FirebaseAuth.instance.currentUser;
    final String ut = _text(row['user_type']).toLowerCase();
    final String uid = _text(row['user_id']);
    String entityId = uid;
    if (ut == 'merchant') {
      entityId =
          _text(row['merchant_id']).isEmpty ? uid : _text(row['merchant_id']);
    }
    return AdminAuditEvent(
      actorUid: actor?.uid ?? '',
      actorEmail: actor?.email ?? '',
      entityType: ut.isEmpty ? 'verification' : '${ut}_verification',
      entityId: entityId,
      action: action,
      before: row['status'],
      after: success ? afterSuccess : null,
      metadata: <String, dynamic>{
        'document_type': _text(row['document_type']),
        ...extra,
        if (!success && error != null) 'error': error.toString(),
      },
      correlationId: correlationId,
    );
  }

  Future<void> _invokeDocumentReview(
    Map<String, dynamic> row, {
    required String verb,
    String? rejectionNote,
    String? approvalNote,
  }) async {
    final String ut = _text(row['user_type']).toLowerCase();
    final String uid = _text(row['user_id']);
    final String docType = _text(row['document_type']);
    if (ut == 'merchant') {
      final String mid =
          _text(row['merchant_id']).isEmpty ? uid : _text(row['merchant_id']);
      final Map<String, dynamic> body = <String, dynamic>{
        'merchant_id': mid,
        'document_type': docType,
        'action': _verbToAction(verb),
      };
      if (verb != 'approve') {
        body['rejection_reason'] = rejectionNote ?? '';
      } else if (approvalNote != null && approvalNote.trim().isNotEmpty) {
        body['admin_note'] = approvalNote.trim();
        body['note'] = approvalNote.trim();
      }
      await _callReviewCallable('adminReviewMerchantDocument', body);
      return;
    }
    if (ut == 'driver') {
      final Map<String, dynamic> body = <String, dynamic>{
        'driver_id': uid,
        'document_type': docType,
        'action': _verbToAction(verb),
      };
      if (verb != 'approve') {
        body['note'] = rejectionNote ?? '';
      } else if (approvalNote != null && approvalNote.trim().isNotEmpty) {
        body['note'] = approvalNote.trim();
      }
      await _callReviewCallable('adminReviewDriverDocument', body);
      return;
    }
    if (ut == 'rider') {
      final Map<String, dynamic> body = <String, dynamic>{
        'user_id': uid,
        'document_type': docType,
        'action': _verbToAction(verb),
      };
      if (verb != 'approve') {
        body['note'] = rejectionNote ?? '';
      } else if (approvalNote != null && approvalNote.trim().isNotEmpty) {
        body['note'] = approvalNote.trim();
      }
      await _callReviewCallable('adminReviewRiderDocument', body);
      return;
    }
    throw AdminStructuredActionFailure(
      code: 'validation_failed',
      message: 'Unknown user type: $ut',
      adminCode: AdminErrorCode.validationFailed,
    );
  }

  String _verbToAction(String verb) {
    if (verb == 'require_resubmit') {
      return 'require_resubmit';
    }
    return verb;
  }

  Future<void> _callReviewCallable(String name, Map<String, dynamic> body) async {
    final HttpsCallable callable = _fn.httpsCallable(
      name,
      options: HttpsCallableOptions(timeout: Duration(seconds: 60)),
    );
    final HttpsCallableResult result = await callable.call(body);
    final Map<String, dynamic> data = _asMap(result.data);
    if (data['success'] == true) {
      return;
    }
    final String code =
        _text(data['code']).isEmpty ? 'validation_failed' : _text(data['code']);
    throw AdminStructuredActionFailure(
      code: code,
      message: _text(data['message']).isNotEmpty
          ? _text(data['message'])
          : (_text(data['reason']).isNotEmpty
              ? _text(data['reason'])
              : 'Review failed'),
      retryable: data['retryable'] == true || code == 'stale_entity',
      adminCode: AdminErrorCode.fromWire(code),
    );
  }

  Future<void> _openUrl(String? url) async {
    final u = url?.trim() ?? '';
    if (u.isEmpty) return;
    final uri = Uri.tryParse(u);
    if (uri == null) return;
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open link')),
      );
    }
  }

  String _fmtTime(dynamic ms) {
    final n = ms is num ? ms.round() : int.tryParse(_text(ms));
    if (n == null || n <= 0) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch(n);
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} '
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const AdminSectionHeader(
          title: 'Verification center',
          description:
              'Review and approve rider identity, driver KYC uploads, and merchant verification documents in one queue. Default view is pending items.',
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            DropdownButton<String>(
              value: _statusFilter,
              items: const <DropdownMenuItem<String>>[
                DropdownMenuItem(value: 'pending', child: Text('Pending')),
                DropdownMenuItem(value: 'all', child: Text('All statuses')),
                DropdownMenuItem(value: 'approved', child: Text('Approved')),
                DropdownMenuItem(value: 'rejected', child: Text('Rejected')),
                DropdownMenuItem(
                  value: 'resubmission_required',
                  child: Text('Resubmission required'),
                ),
              ],
              onChanged: (v) {
                if (v == null) return;
                setState(() => _statusFilter = v);
                _load();
              },
            ),
            OutlinedButton.icon(
              onPressed: _loading ? null : _load,
              icon: _loading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Refresh'),
            ),
          ],
        ),
        Material(
          color: AdminThemeTokens.canvas,
          child: TabBar(
            controller: _tabs,
            isScrollable: true,
            tabs: const <Tab>[
              Tab(text: 'Riders'),
              Tab(text: 'Drivers'),
              Tab(text: 'Merchants'),
              Tab(text: 'All'),
            ],
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          )
        else
          SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.58,
            child: _buildGroupedList(),
          ),
      ],
    );
  }

  Widget _buildGroupedList() {
    if (_rows.isEmpty) {
      return const AdminEmptyState(
        title: 'No verification rows',
        message:
            'Try another tab, set status to “All statuses”, or refresh after new uploads are submitted.',
        icon: Icons.verified_user_outlined,
      );
    }
    final sorted = List<Map<String, dynamic>>.from(_rows)
      ..sort((a, b) {
        final ta = _text(a['user_type']);
        final tb = _text(b['user_type']);
        final c = ta.compareTo(tb);
        if (c != 0) return c;
        final ma = a['uploaded_at'] is num ? (a['uploaded_at'] as num).round() : 0;
        final mb = b['uploaded_at'] is num ? (b['uploaded_at'] as num).round() : 0;
        return mb.compareTo(ma);
      });

    String? lastType;
    final children = <Widget>[];
    for (final row in sorted) {
      final t = _text(row['user_type']);
      if (t != lastType) {
        lastType = t;
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 6),
            child: Text(
              t.isEmpty ? 'Unknown' : '${t[0].toUpperCase()}${t.substring(1)}s',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: AdminThemeTokens.ink,
                  ),
            ),
          ),
        );
      }
      children.add(_rowCard(row));
    }
    return ListView(padding: const EdgeInsets.only(bottom: 24), children: children);
  }

  /// Hide approve / reject / resubmit once this upload row is already accepted.
  bool _isDocumentAlreadyAccepted(Map<String, dynamic> row) {
    final st = _text(row['status']).toLowerCase();
    return st == 'approved' || st == 'verified';
  }

  Widget _rowCard(Map<String, dynamic> row) {
    final ut = _text(row['user_type']).toLowerCase();
    final docAccepted = _isDocumentAlreadyAccepted(row);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AdminSurfaceCard(
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
                        _text(row['display_name']).isEmpty ? _text(row['user_id']) : _text(row['display_name']),
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                              color: AdminThemeTokens.ink,
                            ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${_text(row['email'])} · ${_text(row['phone'])}',
                        style: const TextStyle(fontSize: 13, color: Color(0xFF6A6359)),
                      ),
                      const SizedBox(height: 6),
                      Text('Document: ${_text(row['document_type'])} · Status: ${_text(row['status'])}'),
                      Text('Uploaded: ${_fmtTime(row['uploaded_at'])} · Reviewed: ${_fmtTime(row['reviewed_at'])}'),
                      if (_text(row['storage_path']).isNotEmpty)
                        SelectableText(
                          'Storage: ${_text(row['storage_path'])}',
                          style: const TextStyle(fontSize: 12, color: Color(0xFF3D3A35)),
                        ),
                      if (_text(row['admin_note']).isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            'Note: ${_text(row['admin_note'])}',
                            style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.error),
                          ),
                        ),
                      if (ut == 'merchant' && _text(row['readiness_summary']).isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            'Readiness: ${_text(row['readiness_summary'])}',
                            style: const TextStyle(fontSize: 13, color: Color(0xFF55514A)),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                TextButton.icon(
                  onPressed: _text(row['signed_url']).isEmpty
                      ? null
                      : () => _openUrl(_text(row['signed_url'])),
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  label: const Text('Open document'),
                ),
                if (docAccepted)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(Icons.check_circle_rounded, size: 20, color: Colors.green.shade700),
                        const SizedBox(width: 8),
                        Text(
                          'No further review actions for this row.',
                          style: TextStyle(fontSize: 13, color: Colors.grey.shade800),
                        ),
                      ],
                    ),
                  )
                else ...<Widget>[
                  Builder(
                    builder: (BuildContext ctx) {
                      final String ut = _text(row['user_type']).toLowerCase();
                      final String docPerm =
                          ut == 'merchant' ? 'merchants.write' : 'verification.approve';
                      final bool canDoc = widget.session.hasPermission(docPerm);
                      final approveBtn = FilledButton(
                        onPressed: canDoc ? () => _approve(row) : null,
                        child: const Text('Approve'),
                      );
                      final rejectBtn = OutlinedButton(
                        onPressed: canDoc ? () => _reject(row) : null,
                        child: const Text('Reject'),
                      );
                      final resubmitBtn = OutlinedButton(
                        onPressed: canDoc ? () => _resubmit(row) : null,
                        child: const Text('Ask resubmit (this document)'),
                      );
                      return Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: <Widget>[
                          canDoc
                              ? approveBtn
                              : Tooltip(
                                  message: kAdminNoPermissionTooltip,
                                  child: approveBtn,
                                ),
                          canDoc
                              ? rejectBtn
                              : Tooltip(
                                  message: kAdminNoPermissionTooltip,
                                  child: rejectBtn,
                                ),
                          canDoc
                              ? resubmitBtn
                              : Tooltip(
                                  message: kAdminNoPermissionTooltip,
                                  child: resubmitBtn,
                                ),
                        ],
                      );
                    },
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

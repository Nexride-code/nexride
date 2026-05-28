import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../admin_config.dart';
import '../models/admin_models.dart';
import '../widgets/admin_components.dart';
import '../widgets/admin_permission_gate.dart';

/// Dispatch Fleet operator approvals — separate from merchant commerce.
class AdminDispatchFleetScreen extends StatefulWidget {
  const AdminDispatchFleetScreen({super.key, required this.session});

  final AdminSession session;

  @override
  State<AdminDispatchFleetScreen> createState() => _AdminDispatchFleetScreenState();
}

class _AdminDispatchFleetScreenState extends State<AdminDispatchFleetScreen> {
  static const Set<String> _filters = <String>{
    'all',
    'pending_documents',
    'pending_review',
    'approved',
    'rejected',
    'suspended',
  };

  bool _loading = true;
  String? _error;
  String _filter = 'pending_review';
  List<Map<String, dynamic>> _rows = const <Map<String, dynamic>>[];
  bool _hasMore = false;
  Map<String, dynamic>? _nextCursor;

  String? _detailForId;
  Map<String, dynamic>? _detailAccount;
  bool _detailLoading = false;

  List<Map<String, dynamic>> _linkedBikers = const <Map<String, dynamic>>[];
  bool _linkedBikersLoading = false;
  String? _linkedBikersError;
  String? _linkedBikersCursor;
  bool _linkedBikersHasMore = false;

  FirebaseFunctions get _fn =>
      FirebaseFunctions.instanceFor(region: 'us-central1');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Map<String, dynamic> _asMap(dynamic data) {
    if (data is Map) {
      return data.map((dynamic k, dynamic v) => MapEntry(k.toString(), v));
    }
    return <String, dynamic>{};
  }

  String _verificationTypeLabel(String raw) {
    switch (raw.trim().toLowerCase()) {
      case 'nin_individual_business':
        return 'NIN individual business';
      case 'cac_business':
        return 'CAC registered business';
      default:
        return raw.isEmpty ? 'CAC registered business' : raw;
    }
  }

  String _documentStatusLabel(String status) {
    switch (status.trim().toLowerCase()) {
      case 'not_submitted':
        return 'Not submitted';
      case 'pending':
        return 'Pending review';
      case 'approved':
        return 'Approved';
      case 'rejected':
        return 'Rejected';
      case 'resubmission_required':
        return 'Resubmission required';
      default:
        return status.isEmpty ? 'Unknown' : status;
    }
  }

  Future<void> _viewDocument(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Document link is not available.')),
        );
      }
      return;
    }
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open document.')),
      );
    }
  }

  Future<void> _refreshDetail() async {
    final businessId = _detailForId;
    if (businessId == null || businessId.isEmpty) {
      return;
    }
    await _openDetail(businessId);
  }

  Future<void> _loadLinkedBikers(String businessId, {bool append = false}) async {
    if (businessId.isEmpty) {
      return;
    }
    setState(() {
      _linkedBikersLoading = true;
      if (!append) {
        _linkedBikersError = null;
        _linkedBikers = const <Map<String, dynamic>>[];
        _linkedBikersCursor = null;
        _linkedBikersHasMore = false;
      }
    });

    try {
      final payload = <String, dynamic>{
        'business_id': businessId,
        'limit': 25,
      };
      if (append && _linkedBikersCursor != null && _linkedBikersCursor!.isNotEmpty) {
        payload['cursor_driver_id'] = _linkedBikersCursor;
      }

      final result = await _fn
          .httpsCallable(
            'adminListFleetLinkedDriversPage',
            options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
          )
          .call(payload);

      final data = _asMap(result.data);
      if (data['success'] != true) {
        throw StateError(data['reason']?.toString() ?? 'linked_bikers_failed');
      }

      final parsed = <Map<String, dynamic>>[];
      final raw = data['items'];
      if (raw is List) {
        for (final item in raw) {
          if (item is Map) {
            parsed.add(item.map((k, v) => MapEntry(k.toString(), v)));
          }
        }
      }

      if (!mounted) {
        return;
      }
      setState(() {
        _linkedBikers = append ? <Map<String, dynamic>>[..._linkedBikers, ...parsed] : parsed;
        _linkedBikersCursor = data['next_cursor_driver_id']?.toString();
        _linkedBikersHasMore = data['has_more'] == true;
        _linkedBikersLoading = false;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _linkedBikersLoading = false;
        _linkedBikersError = e.toString();
      });
    }
  }

  String _formatLinkedAt(dynamic raw) {
    final ms = int.tryParse(raw?.toString() ?? '');
    if (ms == null || ms <= 0) {
      return '—';
    }
    final dt = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }

  String _text(dynamic v) => v?.toString().trim() ?? '';

  Future<void> _load({bool append = false}) async {
    if (!append) {
      setState(() {
        _loading = true;
        _error = null;
        _nextCursor = null;
      });
    }

    try {
      final payload = <String, dynamic>{
        'limit': 25,
        'status': _filter,
      };
      if (append && _nextCursor != null) {
        payload.addAll(_nextCursor!);
      }

      final result = await _fn
          .httpsCallable(
            'adminListDispatchFleetPage',
            options: HttpsCallableOptions(timeout: const Duration(seconds: 45)),
          )
          .call(payload);

      final data = _asMap(result.data);
      if (data['success'] != true) {
        final reason = data['reason']?.toString() ?? 'list_failed';
        if (reason == 'firestore_index_required') {
          final indexUrl = data['index_url']?.toString().trim() ?? '';
          throw StateError(
            indexUrl.isNotEmpty
                ? 'Firestore index required. Create it in Firebase Console:\n$indexUrl'
                : (data['message']?.toString() ??
                    'Firestore composite index required for Dispatch Fleet list.'),
          );
        }
        throw StateError(reason);
      }

      final list = <Map<String, dynamic>>[];
      final raw = data['accounts'];
      if (raw is List) {
        for (final item in raw) {
          if (item is Map) {
            list.add(item.map((k, v) => MapEntry(k.toString(), v)));
          }
        }
      }

      final next = data['next_cursor'];
      Map<String, dynamic>? cursor;
      if (next is Map) {
        cursor = next.map((k, v) => MapEntry(k.toString(), v));
      }

      if (!mounted) {
        return;
      }
      setState(() {
        _rows = append ? <Map<String, dynamic>>[..._rows, ...list] : list;
        _hasMore = data['has_more'] == true;
        _nextCursor = cursor;
        _loading = false;
        if (!append) {
          _detailForId = null;
          _detailAccount = null;
        }
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _openDetail(String businessId) async {
    setState(() {
      _detailForId = businessId;
      _detailAccount = null;
      _detailLoading = true;
      _linkedBikers = const <Map<String, dynamic>>[];
      _linkedBikersError = null;
      _linkedBikersCursor = null;
      _linkedBikersHasMore = false;
    });

    try {
      final result = await _fn
          .httpsCallable(
            'adminGetDispatchFleetAccount',
            options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
          )
          .call(<String, dynamic>{'business_id': businessId});

      final data = _asMap(result.data);
      if (data['success'] != true) {
        throw StateError(data['reason']?.toString() ?? 'detail_failed');
      }
      final account = data['account'];
      if (!mounted) {
        return;
      }
      setState(() {
        _detailAccount = account is Map
            ? account.map((k, v) => MapEntry(k.toString(), v))
            : null;
        _detailLoading = false;
      });
      await _loadLinkedBikers(businessId);
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() => _detailLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not load account: $e')),
      );
    }
  }

  Future<void> _reviewDocument(
    String businessId,
    String documentType,
    String action,
  ) async {
    final noteController = TextEditingController();
    final requireNote = action == 'reject';
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(action == 'approve' ? 'Approve document' : 'Reject document'),
        content: TextField(
          controller: noteController,
          decoration: InputDecoration(
            labelText: requireNote ? 'Rejection reason' : 'Note (optional)',
            border: const OutlineInputBorder(),
          ),
          maxLines: 3,
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (requireNote && noteController.text.trim().length < 3) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text('Enter at least 3 characters.')),
                );
                return;
              }
              Navigator.pop(ctx, true);
            },
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    if (proceed != true || !mounted) {
      return;
    }
    try {
      final result = await _fn
          .httpsCallable('adminReviewFleetVerificationDocument')
          .call(<String, dynamic>{
            'business_id': businessId,
            'document_type': documentType,
            'action': action,
            'note': noteController.text.trim(),
            if (action == 'reject') 'rejection_reason': noteController.text.trim(),
          });
      final data = _asMap(result.data);
      if (data['success'] != true) {
        throw StateError(data['reason']?.toString() ?? 'doc_review_failed');
      }
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Document review saved')),
      );
      await _openDetail(businessId);
    } catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Document review failed: $e')),
      );
    }
  }

  Future<void> _review(
    String businessId,
    String action, {
    bool approvalOverride = false,
  }) async {
    final noteController = TextEditingController();
    final requireNote = action == 'reject' || approvalOverride;

    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          approvalOverride
              ? 'Approve fleet (override)'
              : action == 'approve'
                  ? 'Approve fleet'
                  : 'Reject fleet',
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (approvalOverride)
              const Text(
                'Documents are incomplete. Override approval requires a written reason '
                'and is recorded in the audit log.',
                style: TextStyle(fontSize: 13),
              )
            else if (requireNote)
              const Text(
                'A rejection note is required.',
                style: TextStyle(fontSize: 13),
              )
            else
              const Text(
                'Optional note for the review record.',
                style: TextStyle(fontSize: 13),
              ),
            const SizedBox(height: 12),
            TextField(
              controller: noteController,
              decoration: InputDecoration(
                labelText: approvalOverride
                    ? 'Override reason (required)'
                    : requireNote
                        ? 'Rejection reason'
                        : 'Note (optional)',
                border: const OutlineInputBorder(),
              ),
              maxLines: 3,
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (requireNote && noteController.text.trim().length < 3) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text('Enter at least 3 characters.')),
                );
                return;
              }
              Navigator.pop(ctx, true);
            },
            child: Text(approvalOverride ? 'Manual override approve' : action == 'approve' ? 'Approve fleet' : 'Reject fleet'),
          ),
        ],
      ),
    );

    if (proceed != true || !mounted) {
      return;
    }

    try {
      final result = await _fn
          .httpsCallable(
            'adminReviewDispatchFleet',
            options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
          )
          .call(<String, dynamic>{
            'business_id': businessId,
            'action': action,
            'note': noteController.text.trim(),
            if (approvalOverride) 'approval_override': true,
          });

      final data = _asMap(result.data);
      if (data['success'] != true) {
        final reason = data['reason']?.toString() ?? 'review_failed';
        if (reason == 'fleet_documents_incomplete') {
          throw StateError(
            'Cannot approve: required fleet documents are not all approved. '
            'Use override only with a documented reason.',
          );
        }
        if (reason == 'override_note_required') {
          throw StateError('Override approval requires a reason of at least 3 characters.');
        }
        throw StateError(reason);
      }

      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            approvalOverride
                ? 'Fleet approved with manual override'
                : action == 'approve'
                    ? 'Fleet approved'
                    : 'Fleet rejected',
          ),
        ),
      );
      await _load();
      if (_detailForId == businessId) {
        await _openDetail(businessId);
      }
    } catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Review failed: $e')),
      );
    }
  }

  Widget _statusChip(String status) {
    final s = status.toLowerCase();
    Color color = AdminThemeTokens.slate;
    if (s == 'approved') {
      color = AdminThemeTokens.success;
    } else if (s == 'rejected') {
      color = AdminThemeTokens.danger;
    } else if (s.contains('pending')) {
      color = AdminThemeTokens.warning;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        status.isEmpty ? '—' : status,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
      ),
    );
  }

  Widget _buildRow(Map<String, dynamic> row) {
    final id = _text(row['business_id']);
    final selected = _detailForId == id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected ? AdminThemeTokens.goldSoft : Colors.white,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: id.isEmpty ? null : () => _openDetail(id),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: selected ? AdminThemeTokens.gold : AdminThemeTokens.border,
              ),
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        _text(row['business_name']).isEmpty
                            ? 'Fleet business'
                            : _text(row['business_name']),
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Owner: ${_text(row['owner_name']).isEmpty ? '—' : _text(row['owner_name'])}',
                        style: const TextStyle(fontSize: 13),
                      ),
                      Text(
                        'Phone: ${_text(row['phone']).isEmpty ? '—' : _text(row['phone'])}',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    _statusChip(_text(row['merchant_status'])),
                    const SizedBox(height: 6),
                    Text(
                      _text(row['verification_status']),
                      style: const TextStyle(fontSize: 11),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDocumentCard({
    required String businessId,
    required Map<String, dynamic> doc,
  }) {
    final docType = _text(doc['document_type']);
    final docStatusRaw = _text(doc['status']);
    final docStatus =
        docStatusRaw.isEmpty ? 'not_submitted' : docStatusRaw.toLowerCase();
    final label = _text(doc['label']).isEmpty ? docType : _text(doc['label']);
    final url = _text(doc['download_url']);
    final isSubmitted = docStatus != 'not_submitted';
    final canReviewDoc = isSubmitted &&
        (docStatus == 'pending' ||
            docStatus == 'rejected' ||
            docStatus == 'resubmission_required');

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(label, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
            const SizedBox(height: 6),
            Text(
              'Status: ${_documentStatusLabel(docStatus)}',
              style: const TextStyle(fontSize: 13),
            ),
            if (!isSubmitted) ...<Widget>[
              const SizedBox(height: 8),
              const Text(
                'Not submitted',
                style: TextStyle(color: AdminThemeTokens.slate, fontSize: 13),
              ),
            ],
            if (isSubmitted && url.isNotEmpty) ...<Widget>[
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () => _viewDocument(url),
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('View document'),
              ),
            ],
            if (canReviewDoc && docType.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    FilledButton(
                      onPressed: businessId.isEmpty
                          ? null
                          : () => _reviewDocument(businessId, docType, 'approve'),
                      child: const Text('Approve document'),
                    ),
                    OutlinedButton(
                      onPressed: businessId.isEmpty
                          ? null
                          : () => _reviewDocument(businessId, docType, 'reject'),
                      child: const Text('Reject document'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailPanel() {
    if (_detailForId == null) {
      return const AdminSurfaceCard(
        child: Text(
          'Select a fleet account to view details and approve or reject.',
          style: TextStyle(color: AdminThemeTokens.slate),
        ),
      );
    }

    if (_detailLoading) {
      return const AdminSurfaceCard(
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final account = _detailAccount;
    if (account == null) {
      return const AdminSurfaceCard(
        child: Text('Could not load fleet account details.'),
      );
    }

    final businessId = _text(account['business_id']);
    final status = _text(account['merchant_status']).toLowerCase();
    final canReviewFleet = status == 'pending_review' ||
        status == 'pending' ||
        status == 'pending_documents';
    final docsComplete = account['required_documents_complete'] == true;
    final verificationType = _text(account['verification_type']);
    final readiness = account['readiness'];
    final documents = account['verification_documents'];
    final missingRequirements = readiness is Map ? readiness['missing_requirements'] : null;

    return AdminSurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      _text(account['business_name']).isEmpty
                          ? 'Fleet business'
                          : _text(account['business_name']),
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _statusChip(_text(account['merchant_status'])),
                  ],
                ),
              ),
              OutlinedButton.icon(
                onPressed: _detailLoading ? null : _refreshDetail,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Refresh'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Text(
            'Account details',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
          ),
          const SizedBox(height: 8),
          _detailLine('Owner', _text(account['owner_name'])),
          _detailLine('Phone', _text(account['phone'])),
          _detailLine('Status', _text(account['merchant_status'])),
          _detailLine(
            'Verification type',
            _verificationTypeLabel(verificationType),
          ),
          _detailLine('Business ID', businessId),
          _detailLine('Email', _text(account['contact_email'])),
          _detailLine('Documents complete', docsComplete ? 'Yes' : 'No'),
          if (readiness is Map && readiness['readable_message'] != null)
            _detailLine(
              'Readiness',
              readiness['readable_message']?.toString() ?? '',
            ),
          if (missingRequirements is List && missingRequirements.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            const Text(
              'Missing or pending items',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            ),
            const SizedBox(height: 4),
            ...missingRequirements.whereType<String>().map(
                  (item) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text('• $item', style: const TextStyle(fontSize: 13)),
                  ),
                ),
          ],
          if (_text(account['rejection_reason']).isNotEmpty)
            _detailLine('Rejection reason', _text(account['rejection_reason'])),
          const SizedBox(height: 16),
          const Text(
            'Verification documents',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
          ),
          const SizedBox(height: 8),
          if (documents is List && documents.isNotEmpty)
            ...documents.whereType<Map>().map(
                  (raw) => _buildDocumentCard(
                    businessId: businessId,
                    doc: raw.map((k, v) => MapEntry(k.toString(), v)),
                  ),
                )
          else
            const Text(
              'No verification documents on file yet.',
              style: TextStyle(color: AdminThemeTokens.slate),
            ),
          const SizedBox(height: 20),
          Row(
            children: <Widget>[
              const Expanded(
                child: Text(
                  'Linked bikers',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                ),
              ),
              OutlinedButton.icon(
                onPressed: _linkedBikersLoading || businessId.isEmpty
                    ? null
                    : () => _loadLinkedBikers(businessId),
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Refresh'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_linkedBikersLoading && _linkedBikers.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_linkedBikersError != null)
            Text(
              _linkedBikersError!,
              style: const TextStyle(color: AdminThemeTokens.slate, fontSize: 13),
            )
          else if (_linkedBikers.isEmpty)
            const Text(
              'No linked bikers yet.',
              style: TextStyle(color: AdminThemeTokens.slate),
            )
          else
            ..._linkedBikers.map((item) {
              final driverId = _text(item['driver_id']);
              final name = _text(item['driver_name']);
              final status = _text(item['business_link_status']);
              final vehicle = _text(item['dispatch_vehicle_type']);
              final ownership = _text(item['ownership_mode']);
              final online = item['online'] == true;
              final withdrawalBlocked = ownership.toLowerCase() == 'business_managed' ||
                  (status.isNotEmpty && status.toLowerCase() != 'approved');
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    border: Border.all(color: AdminThemeTokens.border),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        name.isNotEmpty ? name : driverId,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      if (name.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 2),
                        Text(
                          driverId,
                          style: const TextStyle(
                            fontSize: 12,
                            color: AdminThemeTokens.slate,
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: <Widget>[
                          _statusChip(status.isEmpty ? 'approved' : status),
                          if (vehicle.isNotEmpty)
                            Chip(
                              label: Text(vehicle),
                              visualDensity: VisualDensity.compact,
                            ),
                          if (ownership.isNotEmpty)
                            Chip(
                              label: Text(ownership),
                              visualDensity: VisualDensity.compact,
                            ),
                          Chip(
                            label: Text(online ? 'Online' : 'Offline'),
                            visualDensity: VisualDensity.compact,
                          ),
                          if (withdrawalBlocked)
                            Chip(
                              label: const Text('Withdrawals blocked'),
                              visualDensity: VisualDensity.compact,
                              backgroundColor: Colors.orange.shade50,
                            ),
                          Chip(
                            label: Text('Linked ${_formatLinkedAt(item['linked_at'])}'),
                            visualDensity: VisualDensity.compact,
                          ),
                        ],
                      ),
                      if (_text(item['phone']).isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text('Phone: ${_text(item['phone'])}'),
                        ),
                      if (withdrawalBlocked)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            'Withdrawal restriction active '
                            '(ownership: ${ownership.isEmpty ? 'business_managed' : ownership}).',
                            style: const TextStyle(
                              fontSize: 12,
                              color: AdminThemeTokens.slate,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              );
            }),
          if (_linkedBikersHasMore) ...<Widget>[
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _linkedBikersLoading || businessId.isEmpty
                  ? null
                  : () => _loadLinkedBikers(businessId, append: true),
              child: _linkedBikersLoading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Load more bikers'),
            ),
          ],
          const SizedBox(height: 20),
          if (canReviewFleet)
            AdminPermissionGate(
              session: widget.session,
              permission: 'merchants.write',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const Text(
                    'Fleet decision',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: FilledButton(
                          onPressed: !docsComplete || businessId.isEmpty
                              ? null
                              : () => _review(businessId, 'approve'),
                          child: const Text('Approve fleet'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: businessId.isEmpty
                              ? null
                              : () => _review(businessId, 'reject'),
                          child: const Text('Reject fleet'),
                        ),
                      ),
                    ],
                  ),
                  if (!docsComplete) ...<Widget>[
                    const SizedBox(height: 10),
                    const Text(
                      'Approve fleet stays disabled until every required document is approved.',
                      style: TextStyle(fontSize: 12, color: AdminThemeTokens.slate),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: businessId.isEmpty
                          ? null
                          : () => _review(
                                businessId,
                                'approve',
                                approvalOverride: true,
                              ),
                      icon: const Icon(Icons.gpp_maybe_outlined, size: 18),
                      label: const Text('Manual override approve'),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _detailLine(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: AdminThemeTokens.slate,
              ),
            ),
          ),
          Expanded(child: Text(value.isEmpty ? '—' : value)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _rows.isEmpty) {
      return const AdminEmptyState(
        title: 'Loading Dispatch Fleet',
        message: 'Fetching fleet operator applications…',
        icon: Icons.local_shipping_outlined,
      );
    }

    if (_error != null && _rows.isEmpty) {
      return AdminEmptyState(
        title: 'Could not load Dispatch Fleet',
        message: _error!,
        icon: Icons.error_outline_rounded,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const AdminSectionHeader(
          title: 'Dispatch Fleet',
          description:
              'Review Fleet Business operator applications. '
              'This is separate from restaurant, pharmacy, and grocery merchant commerce.',
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            DropdownButton<String>(
              value: _filters.contains(_filter) ? _filter : 'pending_review',
              items: const <DropdownMenuItem<String>>[
                DropdownMenuItem(value: 'all', child: Text('All')),
                DropdownMenuItem(
                  value: 'pending_documents',
                  child: Text('Pending documents'),
                ),
                DropdownMenuItem(
                  value: 'pending_review',
                  child: Text('Pending review'),
                ),
                DropdownMenuItem(value: 'approved', child: Text('Approved')),
                DropdownMenuItem(value: 'rejected', child: Text('Rejected')),
                DropdownMenuItem(value: 'suspended', child: Text('Suspended')),
              ],
              onChanged: (v) {
                if (v == null) {
                  return;
                }
                setState(() => _filter = v);
                _load();
              },
            ),
            OutlinedButton.icon(
              onPressed: _loading ? null : () => _load(),
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Refresh'),
            ),
            if (_hasMore)
              OutlinedButton(
                onPressed: _loading ? null : () => _load(append: true),
                child: const Text('Load more'),
              ),
          ],
        ),
        const SizedBox(height: 20),
        LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 900;
            if (wide) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    flex: 3,
                    child: Column(
                      children: <Widget>[
                        if (_rows.isEmpty)
                          const Text('No fleet accounts for this filter.')
                        else
                          ..._rows.map(_buildRow),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(flex: 2, child: _buildDetailPanel()),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (_rows.isEmpty)
                  const Text('No fleet accounts for this filter.')
                else
                  ..._rows.map(_buildRow),
                const SizedBox(height: 20),
                _buildDetailPanel(),
              ],
            );
          },
        ),
      ],
    );
  }
}

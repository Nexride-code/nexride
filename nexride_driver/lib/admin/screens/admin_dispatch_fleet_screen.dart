import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

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
        throw StateError(data['reason']?.toString() ?? 'list_failed');
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

  Future<void> _review(String businessId, String action) async {
    final noteController = TextEditingController();
    final requireNote = action == 'reject';

    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(action == 'approve' ? 'Approve fleet' : 'Reject fleet'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (requireNote)
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
                labelText: requireNote ? 'Rejection reason' : 'Note (optional)',
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
            child: Text(action == 'approve' ? 'Approve' : 'Reject'),
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
          });

      final data = _asMap(result.data);
      if (data['success'] != true) {
        final reason = data['reason']?.toString() ?? 'review_failed';
        if (reason == 'fleet_documents_incomplete') {
          throw StateError(
            'Cannot approve: required fleet documents are not all approved.',
          );
        }
        throw StateError(reason);
      }

      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            action == 'approve' ? 'Fleet approved' : 'Fleet rejected',
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
    final canReview = status == 'pending_review' || status == 'pending';
    final docsComplete = account['required_documents_complete'] == true;
    final verificationType = _text(account['verification_type']);
    final readiness = account['readiness'];
    final documents = account['verification_documents'];

    return AdminSurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
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
          const SizedBox(height: 16),
          _detailLine('Business ID', businessId),
          _detailLine('Owner', _text(account['owner_name'])),
          _detailLine('Email', _text(account['contact_email'])),
          _detailLine('Phone', _text(account['phone'])),
          _detailLine('Address', _text(account['address'])),
          _detailLine('Region', _text(account['region_id'])),
          _detailLine('City', _text(account['city_id'])),
          _detailLine('Verification', _text(account['verification_status'])),
          _detailLine(
            'Verification type',
            verificationType.isEmpty ? 'cac_business' : verificationType,
          ),
          _detailLine(
            'Documents complete',
            docsComplete ? 'Yes' : 'No',
          ),
          if (readiness is Map && readiness['readable_message'] != null)
            _detailLine(
              'Readiness',
              readiness['readable_message']?.toString() ?? '',
            ),
          if (_text(account['rejection_reason']).isNotEmpty)
            _detailLine('Rejection reason', _text(account['rejection_reason'])),
          const SizedBox(height: 16),
          const Text(
            'Verification documents',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
          ),
          const SizedBox(height: 8),
          if (documents is List && documents.isNotEmpty)
            ...documents.whereType<Map>().map((raw) {
              final doc = raw.map((k, v) => MapEntry(k.toString(), v));
              final docType = _text(doc['document_type']);
              final docStatus = _text(doc['status']);
              final label = _text(doc['label']).isEmpty ? docType : _text(doc['label']);
              final url = _text(doc['download_url']);
              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
                      Text('Status: $docStatus'),
                      if (url.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: SelectableText(url, style: const TextStyle(fontSize: 11)),
                        ),
                      if (docStatus == 'pending' && docType.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Wrap(
                            spacing: 8,
                            children: <Widget>[
                              OutlinedButton(
                                onPressed: businessId.isEmpty
                                    ? null
                                    : () => _reviewDocument(
                                          businessId,
                                          docType,
                                          'approve',
                                        ),
                                child: const Text('Approve doc'),
                              ),
                              OutlinedButton(
                                onPressed: businessId.isEmpty
                                    ? null
                                    : () => _reviewDocument(
                                          businessId,
                                          docType,
                                          'reject',
                                        ),
                                child: const Text('Reject doc'),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              );
            })
          else
            const Text(
              'No documents uploaded yet.',
              style: TextStyle(color: AdminThemeTokens.slate),
            ),
          const SizedBox(height: 20),
          if (canReview)
            AdminPermissionGate(
              session: widget.session,
              permission: 'merchants.write',
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: FilledButton(
                      onPressed: businessId.isEmpty
                          ? null
                          : () => _review(businessId, 'approve'),
                      child: const Text('Approve'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: businessId.isEmpty
                          ? null
                          : () => _review(businessId, 'reject'),
                      child: const Text('Reject'),
                    ),
                  ),
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

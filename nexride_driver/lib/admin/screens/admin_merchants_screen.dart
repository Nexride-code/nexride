import 'dart:async' show unawaited;

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../admin_config.dart';
import '../models/admin_models.dart';
import '../utils/admin_formatters.dart';
import '../widgets/admin_components.dart';
import '../widgets/admin_permission_gate.dart';

/// Merchant registration review — mirrors admin web `/admin/merchants`.
class AdminMerchantsScreen extends StatefulWidget {
  const AdminMerchantsScreen({super.key, required this.session});

  final AdminSession session;

  @override
  State<AdminMerchantsScreen> createState() => _AdminMerchantsScreenState();
}

class _AdminMerchantsScreenState extends State<AdminMerchantsScreen> {
  bool _loading = true;
  String? _error;

  // Server fetch (all merchants), then client-side filters.
  List<Map<String, dynamic>> _allMerchants = const <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _rows = const <Map<String, dynamic>>[];

  /// [DropdownButton] requires [value] to match an item exactly (web release
  /// can otherwise fail layout / render a blank subtree).
  static const Set<String> _allowedFilters = <String>{
    'all',
    'pending',
    'approved',
    'rejected',
    'suspended',
    'subscription',
    'commission',
  };

  String _filter = 'pending';

  String _normalizeFilter(String raw) =>
      _allowedFilters.contains(raw) ? raw : 'pending';
  String? _detailForId;
  Map<String, dynamic>? _detailMerchant;

  /// Scroll target: filter row + merchant list (after jumping from summary cards).
  final GlobalKey _merchantListAnchorKey = GlobalKey();

  FirebaseFunctions get _fn =>
      FirebaseFunctions.instanceFor(region: 'us-central1');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final payload = <String, dynamic>{'limit': 100};
      if (_filter == 'subscription' || _filter == 'commission') {
        payload['payment_model'] = _filter;
      } else if (_filter != 'all') {
        payload['status'] = _filter;
      }
      final callable = _fn.httpsCallable(
        'adminListMerchantsPage',
        options: HttpsCallableOptions(timeout: const Duration(seconds: 60)),
      );
      final result = await callable.call(payload);

      final data = _asMap(result.data);
      if (data['success'] != true) {
        throw StateError(data['reason']?.toString() ?? 'list_failed');
      }

      final raw = data['merchants'];
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
        _filter = _normalizeFilter(_filter);
        _allMerchants = list;
        _rows = list;
        _loading = false;
        _detailForId = null;
        _detailMerchant = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _openDetail(String merchantId) async {
    setState(() {
      _detailForId = merchantId;
      _detailMerchant = null;
    });
    try {
      final callable = _fn.httpsCallable(
        'adminGetMerchantProfile',
        options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
      );
      final result = await callable.call(<String, dynamic>{
        'merchant_id': merchantId,
        'include_order_metrics': true,
        'include_internal_notes': true,
        'include_portal_snapshot': true,
      });
      final data = _asMap(result.data);
      if (data['success'] != true) {
        throw StateError(data['reason']?.toString() ?? 'get_failed');
      }

      final m = data['merchant'];
      if (m is Map) {
        if (!mounted) return;
        setState(() {
          _detailMerchant = m.map((k, v) => MapEntry(k.toString(), v));
        });
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Load merchant failed: $e')),
      );
    }
  }

  Future<void> _maybeWarnReadinessThenReview(
    String merchantId,
    String action,
    Map<String, dynamic> merchant,
  ) async {
    final needsForce =
        (action == 'approve' || action == 'reactivate') && !_readinessAllowed(merchant);
    if (needsForce) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (BuildContext ctx) => AlertDialog(
          title: const Text('Approve anyway?'),
          content: const Text(
            'Verification readiness is not passing (documents or subscription workflow may still be incomplete). '
            'If you confirm, this merchant is approved with a manual override and notified on their profile '
            '(push; email when configured).',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Confirm'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    await _review(merchantId, action, forceManualApprove: needsForce);
  }

  Future<void> _review(
    String merchantId,
    String action, {
    bool forceManualApprove = false,
  }) async {
    final noteController = TextEditingController();
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Confirm ${action.toUpperCase()}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Merchant: $merchantId'),
            const SizedBox(height: 12),
            TextField(
              controller: noteController,
              decoration: const InputDecoration(
                labelText: 'Note (optional)',
                border: OutlineInputBorder(),
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
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Submit'),
          ),
        ],
      ),
    );

    if (proceed != true || !mounted) return;

    try {
      final callable = _fn.httpsCallable(
        'adminReviewMerchant',
        options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
      );
      final result = await callable.call(<String, dynamic>{
        'merchant_id': merchantId,
        'action': action,
        'note': noteController.text.trim(),
        if (forceManualApprove) 'force_manual_approve': true,
      });
      final data = _asMap(result.data);
      if (data['success'] != true) {
        final reason = data['reason']?.toString() ?? 'review_failed';
        if (reason == 'readiness_blocked') {
          final msg = data['readable_message']?.toString() ??
              data['readableMessage']?.toString() ??
              reason;
          throw StateError(msg);
        }
        throw StateError(reason);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Updated to ${data['status'] ?? action}')),
        );
      }
      await _load();
      if (_detailForId == merchantId) {
        await _openDetail(merchantId);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Review failed: $e')),
      );
    }
  }

  Future<void> _setPaymentModel(String merchantId, String paymentModel) async {
    try {
      final callable = _fn.httpsCallable(
        'adminUpdateMerchantPaymentModel',
        options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
      );
      final result = await callable.call(<String, dynamic>{
        'merchant_id': merchantId,
        'payment_model': paymentModel,
      });
      final data = _asMap(result.data);
      if (data['success'] != true) {
        throw StateError(data['reason']?.toString() ?? 'payment_model_update_failed');
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Payment model updated to $paymentModel')),
        );
      }
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Update failed: $e')),
      );
    }
  }

  Future<void> _setSubscriptionStatus(String merchantId, String subscriptionStatus) async {
    try {
      final callable = _fn.httpsCallable(
        'adminUpdateMerchantSubscriptionStatus',
        options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
      );
      final result = await callable.call(<String, dynamic>{
        'merchant_id': merchantId,
        'subscription_status': subscriptionStatus,
      });
      final data = _asMap(result.data);
      if (data['success'] != true) {
        throw StateError(
          data['reason']?.toString() ?? 'subscription_status_update_failed',
        );
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Subscription status: $subscriptionStatus')),
        );
      }
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Update failed: $e')),
      );
    }
  }

  Future<void> _recompute(String merchantId) async {
    try {
      final callable = _fn.httpsCallable(
        'recomputeMerchantFinancialModel',
        options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
      );
      final result = await callable.call(<String, dynamic>{
        'merchant_id': merchantId,
      });
      final data = _asMap(result.data);
      if (data['success'] != true) {
        throw StateError(data['reason']?.toString() ?? 'recompute_failed');
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Recomputed financial model')),
        );
      }
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Recompute failed: $e')),
      );
    }
  }

  Future<void> _recomputeReadiness(String merchantId) async {
    try {
      final callable = _fn.httpsCallable(
        'adminRecomputeMerchantReadiness',
        options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
      );
      final result = await callable.call(<String, dynamic>{
        'merchant_id': merchantId,
      });
      final data = _asMap(result.data);
      if (data['success'] != true) {
        throw StateError(data['reason']?.toString() ?? 'recompute_failed');
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Readiness recomputed')),
        );
      }
      await _load();
      if (_detailForId == merchantId) {
        await _openDetail(merchantId);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Readiness recompute failed: $e')),
      );
    }
  }

  Future<void> _reviewMerchantDocument(
    String merchantId,
    String documentType,
    String action, {
    String note = '',
    String rejectionReason = '',
  }) async {
    try {
      final callable = _fn.httpsCallable(
        'adminReviewMerchantDocument',
        options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
      );
      final result = await callable.call(<String, dynamic>{
        'merchant_id': merchantId,
        'document_type': documentType,
        'action': action,
        'admin_note': note,
        'rejection_reason': rejectionReason,
      });
      final data = _asMap(result.data);
      if (data['success'] != true) {
        throw StateError(data['reason']?.toString() ?? 'doc_review_failed');
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Document $documentType → ${data['status']}')),
        );
      }
      await _load();
      if (_detailForId == merchantId) {
        await _openDetail(merchantId);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Document review failed: $e')),
      );
    }
  }

  Future<void> _promptDocNoteAndReview(
    String merchantId,
    String documentType,
    String action,
  ) async {
    final noteController = TextEditingController();
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          action == 'reject'
              ? 'Reject document'
              : 'Request resubmission',
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('$documentType · $merchantId'),
            const SizedBox(height: 12),
            TextField(
              controller: noteController,
              decoration: const InputDecoration(
                labelText: 'Note to merchant (required)',
                border: OutlineInputBorder(),
              ),
              maxLines: 4,
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Submit'),
          ),
        ],
      ),
    );
    if (proceed != true || !mounted) return;
    final text = noteController.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Note is required')),
      );
      return;
    }
    await _reviewMerchantDocument(
      merchantId,
      documentType,
      action,
      note: text,
      rejectionReason: text,
    );
  }

  Future<void> _openSignedUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open link')),
      );
    }
  }

  String _formatMs(dynamic v) {
    final n = v is num ? v.round() : int.tryParse(_text(v));
    if (n == null || n <= 0) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch(n);
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} '
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  static const Map<String, String> _adminDocTitles = <String, String>{
    'cac_document': 'Business registration / CAC',
    'owner_id': 'Owner government ID',
    'storefront_photo': 'Storefront or business photo',
    'address_proof': 'Address proof / utility bill',
    'operating_license': 'Food safety or pharmacy license',
  };

  bool _readinessAllowed(Map<String, dynamic> merchant) {
    final r = merchant['readiness'];
    if (r is! Map) return false;
    return _asMap(r)['allowed'] == true;
  }

  Widget _adminPill(String text, Color bg, Color fg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(100),
        border: Border.all(color: fg.withValues(alpha: 0.2)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: fg,
          fontWeight: FontWeight.w700,
          fontSize: 11,
        ),
      ),
    );
  }

  Widget _adminDocStatusPill(String stRaw) {
    final st = stRaw.toLowerCase();
    switch (st) {
      case 'approved':
        return _adminPill(
          'Approved',
          AdminThemeTokens.portalSecurityTheme.successBackground,
          AdminThemeTokens.success,
        );
      case 'rejected':
        return _adminPill(
          'Rejected',
          AdminThemeTokens.portalSecurityTheme.dangerBackground,
          AdminThemeTokens.danger,
        );
      case 'pending':
        return _adminPill(
          'Pending review',
          AdminThemeTokens.portalSecurityTheme.warningBackground,
          AdminThemeTokens.warning,
        );
      case 'resubmission_required':
        return _adminPill(
          'Resubmission required',
          AdminThemeTokens.portalSecurityTheme.warningBackground,
          AdminThemeTokens.warning,
        );
      default:
        return _adminPill(
          stRaw.isEmpty ? 'Unknown' : stRaw,
          const Color(0xFFEDEAE4),
          AdminThemeTokens.slate,
        );
    }
  }

  IconData _adminDocIcon(String type) {
    switch (type) {
      case 'owner_id':
        return Icons.badge_outlined;
      case 'storefront_photo':
        return Icons.storefront_outlined;
      case 'operating_license':
        return Icons.health_and_safety_outlined;
      case 'cac_document':
        return Icons.article_outlined;
      case 'address_proof':
        return Icons.home_work_outlined;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }

  Widget _buildVerificationReadinessCard(
    BuildContext context,
    Map<String, dynamic> merchant,
  ) {
    final r = merchant['readiness'];
    if (r is! Map) {
      return AdminSurfaceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Verification readiness',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: AdminThemeTokens.ink,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              'No readiness payload yet. Use “Recompute readiness”, then refresh details.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AdminThemeTokens.slate,
                    height: 1.35,
                  ),
            ),
          ],
        ),
      );
    }
    final rm = _asMap(r);
    final allowed = rm['allowed'] == true;
    final msg = _text(rm['readableMessage'] ?? rm['readable_message']);
    final missing = rm['missingRequirements'] ?? rm['missing_requirements'];
    final dsRaw = rm['documentStatuses'] ?? rm['document_statuses'];
    final ds = dsRaw is Map ? _asMap(dsRaw) : <String, dynamic>{};

    return AdminSurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                allowed ? Icons.verified_outlined : Icons.rule_folder_outlined,
                color: allowed ? AdminThemeTokens.success : AdminThemeTokens.gold,
                size: 28,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Verification readiness',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: AdminThemeTokens.ink,
                          ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[
                        _adminPill(
                          allowed ? 'Ready to approve' : 'Not ready',
                          allowed
                              ? AdminThemeTokens.portalSecurityTheme
                                  .successBackground
                              : AdminThemeTokens.goldSoft,
                          allowed
                              ? AdminThemeTokens.success
                              : AdminThemeTokens.gold,
                        ),
                      ],
                    ),
                    if (msg.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 10),
                      Text(
                        msg,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: const Color(0xFF3D3A35),
                              height: 1.4,
                            ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (missing is List && missing.isNotEmpty) ...<Widget>[
            const SizedBox(height: 14),
            Text(
              'Missing requirements',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: AdminThemeTokens.ink,
                  ),
            ),
            const SizedBox(height: 6),
            for (final x in missing)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '• ',
                      style: TextStyle(
                        color: AdminThemeTokens.danger,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        x.toString(),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              height: 1.35,
                              color: const Color(0xFF3D3A35),
                            ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
          if (ds.isNotEmpty) ...<Widget>[
            const SizedBox(height: 14),
            Text(
              'Document status (server)',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: AdminThemeTokens.ink,
                  ),
            ),
            const SizedBox(height: 6),
            for (final MapEntry<String, dynamic> e in ds.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '${e.key}: ${e.value}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AdminThemeTokens.slate,
                      ),
                ),
              ),
          ],
          if (!allowed) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              'Readiness is advisory: you can still approve from “Payouts & subscriptions” below '
              'if you accept the risk; you will be asked to confirm when readiness is not passing.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AdminThemeTokens.slate,
                    fontStyle: FontStyle.italic,
                    height: 1.35,
                  ),
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _buildVerificationDocumentsBlock(
    BuildContext context,
    String merchantId,
    Map<String, dynamic> merchant,
  ) {
    final raw = merchant['verification_documents'];
    if (raw is! List) {
      return <Widget>[
        const SizedBox(height: 12),
        Text(
          'No verification_documents in payload.',
          style: TextStyle(color: AdminThemeTokens.slate, fontSize: 13),
        ),
      ];
    }

    final out = <Widget>[
      const SizedBox(height: 16),
      Text(
        'Document checklist',
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
              color: AdminThemeTokens.ink,
            ),
      ),
      const SizedBox(height: 4),
      Text(
        'Review each file, then approve or request changes. Merchants see your rejection reason in their portal.',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: AdminThemeTokens.slate,
              height: 1.35,
            ),
      ),
      const SizedBox(height: 12),
    ];

    for (final item in raw) {
      if (item is! Map) continue;
      final row = item.map((k, v) => MapEntry(k.toString(), v));
      final type = _text(row['document_type']);
      final st = _text(row['status']);
      final stLower = st.toLowerCase();
      final uploaded = _formatMs(row['uploaded_at']);
      final reviewed = _formatMs(row['reviewed_at']);
      final path = _text(row['storage_path']);
      final note = _text(row['admin_note']);
      final rej = _text(row['rejection_reason']);
      final url = _text(row['download_url']);
      final title = _adminDocTitles[type] ?? type;

      out.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: AdminSurfaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(
                      _adminDocIcon(type),
                      color: AdminThemeTokens.gold,
                      size: 28,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            title,
                            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w800,
                                  color: AdminThemeTokens.ink,
                                ),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: <Widget>[
                              _adminDocStatusPill(st),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  'Uploaded: $uploaded · Reviewed: $reviewed',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AdminThemeTokens.slate,
                      ),
                ),
                if (path.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 6),
                  SelectableText(
                    'Storage: $path',
                    style: const TextStyle(fontSize: 12, color: Color(0xFF3D3A35)),
                  ),
                ],
                if (note.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(
                    'Admin note: $note',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: const Color(0xFF3D3A35),
                          height: 1.35,
                        ),
                  ),
                ],
                if (rej.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 6),
                  Text(
                    'Rejection / resubmission reason: $rej',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AdminThemeTokens.danger,
                          height: 1.35,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ],
                if (url.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 10),
                  TextButton(
                    onPressed: () => _openSignedUrl(url),
                    child: const Text('Open file (signed URL)'),
                  ),
                ],
                if (stLower == 'pending') ...<Widget>[
                  const SizedBox(height: 12),
                  const Divider(height: 1),
                  const SizedBox(height: 12),
                  Text(
                    'Review actions',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: AdminThemeTokens.slate,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 8),
                  AdminPermissionGate(
                    session: widget.session,
                    permission: 'merchants.write',
                    child: Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: <Widget>[
                      FilledButton(
                        onPressed: () => _reviewMerchantDocument(
                          merchantId,
                          type,
                          'approve',
                        ),
                        child: const Text('Approve document'),
                      ),
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AdminThemeTokens.danger,
                          side: BorderSide(
                            color: AdminThemeTokens.portalSecurityTheme.dangerBorder,
                          ),
                        ),
                        onPressed: () =>
                            _promptDocNoteAndReview(merchantId, type, 'reject'),
                        child: const Text('Reject document'),
                      ),
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AdminThemeTokens.warning,
                          side: BorderSide(
                            color: AdminThemeTokens.portalSecurityTheme.warningBorder,
                          ),
                        ),
                        onPressed: () => _promptDocNoteAndReview(
                          merchantId,
                          type,
                          'require_resubmit',
                        ),
                        child: const Text('Require resubmission'),
                      ),
                    ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    return out;
  }

  List<Widget> _buildOrderMetricsAndNotes(
    BuildContext context,
    Map<String, dynamic> merchant,
  ) {
    final om = merchant['order_metrics'];
    final widgets = <Widget>[
      const Text(
        'Order metrics',
        style: TextStyle(fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 6),
    ];
    if (om is Map) {
      final delayed = om['delayed_ready_for_pickup'];
      final counts = om['counts_by_status'];
      if (counts is Map) {
        for (final e in counts.entries) {
          widgets.add(Text('${e.key}: ${e.value}'));
        }
      } else {
        widgets.add(const Text('No order samples loaded.'));
      }
      if (delayed != null) {
        widgets.add(Text('Delayed ready_for_pickup (>30m): $delayed'));
      }
    } else {
      widgets.add(const Text('Expand details with metrics to see counts.'));
    }
    widgets.add(const SizedBox(height: 12));
    widgets.add(
      const Text(
        'Internal notes (recent)',
        style: TextStyle(fontWeight: FontWeight.w800),
      ),
    );
    widgets.add(const SizedBox(height: 6));
    final notes = merchant['internal_notes'];
    if (notes is List && notes.isNotEmpty) {
      for (final n in notes.take(8)) {
        if (n is Map) {
          widgets.add(
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                '${formatAdminDateTimeFromMillis(n['created_at'])} · '
                '${n['admin_uid'] ?? ''}\n${n['text']}',
                style: const TextStyle(height: 1.35),
              ),
            ),
          );
        }
      }
    } else {
      widgets.add(const Text('No internal notes yet.'));
    }
    return widgets;
  }

  String formatAdminDateTimeFromMillis(dynamic ms) {
    final v = ms is int ? ms : int.tryParse(ms?.toString() ?? '') ?? 0;
    if (v <= 0) {
      return '—';
    }
    return formatAdminDateTime(DateTime.fromMillisecondsSinceEpoch(v));
  }

  Future<void> _flagMerchantOwnerForSupport(
    String merchantId,
    Map<String, dynamic> merchant,
  ) async {
    final String uid = _text(merchant['owner_uid']);
    if (uid.length < 4) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Cannot flag: merchant owner UID is missing. Use backend tools or refresh merchant profile.',
          ),
        ),
      );
      return;
    }
    final TextEditingController noteController = TextEditingController();
    String priority = 'normal';
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) {
        return StatefulBuilder(
          builder:
              (BuildContext ctx, void Function(void Function()) setLocal) {
            return AlertDialog(
              title: const Text('Flag merchant owner for support'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('Merchant: $merchantId · Owner: $uid'),
                    const SizedBox(height: 12),
                    const Text(
                      'Queues an internal support flag and notifies the account owner. Note min 4 characters.',
                      style: TextStyle(fontSize: 13, height: 1.35),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      key: ValueKey<String>(priority),
                      initialValue: priority,
                      decoration: const InputDecoration(
                        labelText: 'Priority',
                        border: OutlineInputBorder(),
                      ),
                      items: const <DropdownMenuItem<String>>[
                        DropdownMenuItem<String>(
                          value: 'normal',
                          child: Text('Normal'),
                        ),
                        DropdownMenuItem<String>(
                          value: 'high',
                          child: Text('High'),
                        ),
                        DropdownMenuItem<String>(
                          value: 'urgent',
                          child: Text('Urgent'),
                        ),
                      ],
                      onChanged: (String? v) {
                        setLocal(() {
                          priority = v ?? 'normal';
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: noteController,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        labelText: 'Instruction for support',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () {
                    if (noteController.text.trim().length < 4) {
                      return;
                    }
                    Navigator.pop(ctx, true);
                  },
                  child: const Text('Submit'),
                ),
              ],
            );
          },
        );
      },
    );
    if (ok != true || !mounted) {
      noteController.dispose();
      return;
    }
    final String note = noteController.text.trim();
    noteController.dispose();
    try {
      final callable = _fn.httpsCallable(
        'adminFlagUserForSupportContact',
        options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
      );
      final result = await callable.call(<String, dynamic>{
        'uid': uid,
        'role': 'merchant',
        'note': note,
        'priority': priority,
      });
      final data = _asMap(result.data);
      if (data['success'] != true) {
        throw StateError(data['reason']?.toString() ?? 'flag_failed');
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Support flag saved. Merchant owner notified (push).'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e')),
        );
      }
    }
  }

  Future<void> _warnMerchant(String merchantId) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Warn merchant'),
        content: TextField(
          controller: ctrl,
          maxLines: 4,
          decoration: const InputDecoration(
            labelText: 'Message (min 4 chars)',
            border: OutlineInputBorder(),
          ),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Send')),
        ],
      ),
    );
    if (ok != true || !mounted) {
      ctrl.dispose();
      return;
    }
    try {
      final callable = _fn.httpsCallable(
        'adminWarnMerchant',
        options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
      );
      final result = await callable.call(<String, dynamic>{
        'merchant_id': merchantId,
        'message': ctrl.text.trim(),
      });
      ctrl.dispose();
      final data = _asMap(result.data);
      if (data['success'] != true) {
        throw StateError(data['reason']?.toString() ?? 'warn_failed');
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Warning saved')));
      }
      await _load();
      if (_detailForId == merchantId) {
        await _openDetail(merchantId);
      }
    } catch (e) {
      ctrl.dispose();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _promptCommissionOverride(String merchantId) async {
    final crCtrl = TextEditingController(text: '10');
    final wrCtrl = TextEditingController(text: '90');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Commission override'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text('Enter commission % (0–50) and merchant withdrawal % (0–100).'),
            TextField(
              controller: crCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Commission %'),
            ),
            TextField(
              controller: wrCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Withdrawal %'),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Apply')),
        ],
      ),
    );
    if (ok != true || !mounted) {
      crCtrl.dispose();
      wrCtrl.dispose();
      return;
    }
    final crPct = double.tryParse(crCtrl.text.trim()) ?? -1;
    final wrPct = double.tryParse(wrCtrl.text.trim()) ?? -1;
    crCtrl.dispose();
    wrCtrl.dispose();
    if (crPct < 0 || crPct > 50 || wrPct < 0 || wrPct > 100) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invalid percentages.')),
        );
      }
      return;
    }
    try {
      final callable = _fn.httpsCallable(
        'adminSetMerchantCommissionWithdrawal',
        options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
      );
      final result = await callable.call(<String, dynamic>{
        'merchant_id': merchantId,
        'commission_rate': crPct / 100,
        'withdrawal_percent': wrPct / 100,
      });
      final data = _asMap(result.data);
      if (data['success'] != true) {
        throw StateError(data['reason']?.toString() ?? 'update_failed');
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Commission updated')));
      }
      await _load();
      if (_detailForId == merchantId) {
        await _openDetail(merchantId);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _appendInternalNote(String merchantId) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Internal admin note'),
        content: TextField(
          controller: ctrl,
          maxLines: 5,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true || !mounted) {
      ctrl.dispose();
      return;
    }
    try {
      final callable = _fn.httpsCallable(
        'adminAppendMerchantInternalNote',
        options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
      );
      final result = await callable.call(<String, dynamic>{
        'merchant_id': merchantId,
        'text': ctrl.text.trim(),
      });
      ctrl.dispose();
      final data = _asMap(result.data);
      if (data['success'] != true) {
        throw StateError(data['reason']?.toString() ?? 'note_failed');
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Note saved')));
      }
      await _openDetail(merchantId);
    } catch (e) {
      ctrl.dispose();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _showMerchantOrdersDialog(String merchantId) async {
    try {
      final callable = _fn.httpsCallable(
        'adminListMerchantOrders',
        options: HttpsCallableOptions(timeout: const Duration(seconds: 45)),
      );
      final result = await callable.call(<String, dynamic>{'merchant_id': merchantId});
      final data = _asMap(result.data);
      if (data['success'] != true) {
        throw StateError(data['reason']?.toString() ?? 'list_failed');
      }
      final rows = <Map<String, dynamic>>[];
      if (data['orders'] is List) {
        for (final o in data['orders'] as List<dynamic>) {
          if (o is Map) {
            rows.add(o.map((k, v) => MapEntry(k.toString(), v)));
          }
        }
      }
      var commissionSum = 0.0;
      for (final r in rows) {
        final c = r['commission_ngn'];
        if (c is num) {
          commissionSum += c.toDouble();
        }
      }
      if (!mounted) {
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Orders · $merchantId'),
          content: SizedBox(
            width: 520,
            height: 400,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('Commission revenue (sum): ₦${commissionSum.toStringAsFixed(0)}'),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView.builder(
                    itemCount: rows.length,
                    itemBuilder: (c, i) {
                      final o = rows[i];
                      return ListTile(
                        dense: true,
                        title: Text(o['order_id']?.toString() ?? ''),
                        subtitle: Text(
                          '${o['order_status']} · total ₦${o['total_ngn']} · commission ₦${o['commission_ngn']}',
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map) {
      return value.map((k, v) => MapEntry(k.toString(), v));
    }
    return <String, dynamic>{};
  }

  String _text(dynamic v) => v?.toString().trim() ?? '';

  String _formatPortalLastSeen(dynamic v) {
    final n = v is num ? v.toInt() : int.tryParse(_text(v));
    if (n == null || n <= 0) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch(n, isUtc: false).toLocal();
    return d.toString().split('.').first;
  }

  String _formatStaffUids(dynamic v) {
    if (v is List && v.isNotEmpty) {
      return v.map((e) => e.toString()).join(', ');
    }
    return '—';
  }

  String _formatStaffRoles(dynamic v) {
    if (v is Map && v.isNotEmpty) {
      return v.entries.map((e) => '${e.key}:${e.value}').join(' · ');
    }
    return '—';
  }

  String _formatPublicTeaser(dynamic v) {
    if (v is! Map) return '—';
    final m = Map<String, dynamic>.from(v);
    final ol = m['orders_live'];
    final av = m['availability_status'];
    final up = m['updated_at_ms'];
    return 'orders_live=$ol · availability=$av · updated_ms=$up';
  }

  String _formatPortalPresence(dynamic v) {
    if (v is! Map) return '—';
    final m = v;
    final n = m.length;
    if (n == 0) return 'none';
    return '$n session(s) · ${_text(m.keys.take(4).join(', '))}${n > 4 ? '…' : ''}';
  }

  double _asDouble(dynamic v) {
    if (v == null) return 0;
    double x;
    if (v is num) {
      x = v.toDouble();
    } else {
      x = double.tryParse(_text(v)) ?? 0;
    }
    if (!x.isFinite) {
      return 0;
    }
    return x;
  }

  String _ownerNameFromEmail(dynamic email) {
    final e = _text(email);
    if (!e.contains('@')) return e;
    return e.split('@').first;
  }

  String _formatJoinedMs(dynamic v) {
    final n = v is num ? v.round() : int.tryParse(_text(v));
    if (n == null || n <= 0) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch(n);
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  String _commissionPercentLabel(dynamic rate) {
    final r = _asDouble(rate);
    if (r <= 0 || !r.isFinite) return '0%';
    return '${(r * 100).toStringAsFixed(0)}%';
  }

  void _toggleDetailsRow(String id, bool expanded) {
    if (expanded) {
      setState(() {
        _detailForId = null;
        _detailMerchant = null;
      });
    } else {
      _openDetail(id);
    }
  }

  void _setFilterAndScroll(String rawFilter) {
    final f = _normalizeFilter(rawFilter);
    setState(() {
      _filter = f;
    });
    unawaited(_load());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final ctx = _merchantListAnchorKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 450),
          curve: Curves.easeInOut,
          alignment: 0.05,
        );
      }
    });
  }

  Widget _buildMetricCard({
    required IconData icon,
    required String label,
    required String value,
    required String caption,
    VoidCallback? onTap,
  }) {
    final card = SizedBox(
      width: 230,
      child: Tooltip(
        message: onTap != null
            ? 'Show this group in the list below (scrolls into view).'
            : '',
        child: AdminStatCard(
          metric: AdminMetricCardData(label: label, value: value, caption: caption),
          icon: icon,
        ),
      ),
    );
    if (onTap == null) {
      return card;
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: onTap,
          child: card,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const AdminEmptyState(
        title: 'Loading merchants',
        message: 'Calling adminListMerchantsPage…',
        icon: Icons.storefront_outlined,
      );
    }
    if (_error != null) {
      return AdminEmptyState(
        title: 'Could not load merchants',
        message: _error!,
        icon: Icons.error_outline_rounded,
      );
    }

    final total = _allMerchants.length;
    final pending = _allMerchants.where((m) => _text(m['merchant_status'] ?? m['status']) == 'pending').length;
    final approved = _allMerchants.where((m) => _text(m['merchant_status'] ?? m['status']) == 'approved').length;
    final suspended = _allMerchants.where((m) => _text(m['merchant_status'] ?? m['status']) == 'suspended').length;
    final rejected = _allMerchants.where((m) => _text(m['merchant_status'] ?? m['status']) == 'rejected').length;

    final subscriptionCount = _allMerchants.where((m) => _text(m['payment_model']) == 'subscription').length;
    final commissionCount = _allMerchants.where((m) => _text(m['payment_model']) == 'commission').length;

    final monthlySubscriptionRevenue = _allMerchants.fold<double>(0, (sum, m) {
      final pm = _text(m['payment_model']);
      final subStatus = _text(m['subscription_status']);
      if (pm == 'subscription' && subStatus == 'active') {
        return sum + _asDouble(m['subscription_amount'] ?? 25000);
      }
      return sum;
    });

    // Orders aren't wired in Phase 1 yet, so commission revenue is computed from an optional estimate field if present.
    final estimatedCommissionRevenue = _allMerchants.fold<double>(0, (sum, m) {
      final pm = _text(m['payment_model']);
      if (pm != 'commission') return sum;
      final gross = _asDouble(m['estimated_monthly_order_gross_ngn']);
      if (gross <= 0) return sum;
      final rate = _asDouble(m['commission_rate']);
      return sum + gross * rate;
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const AdminSectionHeader(
          title: 'Merchants',
          description:
              'Merchant operations dashboard (payment model + subscription workflow + admin actions).',
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 14,
          runSpacing: 14,
          children: <Widget>[
            _buildMetricCard(
              icon: Icons.people_alt_outlined,
              label: 'Total merchants',
              value: '$total',
              caption:
                  'Latest page from adminListMerchantsPage (max 50 per filter).',
              onTap: () => _setFilterAndScroll('all'),
            ),
            _buildMetricCard(
              icon: Icons.pending_actions_outlined,
              label: 'Pending approval',
              value: '$pending',
              caption: 'Tap to jump to the review queue below.',
              onTap: () => _setFilterAndScroll('pending'),
            ),
            _buildMetricCard(
              icon: Icons.verified_outlined,
              label: 'Approved merchants',
              value: '$approved',
              caption: 'Approved for operations (commission) or pending subscription activation.',
              onTap: () => _setFilterAndScroll('approved'),
            ),
            _buildMetricCard(
              icon: Icons.remove_circle_outline,
              label: 'Rejected merchants',
              value: '$rejected',
              caption: 'Applications declined.',
              onTap: () => _setFilterAndScroll('rejected'),
            ),
            _buildMetricCard(
              icon: Icons.pause_circle_outline,
              label: 'Suspended merchants',
              value: '$suspended',
              caption: 'Temporarily blocked.',
              onTap: () => _setFilterAndScroll('suspended'),
            ),
          ],
        ),
        if (pending > 0) ...<Widget>[
          const SizedBox(height: 14),
          DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xFFFFF6E8),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFE8D4BC)),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(Icons.info_outline_rounded, color: AdminThemeTokens.gold),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          '$pending merchant application${pending == 1 ? '' : 's'} pending review',
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                            color: AdminThemeTokens.ink,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Scroll to the queue below, or tap Details on a row to open the full profile, '
                          'document checklist (approve each file), and Approve merchant when you are satisfied '
                          '(you can override readiness if needed).',
                          style: TextStyle(
                            color: AdminThemeTokens.slate,
                            height: 1.4,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonal(
                    onPressed: () => _setFilterAndScroll('pending'),
                    child: const Text('Jump to queue'),
                  ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 16),
        KeyedSubtree(
          key: _merchantListAnchorKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Review queue',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: AdminThemeTokens.ink,
                    ),
              ),
              const SizedBox(height: 4),
              Text(
                'Filter which merchants appear, then expand Details to approve documents and the merchant.',
                style: TextStyle(
                  color: AdminThemeTokens.slate,
                  fontSize: 13,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 16,
                runSpacing: 8,
                children: <Widget>[
                  DropdownButton<String>(
                    value: _filter,
                    items: const <DropdownMenuItem<String>>[
                      DropdownMenuItem(value: 'all', child: Text('All')),
                      DropdownMenuItem(value: 'pending', child: Text('Pending')),
                      DropdownMenuItem(
                        value: 'approved',
                        child: Text('Approved'),
                      ),
                      DropdownMenuItem(value: 'rejected', child: Text('Rejected')),
                      DropdownMenuItem(value: 'suspended', child: Text('Suspended')),
                      DropdownMenuItem(
                        value: 'subscription',
                        child: Text('Subscription'),
                      ),
                      DropdownMenuItem(
                        value: 'commission',
                        child: Text('Commission'),
                      ),
                    ],
                    onChanged: (v) {
                      if (v == null) return;
                      _setFilterAndScroll(v);
                    },
                  ),
                  OutlinedButton.icon(
                    onPressed: _load,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('Refresh'),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              if (_rows.isEmpty)
                Text(
                  'No merchants for this filter.',
                  style: TextStyle(color: AdminThemeTokens.slate),
                )
              else
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    for (int i = 0; i < _rows.length; i++) ...<Widget>[
                      if (i > 0) const SizedBox(height: 8),
                      _buildMerchantRowCard(_rows[i]),
                    ],
                  ],
                ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Text(
          'Revenue & model mix',
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
                color: AdminThemeTokens.ink,
              ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 14,
          runSpacing: 14,
          children: <Widget>[
            _buildMetricCard(
              icon: Icons.subscriptions_outlined,
              label: 'Subscription merchants',
              value: '$subscriptionCount',
              caption: 'Merchants on ₦25,000/month plan.',
              onTap: () => _setFilterAndScroll('subscription'),
            ),
            _buildMetricCard(
              icon: Icons.calculate_outlined,
              label: 'Commission merchants',
              value: '$commissionCount',
              caption: '10% commission per completed order.',
              onTap: () => _setFilterAndScroll('commission'),
            ),
            _buildMetricCard(
              icon: Icons.receipt_long_outlined,
              label: 'Monthly subscription revenue',
              value: '₦${monthlySubscriptionRevenue.toStringAsFixed(0)}',
              caption: 'Sum of active subscription plans.',
            ),
            _buildMetricCard(
              icon: Icons.attach_money_outlined,
              label: 'Estimated commission revenue',
              value: '₦${estimatedCommissionRevenue.toStringAsFixed(0)}',
              caption: 'Computed from optional monthly order estimates.',
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildMerchantRowCard(Map<String, dynamic> row) {
    final id = _text(row['merchant_id']);
    final expanded = _detailForId == id;

    final merchantStatus = _text(row['merchant_status'] ?? row['status']);
    final paymentModel = _text(row['payment_model']);
    final subStatus = _text(row['subscription_status']);
    final email = _text(row['contact_email']);
    final phone = _text(row['phone']);
    final regionId = _text(row['region_id']);
    final cityId = _text(row['city_id']);
    final commissionRate = _asDouble(row['commission_rate']);
    final withdrawalPercent = _asDouble(row['withdrawal_percent']);
    final ownerOnFile = _text(row['owner_name']);
    final ownerName = ownerOnFile.isNotEmpty
        ? ownerOnFile
        : _ownerNameFromEmail(email);
    final joined = _formatJoinedMs(row['created_at']);
    final contactLine = <String>[
      if (phone.isNotEmpty) phone,
      if (email.isNotEmpty) email,
    ].join(' · ');
    final locationLine = <String>[
      if (regionId.isNotEmpty) regionId,
      if (cityId.isNotEmpty) cityId,
    ].join(' / ');

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ListTile(
            title: Text(
              _text(row['business_name']).isEmpty
                  ? id
                  : _text(row['business_name']),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('Owner: $ownerName'),
                  Text(
                    contactLine.isEmpty ? 'Contact: —' : 'Contact: $contactLine',
                    style: const TextStyle(fontSize: 13),
                  ),
                  Text(
                    locationLine.isEmpty
                        ? 'State/City: —'
                        : 'State/City: $locationLine',
                    style: const TextStyle(fontSize: 13),
                  ),
                  Text(
                    'Status: $merchantStatus · Model: ${paymentModel.isEmpty ? '—' : paymentModel} · Subscription: ${subStatus.isEmpty ? '—' : subStatus}',
                    style: const TextStyle(fontSize: 13),
                  ),
                  Text(
                    'Commission: ${_commissionPercentLabel(commissionRate)} · '
                    'Withdrawal: ${(withdrawalPercent * 100).toStringAsFixed(0)}% · '
                    'Joined: $joined',
                    style: const TextStyle(fontSize: 13),
                  ),
                ],
              ),
            ),
            trailing: TextButton(
              onPressed: () => _toggleDetailsRow(id, expanded),
              child: Text(
                expanded
                    ? 'Hide'
                    : (merchantStatus.toLowerCase() == 'pending'
                        ? 'Review / approve'
                        : 'Details'),
              ),
            ),
          ),
          if (expanded) ...<Widget>[
            const Divider(height: 1),
            if (_detailMerchant == null)
              const Padding(
                padding: EdgeInsets.all(16),
                child: LinearProgressIndicator(),
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: _buildDetailPanel(
                  context: context,
                  merchantId: id,
                  merchant: _detailMerchant!,
                  ownerName: ownerName,
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildDetailPanel({
    required BuildContext context,
    required String merchantId,
    required Map<String, dynamic> merchant,
    required String ownerName,
  }) {
    final merchantStatus =
        _text(merchant['merchant_status'] ?? merchant['status']);
    final merchantStatusNorm = merchantStatus.toLowerCase();
    final paymentModel = _text(merchant['payment_model']);
    final subStatus = _text(merchant['subscription_status']);

    final commissionRate = _asDouble(merchant['commission_rate']);
    final withdrawalPercent = _asDouble(merchant['withdrawal_percent']);
    final commissionExempt = merchant['commission_exempt'] == true;

    final regionId = _text(merchant['region_id']);
    final cityId = _text(merchant['city_id']);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (paymentModel == 'subscription' &&
            merchantStatusNorm == 'approved' &&
            subStatus != 'active')
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.amber.shade50,
                border: Border.all(color: Colors.amber.shade200),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'Full operations for subscription merchants require subscription_status = active.',
                  style: TextStyle(color: Colors.amber.shade900, fontSize: 13),
                ),
              ),
            ),
          ),
        const Text(
          'Business profile',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        Text('Business: ${_text(merchant['business_name'])}'),
        Text('Owner on file: ${_text(merchant['owner_name'])}'),
        Text('Login / contact: $ownerName (${_text(merchant['owner_uid'])})'),
        Text('Category: ${_text(merchant['category'])}'),
        Text('Address: ${_text(merchant['address'])}'),
        Text('Email: ${_text(merchant['contact_email'])}'),
        Text('Phone: ${_text(merchant['phone'])}'),
        Text('Region/City: ${regionId.isEmpty ? '—' : regionId} / ${cityId.isEmpty ? '—' : cityId}'),
        if (_text(merchant['merchant_warning']).isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'Active warning: ${_text(merchant['merchant_warning'])}',
              style: TextStyle(
                color: AdminThemeTokens.danger,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        if (_text(merchant['admin_note']).isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('Admin note: ${_text(merchant['admin_note'])}'),
          ),

        const SizedBox(height: 14),
        const Text(
          'Live portal & storefront',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        Text(
          'Portal last seen: ${_formatPortalLastSeen(merchant['portal_last_seen_ms'])}',
        ),
        Text(
          'Storefront: open=${merchant['is_open']} · accepting=${merchant['accepting_orders']} · '
          'mode=${_text(merchant['availability_status'])}',
        ),
        Text('Staff UIDs: ${_formatStaffUids(merchant['staff_uids'])}'),
        Text('Staff roles: ${_formatStaffRoles(merchant['staff_roles'])}'),
        Text('Rider teaser (orders_live): ${_formatPublicTeaser(merchant['public_storefront_teaser'])}'),
        Text('Portal sessions (RTDB sample): ${_formatPortalPresence(merchant['portal_presence'])}'),

        const SizedBox(height: 14),
        const Text(
          'Payment model',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        Text('Merchant status: $merchantStatus'),
        Text('Payment model: $paymentModel'),
        Text('Subscription status: ${paymentModel == 'subscription' ? subStatus : 'inactive'}'),
        Text('Commission exempt: ${commissionExempt ? 'Yes' : 'No'}'),
        Text(
          'Commission rate: ${commissionRate == 0 ? '0%' : '${(commissionRate * 100).toStringAsFixed(0)}%'}',
        ),
        Text(
          'Withdrawal percent: ${(withdrawalPercent * 100).toStringAsFixed(0)}%',
        ),
        Text(
          'Verification status: ${_text(merchant['verification_status'])} · '
          'Docs complete: ${merchant['required_documents_complete'] == true ? 'yes' : 'no'}',
        ),

        const SizedBox(height: 14),
        _buildVerificationReadinessCard(context, merchant),
        ..._buildVerificationDocumentsBlock(context, merchantId, merchant),

        const SizedBox(height: 14),
        ..._buildOrderMetricsAndNotes(context, merchant),

        const SizedBox(height: 12),
        AdminPermissionGate(
          session: widget.session,
          permission: 'merchants.write',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: <Widget>[
                  OutlinedButton(
                    onPressed: () => _warnMerchant(merchantId),
                    child: const Text('Warn merchant'),
                  ),
                  OutlinedButton(
                    onPressed: paymentModel == 'commission'
                        ? () => _promptCommissionOverride(merchantId)
                        : null,
                    child: const Text('Override commission'),
                  ),
                  OutlinedButton(
                    onPressed: () => _appendInternalNote(merchantId),
                    child: const Text('Internal note'),
                  ),
                  OutlinedButton(
                    onPressed: () =>
                        unawaited(_flagMerchantOwnerForSupport(merchantId, merchant)),
                    child: const Text('Flag owner for support'),
                  ),
                  OutlinedButton(
                    onPressed: () => _showMerchantOrdersDialog(merchantId),
                    child: const Text('Merchant orders'),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              const Text(
                'Payouts & subscriptions',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              const Text(
                'Per-order commission snapshots live on each merchant order. '
                'Subscription billing (₦25,000/mo) is enforced via payment_model + subscription_status.',
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: <Widget>[
                  if (merchantStatusNorm == 'pending' || merchantStatusNorm == 'rejected')
                    Tooltip(
                      message: _readinessAllowed(merchant)
                          ? 'Approve this merchant.'
                          : 'Readiness is not passing; you will see an “Approve anyway?” confirmation first.',
                      child: FilledButton(
                        onPressed: () =>
                            _maybeWarnReadinessThenReview(merchantId, 'approve', merchant),
                        child: const Text('Approve merchant'),
                      ),
                    ),
                  if (merchantStatusNorm == 'suspended')
                    FilledButton(
                      onPressed: () =>
                          _maybeWarnReadinessThenReview(merchantId, 'reactivate', merchant),
                      child: const Text('Reactivate'),
                    ),
                  if (merchantStatusNorm == 'pending' || merchantStatusNorm == 'approved')
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AdminThemeTokens.danger,
                        side: BorderSide(
                          color: AdminThemeTokens.portalSecurityTheme.dangerBorder,
                        ),
                      ),
                      onPressed: () => _review(merchantId, 'reject'),
                      child: const Text('Reject merchant'),
                    ),
                  if (merchantStatusNorm == 'approved')
                    OutlinedButton(
                      onPressed: () => _review(merchantId, 'suspend'),
                      child: const Text('Suspend'),
                    ),
                  OutlinedButton(
                    onPressed: () => _recompute(merchantId),
                    child: const Text('Recompute model'),
                  ),
                  OutlinedButton(
                    onPressed: () => _recomputeReadiness(merchantId),
                    child: const Text('Recompute readiness'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: <Widget>[
                  FilledButton.tonal(
                    onPressed: () => _setPaymentModel(merchantId, 'subscription'),
                    child: const Text('Set Subscription'),
                  ),
                  FilledButton.tonal(
                    onPressed: () => _setPaymentModel(merchantId, 'commission'),
                    child: const Text('Set Commission'),
                  ),
                ],
              ),
            ],
          ),
        ),

        if (paymentModel == 'subscription') ...<Widget>[
          const SizedBox(height: 12),
          const Text(
            'Subscription workflow',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: <Widget>[
              OutlinedButton(
                onPressed: () => _setSubscriptionStatus(
                  merchantId,
                  'pending_payment',
                ),
                child: const Text('Pending'),
              ),
              OutlinedButton(
                onPressed: () => _setSubscriptionStatus(
                  merchantId,
                  'under_review',
                ),
                child: const Text('Under review'),
              ),
              OutlinedButton(
                onPressed: () => _setSubscriptionStatus(
                  merchantId,
                  'active',
                ),
                child: const Text('Active'),
              ),
              OutlinedButton(
                onPressed: () => _setSubscriptionStatus(
                  merchantId,
                  'rejected',
                ),
                child: const Text('Rejected'),
              ),
              OutlinedButton(
                onPressed: () => _setSubscriptionStatus(
                  merchantId,
                  'expired',
                ),
                child: const Text('Expired'),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

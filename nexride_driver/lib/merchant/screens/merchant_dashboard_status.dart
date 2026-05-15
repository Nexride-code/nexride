import 'package:flutter/material.dart';

import '../../admin/admin_config.dart';

/// Branded merchant verification + lifecycle panel (Phase 2C).
class MerchantDashboardStatusView extends StatelessWidget {
  const MerchantDashboardStatusView({
    super.key,
    required this.merchant,
    required this.documents,
    required this.docsLoading,
    required this.uploadBusy,
    required this.onUploadDocument,
    required this.resubmitBusiness,
    required this.resubmitOwner,
    required this.resubmitPhone,
    required this.resubmitEmail,
    required this.resubmitAddress,
    required this.resubmitPaymentModel,
    required this.onPaymentModelChanged,
    required this.onResubmit,
    required this.resubmitBusy,
    required this.resubmitErr,
  });

  final Map<String, dynamic> merchant;
  final List<Map<String, dynamic>> documents;
  final bool docsLoading;
  final bool uploadBusy;
  final Future<void> Function(String documentType) onUploadDocument;
  final TextEditingController resubmitBusiness;
  final TextEditingController resubmitOwner;
  final TextEditingController resubmitPhone;
  final TextEditingController resubmitEmail;
  final TextEditingController resubmitAddress;
  final String resubmitPaymentModel;
  final ValueChanged<String> onPaymentModelChanged;
  final VoidCallback onResubmit;
  final bool resubmitBusy;
  final String? resubmitErr;

  String _str(dynamic v) => v?.toString().trim() ?? '';

  static const Map<String, String> _docLabels = <String, String>{
    'cac_document': 'Business registration / CAC',
    'owner_id': 'Owner government ID',
    'storefront_photo': 'Storefront or business photo',
    'address_proof': 'Address proof / utility bill',
    'operating_license': 'Food safety or pharmacy license',
  };

  String _blockersText() {
    final raw = merchant['readiness_missing_requirements'];
    if (raw is List && raw.isNotEmpty) {
      return raw.map((e) => e.toString()).join('\n');
    }
    return '';
  }

  bool _categoryNeedsLicense() {
    final c = _str(merchant['category']).toLowerCase();
    return c.contains('restaurant') ||
        c.contains('food') ||
        c.contains('pharmacy');
  }

  bool _docRowRelevant(String type) {
    if (type == 'operating_license') return _categoryNeedsLicense();
    return true;
  }

  bool _docRequired(String type) {
    switch (type) {
      case 'owner_id':
      case 'storefront_photo':
        return true;
      case 'operating_license':
        return _categoryNeedsLicense();
      default:
        return false;
    }
  }

  String _paymentPlanCaption() {
    final pm = _str(merchant['payment_model']).toLowerCase();
    if (pm == 'commission') {
      return 'Commission plan · 10% per completed order · 90% withdrawal';
    }
    return 'Subscription plan · ₦25,000/month · 0% commission · 100% withdrawal';
  }

  Widget _pill(String text, Color bg, Color fg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(100),
        border: Border.all(color: fg.withValues(alpha: 0.18)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: fg,
          fontWeight: FontWeight.w700,
          fontSize: 11,
          letterSpacing: 0.2,
        ),
      ),
    );
  }

  Widget _docStatusPill(String st) {
    final s = st.toLowerCase();
    switch (s) {
      case 'approved':
        return _pill(
          'Approved',
          AdminThemeTokens.portalSecurityTheme.successBackground,
          AdminThemeTokens.success,
        );
      case 'rejected':
        return _pill(
          'Rejected',
          AdminThemeTokens.portalSecurityTheme.dangerBackground,
          AdminThemeTokens.danger,
        );
      case 'pending':
        return _pill(
          'Pending review',
          AdminThemeTokens.portalSecurityTheme.warningBackground,
          AdminThemeTokens.warning,
        );
      case 'resubmission_required':
        return _pill(
          'Resubmission required',
          AdminThemeTokens.portalSecurityTheme.warningBackground,
          AdminThemeTokens.warning,
        );
      default:
        return _pill(
          'Not submitted',
          const Color(0xFFEDEAE4),
          AdminThemeTokens.slate,
        );
    }
  }

  IconData _docIcon(String type) {
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

  Widget _surfaceCard({
    required Widget child,
    Color? borderColor,
  }) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AdminThemeTokens.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: borderColor ?? AdminThemeTokens.border),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: child,
      ),
    );
  }

  Widget _textCard(BuildContext context, String title, String body) {
    return _surfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: AdminThemeTokens.ink,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            body,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  height: 1.45,
                  color: const Color(0xFF3D3A35),
                ),
          ),
        ],
      ),
    );
  }

  Widget _pendingHero(BuildContext context) {
    final v = _str(merchant['verification_status']).toLowerCase();
    final body = (v == 'pending_review' || v == 'docs_complete')
        ? 'Your documents have been submitted. NexRide is reviewing them before we can activate your store.'
        : 'Upload your required documents so NexRide can review and activate your store.';
    return _surfaceCard(
      borderColor: AdminThemeTokens.goldSoft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Application submitted',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: AdminThemeTokens.ink,
                ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              Text(
                'Status:',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: AdminThemeTokens.slate,
                    ),
              ),
              _pill(
                'Pending verification',
                AdminThemeTokens.goldSoft,
                AdminThemeTokens.gold,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            body,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  height: 1.45,
                  color: const Color(0xFF3D3A35),
                ),
          ),
          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 14),
          Text(
            _str(merchant['business_name']).isEmpty
                ? 'Business name pending'
                : _str(merchant['business_name']),
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: AdminThemeTokens.ink,
                ),
          ),
          const SizedBox(height: 6),
          Text(
            _paymentPlanCaption(),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AdminThemeTokens.slate,
                  height: 1.4,
                ),
          ),
        ],
      ),
    );
  }

  Widget _actionBannerIfNeeded(BuildContext context, String merchantStatus) {
    if (merchantStatus == 'approved' || merchantStatus == 'suspended') {
      return const SizedBox.shrink();
    }
    final v = _str(merchant['verification_status']).toLowerCase();
    if (v != 'action_required' && v != 'incomplete') {
      return const SizedBox.shrink();
    }
    final b = _blockersText();
    final body = b.isEmpty
        ? 'Upload or fix the documents listed below.'
        : b;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: _surfaceCard(
        borderColor: AdminThemeTokens.portalSecurityTheme.warningBorder,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(Icons.warning_amber_rounded, color: AdminThemeTokens.warning),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Action required',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: AdminThemeTokens.ink,
                        ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    body,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          height: 1.4,
                          color: const Color(0xFF3D3A35),
                        ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _documentSection(BuildContext context, String merchantStatus) {
    if (merchantStatus == 'approved' || merchantStatus == 'suspended') {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Verification checklist',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: AdminThemeTokens.ink,
              ),
        ),
        const SizedBox(height: 4),
        Text(
          'Accepted formats: JPG, PNG, WebP, or PDF · max 12 MB per file',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AdminThemeTokens.slate,
              ),
        ),
        const SizedBox(height: 14),
        if (docsLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: LinearProgressIndicator(),
          )
        else
          for (final row in documents)
            if (_docRowRelevant(_str(row['document_type'])))
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _docRow(context, row),
              ),
      ],
    );
  }

  Widget _docRow(BuildContext context, Map<String, dynamic> row) {
    final type = _str(row['document_type']);
    final st = _str(row['status']).toLowerCase();
    final label = _docLabels[type] ?? type;
    final uploadedAt = row['uploaded_at'];
    final ts = uploadedAt is num && uploadedAt > 0
        ? DateTime.fromMillisecondsSinceEpoch(uploadedAt.round()).toLocal()
        : null;
    final note = _str(row['rejection_reason']).isNotEmpty
        ? _str(row['rejection_reason'])
        : _str(row['admin_note']);
    final canUpload =
        st == 'not_submitted' || st == 'rejected' || st == 'resubmission_required';
    final req = _docRequired(type);

    return _surfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(_docIcon(type), color: AdminThemeTokens.gold, size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      label,
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
                        _pill(
                          req ? 'Required' : 'Optional',
                          req
                              ? AdminThemeTokens.goldSoft
                              : const Color(0xFFEDEAE4),
                          req ? AdminThemeTokens.gold : AdminThemeTokens.slate,
                        ),
                        _docStatusPill(st),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (ts != null) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              'Uploaded ${ts.year}-${ts.month.toString().padLeft(2, '0')}-${ts.day.toString().padLeft(2, '0')} '
              '${ts.hour.toString().padLeft(2, '0')}:${ts.minute.toString().padLeft(2, '0')}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AdminThemeTokens.slate,
                  ),
            ),
          ],
          if (note.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              _str(row['rejection_reason']).isNotEmpty
                  ? 'Rejection reason: $note'
                  : 'Admin note: $note',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AdminThemeTokens.danger,
                    height: 1.35,
                  ),
            ),
          ],
          if (canUpload) ...<Widget>[
            const SizedBox(height: 14),
            FilledButton(
              onPressed: uploadBusy ? null : () => onUploadDocument(type),
              child: Text(st == 'not_submitted' ? 'Upload' : 'Re-upload'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _underReviewStrip(BuildContext context) {
    return _surfaceCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            Icons.hourglass_top_rounded,
            color: AdminThemeTokens.gold,
            size: 30,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Under review',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: AdminThemeTokens.ink,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  'NexRide is reviewing your documents. You will hear from us by email; '
                  'only upload again if we request changes.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AdminThemeTokens.slate,
                        height: 1.4,
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final status =
        _str(merchant['merchant_status'] ?? merchant['status']).toLowerCase();
    final paymentModel = _str(merchant['payment_model']).toLowerCase();
    final subStatus = _str(merchant['subscription_status']).toLowerCase();

    if (status == 'pending') {
      final v = _str(merchant['verification_status']).toLowerCase();
      final underReview = v == 'pending_review' || v == 'docs_complete';
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _pendingHero(context),
          const SizedBox(height: 12),
          if (underReview) ...<Widget>[
            _underReviewStrip(context),
            const SizedBox(height: 12),
          ],
          _actionBannerIfNeeded(context, status),
          _documentSection(context, status),
          const SizedBox(height: 14),
          _textCard(
            context,
            'We will email you',
            'We will notify ${_str(merchant['contact_email']).isEmpty ? 'your contact email' : _str(merchant['contact_email'])} when there is an update.',
          ),
        ],
      );
    }

    if (status == 'rejected') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _surfaceCard(
            borderColor: AdminThemeTokens.portalSecurityTheme.dangerBorder,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(Icons.error_outline, color: AdminThemeTokens.danger),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Action required',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                              color: AdminThemeTokens.ink,
                            ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Your application was not approved. Review the note below, update your documents or profile, then resubmit.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              height: 1.4,
                              color: const Color(0xFF3D3A35),
                            ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _documentSection(context, status),
          const SizedBox(height: 14),
          _textCard(
            context,
            'Admin note',
            _str(merchant['admin_note']).isEmpty
                ? 'No note was provided.'
                : _str(merchant['admin_note']),
          ),
          const SizedBox(height: 16),
          _surfaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  'Update and resubmit',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: AdminThemeTokens.ink,
                      ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: resubmitBusiness,
                  decoration: const InputDecoration(labelText: 'Business name'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: resubmitOwner,
                  decoration: const InputDecoration(labelText: 'Owner name'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: resubmitPhone,
                  decoration: const InputDecoration(labelText: 'Phone'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: resubmitEmail,
                  decoration: const InputDecoration(labelText: 'Contact email'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: resubmitAddress,
                  decoration: const InputDecoration(labelText: 'Address'),
                  maxLines: 2,
                ),
                const SizedBox(height: 10),
                Text(
                  'Payment model (while rejected)',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: AdminThemeTokens.slate,
                      ),
                ),
                const SizedBox(height: 6),
                SegmentedButton<String>(
                  segments: const <ButtonSegment<String>>[
                    ButtonSegment<String>(
                      value: 'subscription',
                      label: Text('Subscription'),
                    ),
                    ButtonSegment<String>(
                      value: 'commission',
                      label: Text('Commission'),
                    ),
                  ],
                  selected: <String>{resubmitPaymentModel},
                  onSelectionChanged: (Set<String> s) {
                    if (s.isNotEmpty) onPaymentModelChanged(s.first);
                  },
                ),
                if (resubmitErr != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      resubmitErr!,
                      style: TextStyle(color: AdminThemeTokens.danger),
                    ),
                  ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: resubmitBusy ? null : onResubmit,
                  child: resubmitBusy
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Resubmit application'),
                ),
              ],
            ),
          ),
        ],
      );
    }

    if (status == 'suspended') {
      return _surfaceCard(
        borderColor: AdminThemeTokens.border,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Account suspended',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: AdminThemeTokens.ink,
                  ),
            ),
            const SizedBox(height: 10),
            Text(
              _str(merchant['admin_note']).isEmpty
                  ? 'This merchant account is suspended. Contact NexRide support if you believe this is a mistake.'
                  : _str(merchant['admin_note']),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    height: 1.45,
                    color: const Color(0xFF3D3A35),
                  ),
            ),
            const SizedBox(height: 12),
            Text(
              'Support: please reach out through the NexRide support channel you were given during onboarding.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AdminThemeTokens.slate,
                    height: 1.35,
                  ),
            ),
          ],
        ),
      );
    }

    if (status == 'approved' && paymentModel == 'commission') {
      return _textCard(
        context,
        'Merchant dashboard',
        'Welcome, ${_str(merchant['business_name'])}.\n\n'
        'You are on the commission plan (10% per completed order, 90% withdrawal). '
        'Menus, orders, and payouts will appear here in later phases.',
      );
    }

    if (status == 'approved' &&
        paymentModel == 'subscription' &&
        subStatus == 'active') {
      return _textCard(
        context,
        'Merchant dashboard',
        'Welcome, ${_str(merchant['business_name'])}.\n\n'
        'Your subscription is active. Store operations, menus, and orders will appear here in later phases.',
      );
    }

    if (status == 'approved' &&
        paymentModel == 'subscription' &&
        subStatus != 'active') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _surfaceCard(
            borderColor: AdminThemeTokens.portalSecurityTheme.warningBorder,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Subscription payment required',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: AdminThemeTokens.ink,
                      ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Your application is approved. Complete the ₦25,000/month '
                  'subscription to activate full operations. '
                  '(Online payment is coming soon.)',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        height: 1.45,
                        color: const Color(0xFF3D3A35),
                      ),
                ),
                const SizedBox(height: 10),
                _pill(
                  'Subscription: $subStatus',
                  AdminThemeTokens.portalSecurityTheme.warningBackground,
                  AdminThemeTokens.warning,
                ),
              ],
            ),
          ),
        ],
      );
    }

    if (status == 'approved') {
      return _textCard(
        context,
        'Merchant dashboard',
        'Welcome, ${_str(merchant['business_name'])}.\n\n'
        'Your verification is complete. Menus, orders, and payouts will '
        'appear here in later phases.',
      );
    }

    return _textCard(context, 'Unknown status', status);
  }
}

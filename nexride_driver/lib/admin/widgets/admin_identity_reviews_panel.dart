import 'package:flutter/material.dart';

import '../admin_config.dart';
import '../models/admin_models.dart';
import 'admin_components.dart';

/// Fetches one page of identity reviews. Injected so the panel is testable
/// without Firebase.
typedef IdentityReviewPageFetcher = Future<AdminIdentityReviewsPageResult>
    Function({String? cursor, String? status, bool flaggedOnly});

/// Fetches the detail for a single driver's review.
typedef IdentityReviewDetailFetcher = Future<AdminIdentityReview?> Function(
  String driverId,
);

/// Observe-only "Identity Reviews" surface.
///
/// Read-only: it lists duplicate identity review signals and opens a detail
/// modal. It performs NO mutations and exposes no resolve/clear action. All
/// data comes from the injected callable-backed fetchers (callable pagination,
/// manual refresh only — no listeners, no polling).
class AdminIdentityReviewsPanel extends StatefulWidget {
  const AdminIdentityReviewsPanel({
    required this.onFetchPage,
    required this.onFetchDetail,
    super.key,
  });

  final IdentityReviewPageFetcher onFetchPage;
  final IdentityReviewDetailFetcher onFetchDetail;

  @override
  State<AdminIdentityReviewsPanel> createState() =>
      _AdminIdentityReviewsPanelState();
}

class _AdminIdentityReviewsPanelState extends State<AdminIdentityReviewsPanel> {
  bool _loading = true;
  String? _error;
  List<AdminIdentityReview> _reviews = const <AdminIdentityReview>[];
  String _statusFilter = 'all';
  bool _flaggedOnly = false;
  bool _hasMore = false;
  String? _nextCursor;

  // Cursor stack: index 0 is the first page (null cursor). The top is the
  // cursor that produced the page currently displayed.
  final List<String?> _cursorStack = <String?>[null];

  @override
  void initState() {
    super.initState();
    _load(_cursorStack.last);
  }

  Future<void> _load(String? cursor) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final AdminIdentityReviewsPageResult page = await widget.onFetchPage(
        cursor: cursor,
        status: _statusFilter == 'all' ? null : _statusFilter,
        flaggedOnly: _flaggedOnly,
      );
      if (!mounted) return;
      setState(() {
        _reviews = page.reviews;
        _nextCursor = page.nextCursor;
        _hasMore = page.hasMore;
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

  void _resetAndReload() {
    _cursorStack
      ..clear()
      ..add(null);
    _load(null);
  }

  void _onNext() {
    if (!_hasMore || _nextCursor == null || _nextCursor!.isEmpty) return;
    _cursorStack.add(_nextCursor);
    _load(_nextCursor);
  }

  void _onPrev() {
    if (_cursorStack.length <= 1) return;
    _cursorStack.removeLast();
    _load(_cursorStack.last);
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'duplicate_review_required':
        return AdminThemeTokens.danger;
      case 'warning':
        return AdminThemeTokens.warning;
      case 'clear':
        return AdminThemeTokens.success;
      default:
        return AdminThemeTokens.slate;
    }
  }

  String _fmtTime(DateTime? dt) {
    if (dt == null) return '—';
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const AdminSectionHeader(
          title: 'Identity Reviews',
          description:
              'Observe-only duplicate identity signals from worker identity checks. '
              'Read-only — these do not block withdrawals, dispatch, or onboarding yet.',
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AdminThemeTokens.info.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Row(
            children: <Widget>[
              Icon(Icons.visibility_outlined,
                  size: 18, color: AdminThemeTokens.info),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Observe-only. No user is blocked by these signals. Use them to '
                  'manually investigate possible duplicate worker accounts.',
                  style: TextStyle(fontSize: 13, color: Color(0xFF3D3A35)),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            DropdownButton<String>(
              key: const Key('identity_reviews_status_filter'),
              value: _statusFilter,
              items: const <DropdownMenuItem<String>>[
                DropdownMenuItem(value: 'all', child: Text('All statuses')),
                DropdownMenuItem(
                  value: 'duplicate_review_required',
                  child: Text('Duplicate review required'),
                ),
                DropdownMenuItem(value: 'warning', child: Text('Warning')),
                DropdownMenuItem(value: 'clear', child: Text('Clear')),
              ],
              onChanged: _loading
                  ? null
                  : (String? v) {
                      if (v == null) return;
                      setState(() => _statusFilter = v);
                      _resetAndReload();
                    },
            ),
            FilterChip(
              key: const Key('identity_reviews_flagged_only'),
              label: const Text('Flagged only'),
              selected: _flaggedOnly,
              onSelected: _loading
                  ? null
                  : (bool v) {
                      setState(() => _flaggedOnly = v);
                      _resetAndReload();
                    },
            ),
            OutlinedButton.icon(
              key: const Key('identity_reviews_refresh'),
              onPressed: _loading ? null : () => _load(_cursorStack.last),
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
        const SizedBox(height: 12),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_reviews.isEmpty)
          const AdminEmptyState(
            title: 'No identity reviews on this page',
            message:
                'Try another status filter, turn off “Flagged only”, or refresh '
                'after more identity checks run.',
            icon: Icons.fingerprint_outlined,
          )
        else
          ..._reviews.map(_reviewCard),
        const SizedBox(height: 12),
        Row(
          children: <Widget>[
            const Expanded(
              child: Text(
                'Callable-paged, 50 rows per request. Manual refresh only.',
                style: TextStyle(
                  color: AdminThemeTokens.slate,
                  fontSize: 12,
                ),
              ),
            ),
            TextButton(
              key: const Key('identity_reviews_prev'),
              onPressed:
                  (_loading || _cursorStack.length <= 1) ? null : _onPrev,
              child: const Text('Previous'),
            ),
            TextButton(
              key: const Key('identity_reviews_next'),
              onPressed: (_loading || !_hasMore || (_nextCursor ?? '').isEmpty)
                  ? null
                  : _onNext,
              child: const Text('Next'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _reviewCard(AdminIdentityReview r) {
    final List<String> subParts = <String>[
      if (r.serviceType.isNotEmpty) r.serviceType,
      if (r.dispatchVehicleType.isNotEmpty) r.dispatchVehicleType,
      if (r.ownershipMode.isNotEmpty) r.ownershipMode,
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        key: Key('identity_review_card_${r.driverId}'),
        borderRadius: BorderRadius.circular(16),
        onTap: () => _openDetail(r),
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
                          r.driverName.isNotEmpty ? r.driverName : r.driverId,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            color: AdminThemeTokens.ink,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          r.driverId,
                          style: const TextStyle(
                            fontSize: 12,
                            color: AdminThemeTokens.slate,
                          ),
                        ),
                        if (subParts.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              subParts.join(' · '),
                              style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xFF6A6359),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  AdminStatusChip(r.status, color: _statusColor(r.status)),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 16,
                runSpacing: 4,
                children: <Widget>[
                  _miniStat('Matched claims',
                      r.matchedClaimTypes.isEmpty ? '—' : r.matchedClaimTypes.join(', ')),
                  _miniStat('Matched workers', '${r.matchedWorkerCount}'),
                  _miniStat(
                      'Matched businesses',
                      r.matchedBusinessIds.isEmpty
                          ? '—'
                          : r.matchedBusinessIds.join(', ')),
                  if (r.businessId.isNotEmpty)
                    _miniStat('Business', r.businessId),
                  _miniStat('Updated', _fmtTime(r.updatedAt)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _miniStat(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: AdminThemeTokens.slate),
        ),
        Text(
          value,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }

  Future<void> _openDetail(AdminIdentityReview summary) async {
    // Fetch fresh detail; fall back to the summary row if it fails.
    AdminIdentityReview detail = summary;
    try {
      final AdminIdentityReview? fetched =
          await widget.onFetchDetail(summary.driverId);
      if (fetched != null) detail = fetched;
    } catch (_) {
      // Keep the summary view; detail is best-effort and read-only.
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return Dialog(
          insetPadding: const EdgeInsets.all(24),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const Expanded(
                          child: Text(
                            'Identity review',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                              color: AdminThemeTokens.ink,
                            ),
                          ),
                        ),
                        AdminStatusChip(detail.status,
                            color: _statusColor(detail.status)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      detail.driverId,
                      style: const TextStyle(color: AdminThemeTokens.slate),
                    ),
                    const SizedBox(height: 16),
                    AdminKeyValueWrap(
                      items: <String, String>{
                        'Driver name':
                            detail.driverName.isNotEmpty ? detail.driverName : '—',
                        'Phone': detail.phone.isNotEmpty ? detail.phone : '—',
                        'Email': detail.email.isNotEmpty ? detail.email : '—',
                        'Service type': detail.serviceType.isNotEmpty
                            ? detail.serviceType
                            : '—',
                        'Ownership mode': detail.ownershipMode.isNotEmpty
                            ? detail.ownershipMode
                            : '—',
                        'Business ID':
                            detail.businessId.isNotEmpty ? detail.businessId : '—',
                        'Dispatch vehicle': detail.dispatchVehicleType.isNotEmpty
                            ? detail.dispatchVehicleType
                            : '—',
                        'Duplicate review required':
                            detail.duplicateReviewRequired ? 'Yes' : 'No',
                        'Updated': _fmtTime(detail.updatedAt),
                      },
                    ),
                    const SizedBox(height: 16),
                    _detailList('Matched claim types', detail.matchedClaimTypes),
                    _detailList('Blocking claim types', detail.blockingClaimTypes),
                    _detailList('Warning claim types', detail.warningClaimTypes),
                    _detailList('Matched worker ids', detail.matchedWorkerIds),
                    _detailList('Matched business ids', detail.matchedBusinessIds),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AdminThemeTokens.info.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Text(
                        'Observe-only: this signal does not block the user yet. '
                        'No resolve/clear action is available.',
                        style: TextStyle(fontSize: 13, color: Color(0xFF3D3A35)),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        child: const Text('Close'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _detailList(String label, List<String> values) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: AdminThemeTokens.slate,
            ),
          ),
          const SizedBox(height: 4),
          if (values.isEmpty)
            const Text('—', style: TextStyle(fontSize: 13))
          else
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: values
                  .map((String v) => Chip(
                        label: Text(v, style: const TextStyle(fontSize: 12)),
                        materialTapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                      ))
                  .toList(),
            ),
        ],
      ),
    );
  }
}

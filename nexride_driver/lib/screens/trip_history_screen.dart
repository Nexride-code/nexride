import 'package:flutter/material.dart';

import '../services/driver_finance_service.dart';

class TripHistoryScreen extends StatefulWidget {
  const TripHistoryScreen({super.key, required this.driverId});

  final String driverId;

  @override
  State<TripHistoryScreen> createState() => _TripHistoryScreenState();
}

class _TripHistoryScreenState extends State<TripHistoryScreen> {
  final DriverFinanceService _financeService = DriverFinanceService();

  DriverFinanceSnapshot? _snapshot;
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadTripHistory();
  }

  Future<void> _loadTripHistory({bool showLoader = true}) async {
    if (showLoader) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
    } else {
      setState(() {
        _errorMessage = null;
      });
    }

    try {
      final snapshot = await _financeService.fetchDriverFinanceSnapshot(
        driverId: widget.driverId,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _snapshot = snapshot;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoading = false;
        _errorMessage =
            'We could not load trip history right now. Pull to refresh or try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final earnings = snapshot?.earnings ?? const <DriverEarningRecord>[];
    final pendingReviews = earnings
        .where((DriverEarningRecord record) =>
            record.settlementStatus == 'payment_review')
        .length;

    return Scaffold(
      appBar: AppBar(title: const Text('Trip history')),
      body: _isLoading && snapshot == null
          ? const _TripHistoryLoadingState()
          : snapshot == null
              ? _TripHistoryErrorState(
                  message: _errorMessage ??
                      'Trip history is unavailable right now. Please try again.',
                  onRetry: _loadTripHistory,
                )
              : RefreshIndicator(
                  onRefresh: () => _loadTripHistory(showLoader: false),
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                    children: [
                      if (_errorMessage != null) ...[
                        _TripHistoryNoticeCard(message: _errorMessage!),
                        const SizedBox(height: 16),
                      ],
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          _TripHistorySummaryCard(
                            title: 'Completed trips',
                            value: earnings.length.toString(),
                            icon: Icons.route_outlined,
                          ),
                          _TripHistorySummaryCard(
                            title: 'Net earnings',
                            value: DriverFinanceService.formatNaira(
                              snapshot.totalEarnings,
                            ),
                            icon: Icons.account_balance_wallet_outlined,
                          ),
                          _TripHistorySummaryCard(
                            title: 'Payment reviews',
                            value: pendingReviews.toString(),
                            icon: Icons.rule_folder_outlined,
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      const _TripHistorySectionHeader(
                        title: 'Completed trip records',
                        subtitle:
                            'Gross fare, commission deduction, net payout, payment method, and route details stay aligned with the saved settlement record.',
                      ),
                      const SizedBox(height: 12),
                      if (earnings.isEmpty)
                        const _TripHistoryEmptyState(
                          icon: Icons.receipt_long_outlined,
                          title: 'No trip records yet',
                          message:
                              'Completed trips will appear here as soon as your account has finished rides and the settlement data is available.',
                        )
                      else
                        ...earnings.map(
                          (DriverEarningRecord record) => Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _TripHistoryRecordCard(record: record),
                          ),
                        ),
                    ],
                  ),
                ),
    );
  }
}

class _TripHistoryLoadingState extends StatelessWidget {
  const _TripHistoryLoadingState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.06),
                blurRadius: 18,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  height: 36,
                  width: 36,
                  child: CircularProgressIndicator(strokeWidth: 3),
                ),
                const SizedBox(height: 18),
                const Text(
                  'Loading trip history',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF111111),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Preparing your completed trip records, payout details, and review status.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.black.withValues(alpha: 0.64),
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TripHistorySummaryCard extends StatelessWidget {
  const _TripHistorySummaryCard({
    required this.title,
    required this.value,
    required this.icon,
  });

  final String title;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: MediaQuery.of(context).size.width > 420
          ? (MediaQuery.of(context).size.width - 44) / 2
          : double.infinity,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 16,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 42,
                width: 42,
                decoration: BoxDecoration(
                  color: const Color(0xFFF3E3BE),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: const Color(0xFF8A6424)),
              ),
              const SizedBox(height: 16),
              Text(
                title,
                style: TextStyle(
                  color: Colors.black.withValues(alpha: 0.64),
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF111111),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TripHistorySectionHeader extends StatelessWidget {
  const _TripHistorySectionHeader({
    required this.title,
    required this.subtitle,
  });

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: Color(0xFF111111),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: TextStyle(
            color: Colors.black.withValues(alpha: 0.64),
            height: 1.4,
          ),
        ),
      ],
    );
  }
}

class _TripHistoryRecordCard extends StatelessWidget {
  const _TripHistoryRecordCard({required this.record});

  final DriverEarningRecord record;

  @override
  Widget build(BuildContext context) {
    final isPaymentReview = record.settlementStatus == 'payment_review';

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 14,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        record.rideId.isNotEmpty
                            ? 'Ride ${record.rideId}'
                            : 'Trip record',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF111111),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        DriverFinanceService.formatDateTime(record.tripDate),
                        style: TextStyle(
                          color: Colors.black.withValues(alpha: 0.62),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                _TripHistoryStatusChip(
                  label: isPaymentReview ? 'Payment review' : 'Completed',
                  color: isPaymentReview
                      ? const Color(0xFF8A6424)
                      : const Color(0xFF1B7F5A),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _TripHistoryAddressLine(
              icon: Icons.radio_button_checked,
              label: 'Pickup',
              value: record.pickupSummary.isNotEmpty
                  ? record.pickupSummary
                  : 'Pickup summary unavailable',
            ),
            const SizedBox(height: 10),
            _TripHistoryAddressLine(
              icon: Icons.location_on_outlined,
              label: 'Destination',
              value: record.destinationSummary.isNotEmpty
                  ? record.destinationSummary
                  : 'Destination summary unavailable',
            ),
            const SizedBox(height: 18),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _TripHistoryMetricTile(
                  label: 'Gross fare',
                  value: DriverFinanceService.formatNaira(record.grossFare),
                ),
                _TripHistoryMetricTile(
                  label: 'Commission',
                  value: DriverFinanceService.formatNaira(record.commission),
                ),
                _TripHistoryMetricTile(
                  label: 'Net payout',
                  value: DriverFinanceService.formatNaira(record.netEarning),
                  emphasized: true,
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(
                  Icons.payments_outlined,
                  size: 18,
                  color: Colors.black.withValues(alpha: 0.64),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Payment method: ${record.paymentMethod}',
                    style: TextStyle(
                      color: Colors.black.withValues(alpha: 0.72),
                      fontWeight: FontWeight.w600,
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
}

class _TripHistoryMetricTile extends StatelessWidget {
  const _TripHistoryMetricTile({
    required this.label,
    required this.value,
    this.emphasized = false,
  });

  final String label;
  final String value;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 130),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: emphasized ? const Color(0xFFFFF8E7) : const Color(0xFFF7F4EE),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: emphasized ? const Color(0xFFE6C97A) : const Color(0xFFE9E2D5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: Colors.black.withValues(alpha: 0.62),
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: emphasized
                  ? const Color(0xFF8A6424)
                  : const Color(0xFF111111),
            ),
          ),
        ],
      ),
    );
  }
}

class _TripHistoryAddressLine extends StatelessWidget {
  const _TripHistoryAddressLine({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: const Color(0xFF8A6424)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: Colors.black.withValues(alpha: 0.58),
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: const TextStyle(
                  color: Color(0xFF111111),
                  fontWeight: FontWeight.w600,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TripHistoryStatusChip extends StatelessWidget {
  const _TripHistoryStatusChip({
    required this.label,
    required this.color,
  });

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _TripHistoryNoticeCard extends StatelessWidget {
  const _TripHistoryNoticeCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF6E2),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE7C87A)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, color: Color(0xFF8A6424)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: Color(0xFF6E531D),
                height: 1.4,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TripHistoryEmptyState extends StatelessWidget {
  const _TripHistoryEmptyState({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            height: 54,
            width: 54,
            decoration: BoxDecoration(
              color: const Color(0xFFF7F0DF),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Icon(icon, color: const Color(0xFF8A6424)),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: Color(0xFF111111),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.black.withValues(alpha: 0.66),
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _TripHistoryErrorState extends StatelessWidget {
  const _TripHistoryErrorState({
    required this.message,
    required this.onRetry,
  });

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.sync_problem_outlined,
              size: 42,
              color: Color(0xFF8A6424),
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.black.withValues(alpha: 0.74),
                height: 1.5,
              ),
            ),
            const SizedBox(height: 18),
            ElevatedButton(
              onPressed: onRetry,
              child: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}

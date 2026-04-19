import 'package:flutter/material.dart';

import '../services/driver_finance_service.dart';

class EarningsScreen extends StatefulWidget {
  const EarningsScreen({super.key, required this.driverId});

  final String driverId;

  @override
  State<EarningsScreen> createState() => _EarningsScreenState();
}

class _EarningsScreenState extends State<EarningsScreen> {
  final DriverFinanceService _financeService = DriverFinanceService();

  DriverFinanceSnapshot? _snapshot;
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadFinance();
  }

  Future<void> _loadFinance({bool showLoader = true}) async {
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
            'We could not load earnings records right now. Pull to refresh or try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;

    return Scaffold(
      appBar: AppBar(title: const Text('Earnings')),
      body: _isLoading && snapshot == null
          ? const _FinanceLoadingState(
              title: 'Loading earnings',
              message:
                  'Preparing your payout summary, completed trip records, and commission breakdown.',
            )
          : snapshot == null
              ? _FinanceErrorState(
                  message: _errorMessage ??
                      'Earnings are unavailable right now. Please try again.',
                  onRetry: _loadFinance,
                )
              : RefreshIndicator(
                  onRefresh: () => _loadFinance(showLoader: false),
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                    children: [
                      if (_errorMessage != null) ...[
                        _InlineNoticeCard(
                          title: 'Refresh needed',
                          message: _errorMessage!,
                          icon: Icons.sync_problem_outlined,
                        ),
                        const SizedBox(height: 16),
                      ],
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          _SummaryCard(
                            title: 'Gross earnings',
                            value: DriverFinanceService.formatNaira(
                              snapshot.totalGrossEarnings,
                            ),
                            icon: Icons.receipt_long_outlined,
                          ),
                          _SummaryCard(
                            title: 'Commission deducted',
                            value: DriverFinanceService.formatNaira(
                              snapshot.totalCommissionDeducted,
                            ),
                            icon: Icons.remove_circle_outline,
                          ),
                          _SummaryCard(
                            title: 'Net earnings',
                            value: DriverFinanceService.formatNaira(
                              snapshot.totalEarnings,
                            ),
                            icon: Icons.account_balance_wallet_outlined,
                          ),
                          _SummaryCard(
                            title: 'Today',
                            value: DriverFinanceService.formatNaira(
                              snapshot.todayEarnings,
                            ),
                            icon: Icons.today_outlined,
                          ),
                          _SummaryCard(
                            title: 'This week',
                            value: DriverFinanceService.formatNaira(
                              snapshot.weeklyEarnings,
                            ),
                            icon: Icons.date_range_outlined,
                          ),
                          _SummaryCard(
                            title: 'This month',
                            value: DriverFinanceService.formatNaira(
                              snapshot.monthlyEarnings,
                            ),
                            icon: Icons.calendar_month_outlined,
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      _SectionHeader(
                        title: 'Completed trip earnings',
                        subtitle: snapshot.hasEarnings
                            ? 'Each record shows gross fare, commission deduction where applicable, net payout, and trip details from the saved settlement record.'
                            : 'Completed trips will appear here as soon as finance records are available.',
                      ),
                      const SizedBox(height: 12),
                      if (!snapshot.hasEarnings)
                        const _EmptyFinanceState(
                          icon: Icons.receipt_long_outlined,
                          title: 'No earnings records yet',
                          message:
                              'Completed trip earnings will show here once your account has finished trips and finance records are available in the backend.',
                        )
                      else
                        ...snapshot.earnings.map(
                          (DriverEarningRecord record) => Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _EarningRecordCard(record: record),
                          ),
                        ),
                    ],
                  ),
                ),
    );
  }
}

class _FinanceLoadingState extends StatelessWidget {
  const _FinanceLoadingState({
    required this.title,
    required this.message,
  });

  final String title;
  final String message;

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
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF111111),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  message,
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

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
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
              color: Colors.black.withValues(alpha: 0.06),
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

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
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

class _EarningRecordCard extends StatelessWidget {
  const _EarningRecordCard({required this.record});

  final DriverEarningRecord record;

  @override
  Widget build(BuildContext context) {
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
                _StatusChip(
                  label: record.settlementStatus == 'payment_review'
                      ? 'Payment review'
                      : 'Completed',
                  color: record.settlementStatus == 'payment_review'
                      ? const Color(0xFF8A6424)
                      : const Color(0xFF1B7F5A),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _AddressLine(
              icon: Icons.radio_button_checked,
              label: 'Pickup',
              value: record.pickupSummary.isNotEmpty
                  ? record.pickupSummary
                  : 'Pickup summary unavailable',
            ),
            const SizedBox(height: 10),
            _AddressLine(
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
                _MetricTile(
                  label: 'Gross fare',
                  value: DriverFinanceService.formatNaira(record.grossFare),
                ),
                _MetricTile(
                  label: 'Commission deduction',
                  value: DriverFinanceService.formatNaira(record.commission),
                ),
                _MetricTile(
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
                Text(
                  'Payment method: ${record.paymentMethod}',
                  style: TextStyle(
                    color: Colors.black.withValues(alpha: 0.72),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            if (record.grossFare > 0 && record.commission == 0) ...[
              const SizedBox(height: 12),
              Text(
                'No commission was deducted for this trip.',
                style: TextStyle(
                  color: Colors.black.withValues(alpha: 0.64),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
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

class _AddressLine extends StatelessWidget {
  const _AddressLine({
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
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, size: 18, color: const Color(0xFF8A6424)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: Colors.black.withValues(alpha: 0.6),
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: const TextStyle(
                  color: Color(0xFF111111),
                  height: 1.35,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
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

class _InlineNoticeCard extends StatelessWidget {
  const _InlineNoticeCard({
    required this.title,
    required this.message,
    required this.icon,
  });

  final String title;
  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    const color = Color(0xFF8A6424);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withValues(alpha: 0.16)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: color,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  message,
                  style: TextStyle(
                    color: Colors.black.withValues(alpha: 0.72),
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyFinanceState extends StatelessWidget {
  const _EmptyFinanceState({
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
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 14,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            height: 64,
            width: 64,
            decoration: BoxDecoration(
              color: const Color(0xFFF3E3BE),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(icon, color: const Color(0xFF8A6424), size: 32),
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
              color: Colors.black.withValues(alpha: 0.68),
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}

class _FinanceErrorState extends StatelessWidget {
  const _FinanceErrorState({
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
              Icons.wifi_off_rounded,
              size: 48,
              color: Color(0xFF8A6424),
            ),
            const SizedBox(height: 16),
            const Text(
              'Unable to load earnings',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.black.withValues(alpha: 0.68),
                height: 1.45,
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

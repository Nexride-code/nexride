import 'package:flutter/material.dart';

import '../services/driver_finance_service.dart';

class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key, required this.driverId});

  final String driverId;

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  final DriverFinanceService _financeService = DriverFinanceService();

  DriverFinanceSnapshot? _snapshot;
  bool _isLoading = true;
  bool _isSubmittingWithdrawal = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadWallet();
  }

  Future<void> _loadWallet({bool showLoader = true}) async {
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
            'We could not load wallet details right now. Pull to refresh or try again.';
      });
    }
  }

  Future<void> _submitWithdrawal(double amount) async {
    final snapshot = _snapshot;
    if (snapshot == null) {
      return;
    }
    if (amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid withdrawal amount.')),
      );
      return;
    }
    if (amount > snapshot.currentWalletBalance) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Withdrawal amount exceeds wallet balance.')),
      );
      return;
    }

    setState(() {
      _isSubmittingWithdrawal = true;
    });

    try {
      await _financeService.createWithdrawalRequest(
        driverId: widget.driverId,
        amount: amount,
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Withdrawal request submitted successfully.'),
        ),
      );
      await _loadWallet(showLoader: false);
    } on StateError catch (e) {
      if (!mounted) {
        return;
      }
      final String code = e.message;
      final String msg = switch (code) {
        'withdrawal_destination_required' =>
          'Add your bank account details before requesting a withdrawal.',
        'insufficient_balance' =>
          'Withdrawal amount exceeds your wallet balance.',
        'invalid_amount' => 'Enter a valid withdrawal amount.',
        _ =>
          'Unable to submit the withdrawal request${code.isNotEmpty ? ' ($code)' : ''}.',
      };
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg)),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Unable to submit the withdrawal request right now.'),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSubmittingWithdrawal = false;
        });
      }
    }
  }

  Future<void> _showWithdrawDialog() async {
    final snapshot = _snapshot;
    if (snapshot == null) {
      return;
    }
    if (!snapshot.payoutDestination.isConfigured) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Add your withdrawal destination before requesting a payout.',
          ),
        ),
      );
      return;
    }

    final controller = TextEditingController();

    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Request withdrawal'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Available balance: ${DriverFinanceService.formatNaira(snapshot.currentWalletBalance)}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: controller,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Amount',
                    hintText: 'Enter withdrawal amount',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 14),
                const _PayoutNoticeCard(
                  message: DriverFinanceService.payoutNoticeText,
                ),
                const SizedBox(height: 12),
                _DestinationSummaryCard(
                  destination: snapshot.payoutDestination,
                  compact: true,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: _isSubmittingWithdrawal
                  ? null
                  : () async {
                      final amount = double.tryParse(
                            controller.text.replaceAll(',', '').trim(),
                          ) ??
                          0;
                      Navigator.of(dialogContext).pop();
                      await _submitWithdrawal(amount);
                    },
              child: const Text('Submit'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showEditDestinationDialog(
    DriverPayoutDestination current,
  ) async {
    final bankController = TextEditingController(text: current.bankName);
    final accountController = TextEditingController(text: current.accountNumber);
    final holderController = TextEditingController(text: current.accountName);
    final bankCodeController = TextEditingController(text: current.bankCode);
    var saving = false;

    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return StatefulBuilder(
          builder: (BuildContext context, void Function(void Function()) setLocal) {
            return AlertDialog(
              title: const Text('Withdrawal destination'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    TextField(
                      controller: bankController,
                      decoration: const InputDecoration(
                        labelText: 'Bank name',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: accountController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Account number',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: holderController,
                      decoration: const InputDecoration(
                        labelText: 'Account holder name',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: bankCodeController,
                      decoration: const InputDecoration(
                        labelText: 'Bank code (optional)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: saving ? null : () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: saving
                      ? null
                      : () async {
                          setLocal(() {
                            saving = true;
                          });
                          try {
                            await _financeService.saveWithdrawalDestination(
                              destination: DriverPayoutDestination(
                                bankName: bankController.text.trim(),
                                accountName: holderController.text.trim(),
                                accountNumber: accountController.text.trim(),
                                bankCode: bankCodeController.text.trim(),
                              ),
                            );
                            if (!mounted) {
                              return;
                            }
                            Navigator.of(dialogContext).pop();
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Withdrawal destination saved.'),
                              ),
                            );
                            await _loadWallet(showLoader: false);
                          } on StateError catch (e) {
                            if (!mounted) {
                              return;
                            }
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(e.message)),
                            );
                          } catch (_) {
                            if (!mounted) {
                              return;
                            }
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Could not save. Try again.'),
                              ),
                            );
                          } finally {
                            if (dialogContext.mounted) {
                              setLocal(() {
                                saving = false;
                              });
                            }
                          }
                        },
                  child: saving
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );

    bankController.dispose();
    accountController.dispose();
    holderController.dispose();
    bankCodeController.dispose();
  }

  void _showWithdrawalDetails(DriverWithdrawalRecord record) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Withdrawal details',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
                const SizedBox(height: 16),
                _DetailRow(
                  label: 'Amount',
                  value: DriverFinanceService.formatNaira(record.amount),
                ),
                _DetailRow(
                  label: 'Requested',
                  value:
                      DriverFinanceService.formatDateTime(record.requestDate),
                ),
                _DetailRow(label: 'Status', value: record.status.label),
                if (record.processedDate != null)
                  _DetailRow(
                    label: 'Processed',
                    value: DriverFinanceService.formatDateTime(
                        record.processedDate),
                  ),
                _DetailRow(
                  label: 'Payout reference',
                  value: record.payoutReference.isNotEmpty
                      ? record.payoutReference
                      : 'Not available yet',
                ),
                _DetailRow(
                  label: 'Destination',
                  value: record.destination.isConfigured
                      ? record.destination.summary
                      : 'Destination account not available yet',
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;

    return Scaffold(
      appBar: AppBar(title: const Text('Wallet')),
      body: _isLoading && snapshot == null
          ? const _WalletLoadingState()
          : snapshot == null
              ? _WalletErrorState(
                  message: _errorMessage ??
                      'Wallet details are unavailable right now. Please try again.',
                  onRetry: _loadWallet,
                )
              : RefreshIndicator(
                  onRefresh: () => _loadWallet(showLoader: false),
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                    children: [
                      if (_errorMessage != null) ...[
                        _InlineWarningBanner(message: _errorMessage!),
                        const SizedBox(height: 16),
                      ],
                      _WalletBalanceHero(
                        balance: DriverFinanceService.formatNaira(
                          snapshot.currentWalletBalance,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          _WalletStatCard(
                            title: 'Total credited',
                            value: DriverFinanceService.formatNaira(
                              snapshot.totalCreditedAmount,
                            ),
                            icon: Icons.arrow_downward_rounded,
                          ),
                          _WalletStatCard(
                            title: 'Total withdrawn',
                            value: DriverFinanceService.formatNaira(
                              snapshot.totalWithdrawnAmount,
                            ),
                            icon: Icons.arrow_upward_rounded,
                          ),
                          _WalletStatCard(
                            title: 'Pending withdrawals',
                            value: DriverFinanceService.formatNaira(
                              snapshot.pendingWithdrawals,
                            ),
                            icon: Icons.schedule_outlined,
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      const _PayoutNoticeCard(
                        message: DriverFinanceService.payoutNoticeText,
                      ),
                      const SizedBox(height: 14),
                      _DestinationSummaryCard(
                        destination: snapshot.payoutDestination,
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _isSubmittingWithdrawal
                              ? null
                              : () async {
                                  await _showEditDestinationDialog(
                                    snapshot.payoutDestination,
                                  );
                                },
                          icon: const Icon(Icons.account_balance_outlined, size: 18),
                          label: Text(
                            snapshot.payoutDestination.isConfigured
                                ? 'Edit withdrawal destination'
                                : 'Add withdrawal destination',
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      _WithdrawalActionCard(
                        isSubmitting: _isSubmittingWithdrawal,
                        balance: snapshot.currentWalletBalance,
                        hasDestination: snapshot.payoutDestination.isConfigured,
                        onPressed: snapshot.currentWalletBalance > 0 &&
                                snapshot.payoutDestination.isConfigured
                            ? _showWithdrawDialog
                            : null,
                      ),
                      const SizedBox(height: 22),
                      const _SectionHeader(
                        title: 'Withdrawal history',
                        subtitle:
                            'Track request dates, payout status, references, and destination details.',
                      ),
                      const SizedBox(height: 12),
                      if (snapshot.withdrawals.isEmpty)
                        const _EmptyStateCard(
                          icon: Icons.account_balance_outlined,
                          title: 'No withdrawals yet',
                          message:
                              'Withdrawal requests will appear here with their processing status and payout details.',
                        )
                      else
                        ...snapshot.withdrawals.map(
                          (DriverWithdrawalRecord record) => Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _WithdrawalHistoryCard(
                              record: record,
                              onTap: () => _showWithdrawalDetails(record),
                            ),
                          ),
                        ),
                      const SizedBox(height: 22),
                      const _SectionHeader(
                        title: 'Recent wallet transactions',
                        subtitle:
                            'Trip credits reflect the net payout for each completed trip after the active monetization rule is applied.',
                      ),
                      const SizedBox(height: 12),
                      if (snapshot.walletTransactions.isEmpty)
                        const _EmptyStateCard(
                          icon: Icons.receipt_long_outlined,
                          title: 'No wallet transactions yet',
                          message:
                              'Once you receive trip credits or create withdrawals, your wallet transaction feed will appear here.',
                        )
                      else
                        ...snapshot.walletTransactions.take(10).map(
                              (DriverWalletTransaction record) => Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: _WalletTransactionCard(record: record),
                              ),
                            ),
                    ],
                  ),
                ),
    );
  }
}

class _WalletLoadingState extends StatelessWidget {
  const _WalletLoadingState();

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
                  'Loading wallet',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF111111),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Preparing your available balance, withdrawal status, and payout destination.',
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

class _WalletBalanceHero extends StatelessWidget {
  const _WalletBalanceHero({required this.balance});

  final String balance;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          colors: [Color(0xFFEBCB7A), Color(0xFFB57A2A)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 44,
            width: 44,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(
              Icons.account_balance_wallet_outlined,
              color: Colors.black,
            ),
          ),
          const SizedBox(height: 18),
          const Text(
            'Available balance',
            style: TextStyle(
              color: Colors.black87,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            balance,
            style: const TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w900,
              color: Colors.black,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Net trip payouts and withdrawal requests update here automatically.',
            style: TextStyle(
              color: Colors.black87,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class _WalletStatCard extends StatelessWidget {
  const _WalletStatCard({
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
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 14,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: const Color(0xFF8A6424)),
            const SizedBox(height: 14),
            Text(
              title,
              style: TextStyle(
                color: Colors.black.withValues(alpha: 0.64),
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              value,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: Color(0xFF111111),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PayoutNoticeCard extends StatelessWidget {
  const _PayoutNoticeCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8E7),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE6C97A)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, color: Color(0xFF8A6424)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: Colors.black.withValues(alpha: 0.75),
                height: 1.42,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DestinationSummaryCard extends StatelessWidget {
  const _DestinationSummaryCard({
    required this.destination,
    this.compact = false,
  });

  final DriverPayoutDestination destination;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(compact ? 14 : 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: compact
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 14,
                  offset: const Offset(0, 8),
                ),
              ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Withdrawal destination',
            style: TextStyle(
              color: Colors.black.withValues(alpha: 0.64),
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            destination.isConfigured
                ? destination.summary
                : 'No destination bank or account details are currently stored on this driver profile.',
            style: const TextStyle(
              color: Color(0xFF111111),
              fontWeight: FontWeight.w700,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}

class _WithdrawalActionCard extends StatelessWidget {
  const _WithdrawalActionCard({
    required this.isSubmitting,
    required this.balance,
    required this.hasDestination,
    required this.onPressed,
  });

  final bool isSubmitting;
  final double balance;
  final bool hasDestination;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final String helper;
    if (balance <= 0) {
      helper =
          'You need an available wallet balance before you can request a withdrawal.';
    } else if (!hasDestination) {
      helper =
          'Add your bank account details above before you can request a withdrawal.';
    } else {
      helper =
          'Submit a withdrawal request from your available wallet balance.';
    }
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 14,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Request a withdrawal',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: Color(0xFF111111),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            helper,
            style: TextStyle(
              color: Colors.black.withValues(alpha: 0.68),
              height: 1.4,
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: isSubmitting ? null : onPressed,
              child: isSubmitting
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Withdraw'),
            ),
          ),
        ],
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

class _WithdrawalHistoryCard extends StatelessWidget {
  const _WithdrawalHistoryCard({
    required this.record,
    required this.onTap,
  });

  final DriverWithdrawalRecord record;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final statusColor = switch (record.status) {
      DriverWithdrawalStatus.pending => const Color(0xFF8A6424),
      DriverWithdrawalStatus.processing => const Color(0xFF5B6BB2),
      DriverWithdrawalStatus.paid => const Color(0xFF1B7F5A),
      DriverWithdrawalStatus.failed => const Color(0xFFC44536),
      DriverWithdrawalStatus.unknown => Colors.black54,
    };

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      DriverFinanceService.formatNaira(record.amount),
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF111111),
                      ),
                    ),
                  ),
                  _StatusPill(
                    label: record.status.label,
                    color: statusColor,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                'Requested ${DriverFinanceService.formatDateTime(record.requestDate)}',
                style: TextStyle(
                  color: Colors.black.withValues(alpha: 0.66),
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                record.destination.isConfigured
                    ? record.destination.summary
                    : 'Destination account not available yet',
                style: const TextStyle(
                  color: Color(0xFF111111),
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                record.payoutReference.isNotEmpty
                    ? 'Reference: ${record.payoutReference}'
                    : 'Tap to view more details',
                style: TextStyle(
                  color: Colors.black.withValues(alpha: 0.62),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WalletTransactionCard extends StatelessWidget {
  const _WalletTransactionCard({required this.record});

  final DriverWalletTransaction record;

  @override
  Widget build(BuildContext context) {
    final isDebit = record.amount < 0;
    final amountColor =
        isDebit ? const Color(0xFFC44536) : const Color(0xFF1B7F5A);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 14,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 44,
            width: 44,
            decoration: BoxDecoration(
              color: amountColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(
              isDebit
                  ? Icons.arrow_upward_rounded
                  : Icons.arrow_downward_rounded,
              color: amountColor,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  record.type.label,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF111111),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  DriverFinanceService.formatDateTime(record.date),
                  style: TextStyle(
                    color: Colors.black.withValues(alpha: 0.64),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (record.referenceLabel.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    record.referenceLabel,
                    style: TextStyle(
                      color: Colors.black.withValues(alpha: 0.58),
                    ),
                  ),
                ],
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                DriverFinanceService.formatNaira(record.amount),
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: amountColor,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                record.statusLabel,
                style: TextStyle(
                  color: Colors.black.withValues(alpha: 0.62),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({
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

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: TextStyle(
                color: Colors.black.withValues(alpha: 0.62),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: Color(0xFF111111),
                fontWeight: FontWeight.w700,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InlineWarningBanner extends StatelessWidget {
  const _InlineWarningBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8E7),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE6C97A)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded, color: Color(0xFF8A6424)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: Colors.black.withValues(alpha: 0.74),
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyStateCard extends StatelessWidget {
  const _EmptyStateCard({
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

class _WalletErrorState extends StatelessWidget {
  const _WalletErrorState({
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
              size: 48,
              color: Color(0xFF8A6424),
            ),
            const SizedBox(height: 16),
            const Text(
              'Unable to load wallet',
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

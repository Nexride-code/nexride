import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_database/firebase_database.dart' as rtdb;
import 'package:flutter/foundation.dart';

import '../support/driver_profile_support.dart';
import '../support/realtime_database_error_support.dart';
import 'driver_wallet_balance_logic.dart';

enum DriverWithdrawalStatus {
  pending,
  processing,
  paid,
  rejected,
  failed,
  unknown;

  String get label {
    return switch (this) {
      DriverWithdrawalStatus.pending => 'Pending',
      DriverWithdrawalStatus.processing => 'Processing',
      DriverWithdrawalStatus.paid => 'Paid',
      DriverWithdrawalStatus.rejected => 'Rejected',
      DriverWithdrawalStatus.failed => 'Failed',
      DriverWithdrawalStatus.unknown => 'Unknown',
    };
  }
}

enum DriverWalletTransactionType {
  tripCredit,
  commissionDebit,
  withdrawalRequest,
  withdrawalProcessed,
  flutterwaveTopUp,
  adjustment;

  String get label {
    return switch (this) {
      DriverWalletTransactionType.tripCredit => 'Trip credit',
      DriverWalletTransactionType.commissionDebit => 'Commission (NexRide)',
      DriverWalletTransactionType.withdrawalRequest => 'Withdrawal request',
      DriverWalletTransactionType.withdrawalProcessed => 'Withdrawal paid',
      DriverWalletTransactionType.flutterwaveTopUp => 'Wallet top-up (Flutterwave)',
      DriverWalletTransactionType.adjustment => 'Adjustment',
    };
  }
}

class DriverPayoutDestination {
  const DriverPayoutDestination({
    required this.bankName,
    required this.accountName,
    required this.accountNumber,
    this.bankCode = '',
  });

  const DriverPayoutDestination.empty()
      : bankName = '',
        accountName = '',
        accountNumber = '',
        bankCode = '';

  final String bankName;
  final String accountName;
  final String accountNumber;
  final String bankCode;

  bool get isConfigured =>
      bankName.trim().isNotEmpty &&
      accountName.trim().isNotEmpty &&
      accountNumber.trim().isNotEmpty &&
      bankCode.trim().length >= 3;

  String get maskedAccountNumber {
    final digitsOnly = accountNumber.replaceAll(RegExp(r'\s+'), '');
    if (digitsOnly.length <= 4) {
      return digitsOnly;
    }
    final visibleDigits = digitsOnly.substring(digitsOnly.length - 4);
    return '****$visibleDigits';
  }

  String get summary {
    if (!isConfigured) {
      return 'Destination account not available yet';
    }

    final parts = <String>[
      if (bankName.isNotEmpty) bankName,
      if (maskedAccountNumber.isNotEmpty) maskedAccountNumber,
      if (accountName.isNotEmpty) accountName,
      if (bankCode.trim().isNotEmpty) 'Code $bankCode',
    ];
    return parts.join(' - ');
  }
}

class DriverWithdrawalBankOption {
  const DriverWithdrawalBankOption({
    required this.code,
    required this.name,
    this.accountBank = '',
  });

  final String code;
  final String name;
  final String accountBank;

  String get flutterwaveAccountBank =>
      accountBank.trim().isNotEmpty ? accountBank.trim() : code.trim();
}

class DriverEarningRecord {
  const DriverEarningRecord({
    required this.id,
    required this.rideId,
    required this.tripDate,
    required this.pickupSummary,
    required this.destinationSummary,
    required this.grossFare,
    required this.commission,
    required this.netEarning,
    required this.paymentMethod,
    required this.settlementStatus,
    required this.countsTowardWallet,
  });

  final String id;
  final String rideId;
  final DateTime? tripDate;
  final String pickupSummary;
  final String destinationSummary;
  final double grossFare;
  final double commission;
  final double netEarning;
  final String paymentMethod;
  final String settlementStatus;
  final bool countsTowardWallet;
}

class DriverWithdrawalRecord {
  const DriverWithdrawalRecord({
    required this.id,
    required this.amount,
    required this.requestDate,
    required this.processedDate,
    required this.status,
    required this.payoutReference,
    required this.destination,
  });

  final String id;
  final double amount;
  final DateTime? requestDate;
  final DateTime? processedDate;
  final DriverWithdrawalStatus status;
  final String payoutReference;
  final DriverPayoutDestination destination;
}

class DriverWalletTransaction {
  const DriverWalletTransaction({
    required this.id,
    required this.date,
    required this.type,
    required this.amount,
    required this.statusLabel,
    required this.referenceLabel,
  });

  final String id;
  final DateTime? date;
  final DriverWalletTransactionType type;
  final double amount;
  final String statusLabel;
  final String referenceLabel;
}

class DriverFinanceSnapshot {
  const DriverFinanceSnapshot({
    required this.totalGrossEarnings,
    required this.totalCommissionDeducted,
    required this.totalEarnings,
    required this.todayEarnings,
    required this.weeklyEarnings,
    required this.monthlyEarnings,
    required this.totalWalletBalance,
    required this.currentWalletBalance,
    required this.totalWalletCredits,
    required this.totalWalletDebits,
    required this.tripEarnings,
    required this.totalCreditedAmount,
    required this.totalWithdrawnAmount,
    required this.pendingWithdrawals,
    required this.earnings,
    required this.withdrawals,
    required this.walletTransactions,
    required this.payoutDestination,
    required this.hasLiveBackendData,
    this.businessManagedWithdrawalsBlocked = false,
  });

  final double totalGrossEarnings;
  final double totalCommissionDeducted;
  final double totalEarnings;
  final double todayEarnings;
  final double weeklyEarnings;
  final double monthlyEarnings;
  /// Total from `wallets/{driverId}/balance` (authoritative; not trip-derived).
  final double totalWalletBalance;
  /// Spendable = [totalWalletBalance] minus reserved pending/processing withdrawals.
  final double currentWalletBalance;
  /// Sum of `wallets/{id}/transactions` with direction=credit (or inferred credit types).
  final double totalWalletCredits;
  /// Sum of wallet debit / withdrawal transactions from RTDB ledger.
  final double totalWalletDebits;
  /// Trip settlement net earnings (not total wallet credits).
  final double tripEarnings;
  final double totalCreditedAmount;
  final double totalWithdrawnAmount;
  final double pendingWithdrawals;
  final List<DriverEarningRecord> earnings;
  final List<DriverWithdrawalRecord> withdrawals;
  final List<DriverWalletTransaction> walletTransactions;
  final DriverPayoutDestination payoutDestination;
  final bool hasLiveBackendData;
  final bool businessManagedWithdrawalsBlocked;

  bool get hasEarnings => earnings.isNotEmpty;
  bool get hasWalletActivity =>
      walletTransactions.isNotEmpty ||
      withdrawals.isNotEmpty ||
      totalWalletCredits > 0 ||
      totalWalletDebits > 0 ||
      tripEarnings > 0 ||
      totalCreditedAmount > 0 ||
      totalWithdrawnAmount > 0 ||
      pendingWithdrawals > 0 ||
      currentWalletBalance > 0;
}

class DriverFinanceService {
  DriverFinanceService({rtdb.FirebaseDatabase? database})
      : _database = database ?? rtdb.FirebaseDatabase.instance;

  final rtdb.FirebaseDatabase _database;

  rtdb.DatabaseReference get _rootRef => _database.ref();

  static const String payoutNoticeText =
      'Withdrawals above ₦300,000 may take 2-3 working days to process. '
      'Withdrawals below ₦300,000 are typically processed within 48 hours. '
      'Approved withdrawals are paid to the bank account you provide.';

  static const String fleetManagedWithdrawalNotice =
      'Withdrawals are managed by your Dispatch Fleet business.';

  static bool businessManagedWithdrawalsBlockedFromDriverData(
    Map<String, dynamic> driverData,
  ) {
    final mode = _staticText(driverData['ownership_mode'] ?? driverData['ownershipMode'])
        .toLowerCase();
    final linkStatus = _staticText(
      driverData['business_link_status'] ?? driverData['businessLinkStatus'],
    ).toLowerCase();
    if (mode == 'business_managed') {
      return true;
    }
    if (linkStatus.isNotEmpty && linkStatus != 'approved') {
      return true;
    }
    return false;
  }

  static String _staticText(dynamic value) => value?.toString().trim() ?? '';

  static String withdrawalBlockedUserMessage(String? reasonCode) {
    switch (reasonCode?.trim().toLowerCase()) {
      case 'business_managed_withdrawal_blocked':
      case 'business_link_not_approved':
        return fleetManagedWithdrawalNotice;
      default:
        return '';
    }
  }

  Future<DriverFinanceSnapshot> fetchDriverFinanceSnapshot({
    required String driverId,
  }) async {
    final normalizedDriverId = driverId.trim();
    if (normalizedDriverId.isEmpty) {
      return _emptyFinanceSnapshot(
        driverData: buildDriverProfileRecord(
          driverId: 'unknown_driver',
          existing: const <String, dynamic>{},
        ),
      );
    }

    var driverData = buildDriverProfileRecord(
      driverId: normalizedDriverId,
      existing: const <String, dynamic>{},
    );

    try {
      final driverSnapshot =
          await runOptionalRealtimeDatabaseRead<rtdb.DataSnapshot>(
        source: 'driver_finance.fetch_profile',
        path: 'drivers/$normalizedDriverId',
        action: () => _rootRef.child('drivers/$normalizedDriverId').get(),
      );
      driverData = buildDriverProfileRecord(
        driverId: normalizedDriverId,
        existing: _map(driverSnapshot?.value),
      );

      final optionalSnapshots =
          await Future.wait<rtdb.DataSnapshot?>(<Future<rtdb.DataSnapshot?>>[
        _optionalSnapshot(
          path: 'wallets/$normalizedDriverId',
          request: () => _rootRef.child('wallets/$normalizedDriverId').get(),
        ),
        _optionalSnapshot(
          path: 'driver_earnings/$normalizedDriverId',
          request: () =>
              _rootRef.child('driver_earnings/$normalizedDriverId').get(),
        ),
        _optionalSnapshot(
          path: 'driver_trips/$normalizedDriverId',
          request: () =>
              _rootRef.child('driver_trips/$normalizedDriverId').get(),
        ),
        _optionalSnapshot(
          path:
              'trip_settlement_hooks[orderByChild=driverId,equalTo=$normalizedDriverId]',
          request: () => _rootRef
              .child('trip_settlement_hooks')
              .orderByChild('driverId')
              .equalTo(normalizedDriverId)
              .get(),
        ),
        _optionalSnapshot(
          path:
              'trip_settlement_hooks[orderByChild=driver_id,equalTo=$normalizedDriverId]',
          request: () => _rootRef
              .child('trip_settlement_hooks')
              .orderByChild('driver_id')
              .equalTo(normalizedDriverId)
              .get(),
        ),
        _optionalSnapshot(
          path: 'driver_wallet_ledger/$normalizedDriverId',
          request: () =>
              _rootRef.child('driver_wallet_ledger/$normalizedDriverId').get(),
        ),
        _optionalSnapshot(
          path: 'driver_withdraw_requests/$normalizedDriverId',
          request: () => _rootRef
              .child('driver_withdraw_requests/$normalizedDriverId')
              .get(),
        ),
      ]);

      final walletsSnapshot = optionalSnapshots[0];
      final driverWalletLedgerSnapshot = optionalSnapshots[5];
      final walletsNodeLoaded = walletsSnapshot != null;
      final walletsNode = walletsNodeLoaded
          ? _map(walletsSnapshot!.value)
          : const <String, dynamic>{};
      final driverWalletLedgerNode = _map(driverWalletLedgerSnapshot?.value);
      final walletTransactionMap = _map(walletsNode['transactions']);
      bool rideWalletCreditConfirmed(String rideId) {
        final normalizedRideId = rideId.trim();
        if (normalizedRideId.isEmpty) {
          return false;
        }
        final ledger = _map(driverWalletLedgerNode['${normalizedRideId}_driver_net']);
        if (ledger['completed'] == true) {
          return true;
        }
        final tx = _map(walletTransactionMap['${normalizedRideId}_driver_net']);
        return tx.isNotEmpty;
      }
      final legacyWalletMetadata =
          walletMetadataWithoutBalance(_map(driverData['wallet']));
      final walletData = walletsNodeLoaded
          ? _mergeMaps(legacyWalletMetadata, walletsNode)
          : legacyWalletMetadata;
      final rawWalletsBalance = walletsNode['balance'];
      final legacyEarningsData = _mergeMaps(
        _map(driverData['earnings']),
        _map(optionalSnapshots[1]?.value),
      );
      final legacyTripsData = _mergeRecordCollections(
        _recordCollectionMap(driverData['trips']),
        _recordCollectionMap(optionalSnapshots[2]?.value),
      );

      final settlementEntries = <MapEntry<String, Map<String, dynamic>>>[
        ..._recordEntries(_map(optionalSnapshots[3]?.value)),
        ..._recordEntries(_map(optionalSnapshots[4]?.value)),
      ];

      final payoutDestination = _resolvePayoutDestination(
        _parseDestinationFromRecord(_map(driverData['withdrawal_destination'])),
        _resolvePayoutDestination(
          _parseDestinationFromRecord(walletData),
          _resolvePayoutDestination(
            _parseDestinationFromRecord(driverData),
            const DriverPayoutDestination.empty(),
          ),
        ),
      );
      final normalizedBusinessModel =
          normalizedDriverBusinessModel(driverData['businessModel']);

      final settlementRideIds = settlementEntries
          .map(
            (MapEntry<String, Map<String, dynamic>> entry) =>
                _rideIdFromRecord(entry.value, fallbackId: entry.key),
          )
          .where((String rideId) => rideId.isNotEmpty)
          .toSet()
          .toList(growable: false);

      final rideSnapshots =
          await Future.wait<rtdb.DataSnapshot?>(settlementRideIds.map(
        (String rideId) => _optionalSnapshot(
          path: 'ride_requests/$rideId',
          request: () => _rootRef.child('ride_requests/$rideId').get(),
        ),
      ));

      final rideDataById = <String, Map<String, dynamic>>{};
      for (var i = 0; i < settlementRideIds.length; i++) {
        rideDataById[settlementRideIds[i]] = _map(rideSnapshots[i]?.value);
      }

      final earningsById = <String, DriverEarningRecord>{};

      for (final entry in settlementEntries) {
        final rideId = _rideIdFromRecord(entry.value, fallbackId: entry.key);
        final rideData = rideDataById[rideId] ?? const <String, dynamic>{};
        final record = _earningFromRecord(
          rawRecord: entry.value,
          rideData: rideData,
          recordId: rideId.isEmpty ? entry.key : rideId,
          businessModel: normalizedBusinessModel,
          rideWalletCredited: rideWalletCreditConfirmed,
        );
        if (record == null) {
          continue;
        }
        earningsById[record.id] = record;
      }

      for (final entry in _recordEntries(legacyTripsData)) {
        final record = _earningFromRecord(
          rawRecord: entry.value,
          rideData: entry.value,
          recordId: _rideIdFromRecord(entry.value, fallbackId: entry.key),
          businessModel: normalizedBusinessModel,
          rideWalletCredited: rideWalletCreditConfirmed,
        );
        if (record == null || earningsById.containsKey(record.id)) {
          continue;
        }
        earningsById[record.id] = record;
      }

      final legacyRecords = _legacyEarningRecordMap(legacyEarningsData);
      for (final entry in _recordEntries(legacyRecords)) {
        final record = _earningFromRecord(
          rawRecord: entry.value,
          rideData: entry.value,
          recordId: _rideIdFromRecord(entry.value, fallbackId: entry.key),
          businessModel: normalizedBusinessModel,
          rideWalletCredited: rideWalletCreditConfirmed,
        );
        if (record == null || earningsById.containsKey(record.id)) {
          continue;
        }
        earningsById[record.id] = record;
      }

      final earnings = earningsById.values.toList()
        ..sort(
          (DriverEarningRecord a, DriverEarningRecord b) =>
              (b.tripDate?.millisecondsSinceEpoch ?? 0)
                  .compareTo(a.tripDate?.millisecondsSinceEpoch ?? 0),
        );

      final withdrawals = _buildWithdrawalRecords(
        driverId: normalizedDriverId,
        payoutDestination: payoutDestination,
        rawCollections: <Map<String, dynamic>>[
          _map(optionalSnapshots[6]?.value),
          _map(driverData['withdrawals']),
          _map(driverData['withdrawal_requests']),
        ],
      );

      final now = DateTime.now();
      final todayStart = DateTime(now.year, now.month, now.day);
      final weekStart =
          todayStart.subtract(Duration(days: todayStart.weekday - 1));
      final monthStart = DateTime(now.year, now.month);

      final derivedTotalEarnings = earnings.fold<double>(
        0,
        (double sum, DriverEarningRecord record) => sum + record.netEarning,
      );
      final derivedTotalGrossEarnings = earnings.fold<double>(
        0,
        (double sum, DriverEarningRecord record) => sum + record.grossFare,
      );
      final derivedTotalCommissionDeducted = earnings.fold<double>(
        0,
        (double sum, DriverEarningRecord record) => sum + record.commission,
      );
      final derivedTodayEarnings = earnings.fold<double>(
        0,
        (double sum, DriverEarningRecord record) {
          final tripDate = record.tripDate;
          if (tripDate == null) {
            return sum;
          }
          final tripDay = DateTime(tripDate.year, tripDate.month, tripDate.day);
          return tripDay == todayStart ? sum + record.netEarning : sum;
        },
      );
      final derivedWeeklyEarnings = earnings.fold<double>(
        0,
        (double sum, DriverEarningRecord record) {
          final tripDate = record.tripDate;
          if (tripDate == null) {
            return sum;
          }
          return tripDate.isBefore(weekStart) ? sum : sum + record.netEarning;
        },
      );
      final derivedMonthlyEarnings = earnings.fold<double>(
        0,
        (double sum, DriverEarningRecord record) {
          final tripDate = record.tripDate;
          if (tripDate == null) {
            return sum;
          }
          return tripDate.isBefore(monthStart) ? sum : sum + record.netEarning;
        },
      );

      final totalEarnings = earnings.isNotEmpty
          ? derivedTotalEarnings
          : _firstPositiveDouble(<dynamic>[
              legacyEarningsData['total'],
              legacyEarningsData['totalEarnings'],
              legacyEarningsData['netTotal'],
            ]);
      final totalGrossEarnings = earnings.isNotEmpty
          ? derivedTotalGrossEarnings
          : _firstPositiveDouble(<dynamic>[
              legacyEarningsData['grossTotal'],
              legacyEarningsData['grossEarnings'],
              legacyEarningsData['total'],
            ]);
      final totalCommissionDeducted = earnings.isNotEmpty
          ? derivedTotalCommissionDeducted
          : _firstPositiveDouble(<dynamic>[
              legacyEarningsData['commissionTotal'],
              legacyEarningsData['totalCommission'],
              legacyEarningsData['commissions'],
            ]);
      final todayEarnings = earnings.isNotEmpty
          ? derivedTodayEarnings
          : _firstPositiveDouble(<dynamic>[
              legacyEarningsData['today'],
              legacyEarningsData['todayEarnings'],
            ]);
      final weeklyEarnings = earnings.isNotEmpty
          ? derivedWeeklyEarnings
          : _firstPositiveDouble(<dynamic>[
              legacyEarningsData['weekly'],
              legacyEarningsData['weeklyEarnings'],
            ]);
      final monthlyEarnings = earnings.isNotEmpty
          ? derivedMonthlyEarnings
          : _firstPositiveDouble(<dynamic>[
              legacyEarningsData['monthly'],
              legacyEarningsData['monthlyEarnings'],
            ]);

      final tripEarnings = earnings.fold<double>(
        0,
        (double sum, DriverEarningRecord record) =>
            record.countsTowardWallet ? sum + record.netEarning : sum,
      );
      final totalWithdrawnAmount = withdrawals.fold<double>(
        0,
        (double sum, DriverWithdrawalRecord record) =>
            record.status == DriverWithdrawalStatus.paid
                ? sum + record.amount
                : sum,
      );
      final pendingWithdrawalAmount =
          driverPendingWithdrawalTotal(withdrawals);

      final storedWalletBalanceNgn = storedWalletBalanceFromWalletData(
        walletData,
        legacyEarningsData: legacyEarningsData,
        walletsNodeLoaded: walletsNodeLoaded,
      );
      final walletLedgerTotals = walletsNodeLoaded
          ? walletLedgerTotalsFromRtdb(walletData)
          : const WalletLedgerTotals(totalCredits: 0, totalDebits: 0);
      final totalWalletCredits = walletLedgerTotals.totalCredits;
      final totalWalletDebits = walletsNodeLoaded
          ? walletLedgerTotals.totalDebits
          : totalWithdrawnAmount;

      final totalWalletBalance =
          driverWalletTotalBalanceNgn(storedWalletBalanceNgn);
      final currentWalletBalance = driverWalletAvailableBalanceNgn(
        storedWalletBalanceNgn: storedWalletBalanceNgn,
        pendingWithdrawals: pendingWithdrawalAmount,
      );

      final walletTransactionList = walletsNodeLoaded
          ? walletTransactionsFromRtdb(walletData)
          : const <DriverWalletTransaction>[];

      debugPrint(
        'DRIVER_WITHDRAWAL_HISTORY_REFRESHED '
        'driverId=$normalizedDriverId '
        'withdrawalCount=${withdrawals.length} '
        'pendingReserved=$pendingWithdrawalAmount '
        'availableBalance=$currentWalletBalance',
      );
      if (pendingWithdrawalAmount > 0) {
        debugPrint(
          'DRIVER_WITHDRAWAL_PENDING_RESERVED '
          'driverId=$normalizedDriverId '
          'amount=$pendingWithdrawalAmount',
        );
      }
      if (kDebugMode) {
        debugPrint(
          '[DriverFinance][wallet] driverId=$normalizedDriverId '
          'walletsNodeLoaded=$walletsNodeLoaded '
          'walletDataKeys=${walletData.keys.toList()} '
          'storedWalletBalanceNgn=$storedWalletBalanceNgn '
          'rawWalletsBalance=$rawWalletsBalance '
          'currentWalletBalance=$currentWalletBalance '
          'totalWalletCredits=$totalWalletCredits '
          'totalWalletDebits=$totalWalletDebits '
          'tripEarnings=$tripEarnings '
          'walletTxCount=${walletTransactionList.length}',
        );
        if (!walletsNodeLoaded) {
          debugPrint(
            '[DriverFinance][wallet] wallets/$normalizedDriverId read returned null '
            '(likely RTDB permission-denied — deploy database.rules.json wallets read rule)',
          );
        }
      }

      final hasLiveBackendData = earnings.isNotEmpty ||
          withdrawals.isNotEmpty ||
          _recordEntries(_map(walletData['transactions'])).isNotEmpty ||
          currentWalletBalance > 0 ||
          _legacyEarningRecordMap(legacyEarningsData).isNotEmpty ||
          legacyTripsData.isNotEmpty;
      final businessManagedWithdrawalsBlocked =
          businessManagedWithdrawalsBlockedFromDriverData(driverData);

      return DriverFinanceSnapshot(
        totalGrossEarnings: totalGrossEarnings,
        totalCommissionDeducted: totalCommissionDeducted,
        totalEarnings: totalEarnings,
        todayEarnings: todayEarnings,
        weeklyEarnings: weeklyEarnings,
        monthlyEarnings: monthlyEarnings,
        totalWalletBalance: totalWalletBalance,
        currentWalletBalance: currentWalletBalance,
        totalWalletCredits: totalWalletCredits,
        totalWalletDebits: totalWalletDebits,
        tripEarnings: tripEarnings,
        totalCreditedAmount: tripEarnings,
        totalWithdrawnAmount: totalWithdrawnAmount,
        pendingWithdrawals: pendingWithdrawalAmount,
        earnings: earnings,
        withdrawals: withdrawals,
        walletTransactions: walletTransactionList,
        payoutDestination: payoutDestination,
        hasLiveBackendData: hasLiveBackendData,
        businessManagedWithdrawalsBlocked: businessManagedWithdrawalsBlocked,
      );
    } catch (error, stackTrace) {
      debugPrint(
        '[DriverFinance] finance snapshot fallback driverId=$normalizedDriverId error=$error',
      );
      debugPrintStack(
        label: '[DriverFinance] finance snapshot stack',
        stackTrace: stackTrace,
      );
      return _emptyFinanceSnapshot(driverData: driverData);
    }
  }

  Future<Map<String, dynamic>> fetchWithdrawalFeePreview({
    required String entityType,
    required double amount,
  }) async {
    final callable = FirebaseFunctions.instanceFor(
      region: 'us-central1',
    ).httpsCallable(
      'getWithdrawalFeePreview',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
    );
    final result = await callable.call(<String, dynamic>{
      'entity_type': entityType,
      'entityType': entityType,
      'amount': amount,
    });
    final data = result.data;
    if (data is! Map) {
      throw StateError('withdrawal_fee_preview_invalid_response');
    }
    final map = Map<String, dynamic>.from(data);
    if (map['success'] != true && map['success'] != 1) {
      final reason = '${map['reason'] ?? 'withdrawal_fee_preview_failed'}'.trim();
      throw StateError(reason.isEmpty ? 'withdrawal_fee_preview_failed' : reason);
    }
    return map;
  }

  /// Applies a newly created pending withdrawal to [snapshot] until RTDB refresh catches up.
  DriverFinanceSnapshot snapshotWithNewPendingWithdrawal(
    DriverFinanceSnapshot snapshot, {
    required String withdrawalId,
    required double requestedAmount,
  }) {
    return snapshotWithWithdrawalRow(
      snapshot,
      DriverWithdrawalRecord(
        id: withdrawalId.trim(),
        amount: requestedAmount,
        requestDate: DateTime.now(),
        processedDate: null,
        status: DriverWithdrawalStatus.pending,
        payoutReference: '',
        destination: snapshot.payoutDestination,
      ),
    );
  }

  /// Inserts [row] when absent and recomputes pending totals / spendable balance.
  DriverFinanceSnapshot snapshotWithWithdrawalRow(
    DriverFinanceSnapshot snapshot,
    DriverWithdrawalRecord row,
  ) {
    return driverSnapshotWithWithdrawalRow(snapshot, row);
  }

  /// Keeps optimistic/pending rows from [prior] when [refreshed] RTDB query has not caught up.
  DriverFinanceSnapshot mergeRetainingOptimisticPending({
    required DriverFinanceSnapshot refreshed,
    DriverFinanceSnapshot? prior,
    Set<String> pinnedWithdrawalIds = const <String>{},
  }) {
    return mergeDriverSnapshotsRetainingOptimisticPending(
      refreshed: refreshed,
      prior: prior,
      pinnedWithdrawalIds: pinnedWithdrawalIds,
    );
  }

  Future<Map<String, dynamic>> createWithdrawalRequest({
    required String driverId,
    required double amount,
    bool userConfirmed = true,
  }) async {
    final normalizedDriverId = driverId.trim();
    if (normalizedDriverId.isEmpty) {
      throw StateError('Driver ID is required to request a withdrawal.');
    }
    if (amount <= 0) {
      throw StateError('Withdrawal amount must be greater than zero.');
    }

    final callable = FirebaseFunctions.instanceFor(
      region: 'us-central1',
    ).httpsCallable(
      'requestWithdrawal',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 60)),
    );
    final result = await callable.call(<String, dynamic>{
      'amount': amount,
      'user_confirmed': userConfirmed,
      'userConfirmed': userConfirmed,
    });
    final data = result.data;
    if (data is! Map) {
      throw StateError('withdrawal_invalid_response');
    }
    final map = Map<String, dynamic>.from(data);
    if (map['success'] != true && map['success'] != 1) {
      final reason = '${map['reason'] ?? 'withdrawal_failed'}'.trim();
      throw StateError(reason.isEmpty ? 'withdrawal_failed' : reason);
    }
    final withdrawalId = _text(map['withdrawalId'] ?? map['withdrawal_id']);
    final requestedAmount = _firstPositiveDouble(<dynamic>[
      map['requested_amount'],
      map['requestedAmount'],
      amount,
    ]);
    debugPrint(
      'DRIVER_WITHDRAWAL_REQUEST_CREATED '
      'driverId=$normalizedDriverId '
      'withdrawalId=$withdrawalId '
      'requestedAmount=$requestedAmount',
    );
    debugPrint(
      'DRIVER_WITHDRAWAL_REQUEST_RESPONSE '
      'driverId=$normalizedDriverId '
      'withdrawalId=$withdrawalId '
      'status=${_text(map['status']).isEmpty ? 'pending' : _text(map['status'])} '
      'success=true',
    );
    return map;
  }

  /// Loads Flutterwave NGN banks for withdrawal destination picker.
  Future<List<DriverWithdrawalBankOption>> fetchWithdrawalBanks() async {
    final callable = FirebaseFunctions.instanceFor(
      region: 'us-central1',
    ).httpsCallable(
      'driverListWithdrawalBanks',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 45)),
    );
    final result = await callable.call(<String, dynamic>{});
    final data = result.data;
    if (data is! Map) {
      throw StateError('withdrawal_banks_invalid_response');
    }
    final map = Map<String, dynamic>.from(data);
    if (map['success'] != true && map['success'] != 1) {
      final reason = '${map['reason'] ?? 'withdrawal_banks_failed'}'.trim();
      throw StateError(reason.isEmpty ? 'withdrawal_banks_failed' : reason);
    }
    final rawBanks = map['banks'];
    if (rawBanks is! List) {
      return const <DriverWithdrawalBankOption>[];
    }
    final banks = <DriverWithdrawalBankOption>[];
    for (final entry in rawBanks) {
      if (entry is! Map) {
        continue;
      }
      final row = Map<String, dynamic>.from(entry);
      final code = _text(row['account_bank'] ?? row['bank_code'] ?? row['code']);
      final name = _text(row['name'] ?? row['bank_name']);
      if (code.length < 3 || name.isEmpty) {
        continue;
      }
      banks.add(
        DriverWithdrawalBankOption(
          code: code,
          name: name,
          accountBank: code,
        ),
      );
    }
    banks.sort(
      (DriverWithdrawalBankOption a, DriverWithdrawalBankOption b) =>
          a.name.compareTo(b.name),
    );
    return banks;
  }

  /// Persists payout account via [driverUpdateWithdrawalDestination] (authoritative).
  Future<void> saveWithdrawalDestination({
    required DriverPayoutDestination destination,
  }) async {
    final bankCode = destination.bankCode.trim();
    if (bankCode.length < 3) {
      throw StateError('bank_selection_required');
    }
    final callable = FirebaseFunctions.instanceFor(
      region: 'us-central1',
    ).httpsCallable(
      'driverUpdateWithdrawalDestination',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 45)),
    );
    final payload = <String, dynamic>{
      'account_holder_name': destination.accountName.trim(),
      'account_name': destination.accountName.trim(),
      'account_number': destination.accountNumber.trim().replaceAll(RegExp(r'\s+'), ''),
      'bank_code': bankCode,
      'account_bank': bankCode,
    };
    debugPrint('DRIVER_WITHDRAW_DEST_SAVE_START');
    final result = await callable.call(payload);
    final data = result.data;
    if (data is! Map) {
      debugPrint('DRIVER_WITHDRAW_DEST_SAVE_FAIL reason=destination_invalid_response');
      throw StateError('destination_invalid_response');
    }
    final map = Map<String, dynamic>.from(data);
    if (map['success'] != true && map['success'] != 1) {
      final reason = '${map['reason'] ?? 'destination_save_failed'}'.trim();
      debugPrint('DRIVER_WITHDRAW_DEST_SAVE_FAIL reason=$reason');
      throw StateError(reason.isEmpty ? 'destination_save_failed' : reason);
    }
    debugPrint('DRIVER_WITHDRAW_DEST_SAVE_SUCCESS');
  }

  Future<rtdb.DataSnapshot?> _optionalSnapshot({
    required String path,
    required RealtimeDatabaseAction<rtdb.DataSnapshot> request,
  }) async {
    return runOptionalRealtimeDatabaseRead<rtdb.DataSnapshot>(
      source: 'driver_finance.optional_read',
      path: path,
      action: request,
    );
  }

  DriverFinanceSnapshot _emptyFinanceSnapshot({
    required Map<String, dynamic> driverData,
  }) {
    return DriverFinanceSnapshot(
      totalGrossEarnings: 0,
      totalCommissionDeducted: 0,
      totalEarnings: 0,
      todayEarnings: 0,
      weeklyEarnings: 0,
      monthlyEarnings: 0,
      totalWalletBalance: 0,
      currentWalletBalance: 0,
      totalWalletCredits: 0,
      totalWalletDebits: 0,
      tripEarnings: 0,
      totalCreditedAmount: 0,
      totalWithdrawnAmount: 0,
      pendingWithdrawals: 0,
      earnings: const <DriverEarningRecord>[],
      withdrawals: const <DriverWithdrawalRecord>[],
      walletTransactions: const <DriverWalletTransaction>[],
      payoutDestination: _resolvePayoutDestination(
        _parseDestinationFromRecord(_map(driverData['withdrawal_destination'])),
        _resolvePayoutDestination(
          _parseDestinationFromRecord(_map(driverData['wallet'])),
          _resolvePayoutDestination(
            _parseDestinationFromRecord(driverData),
            const DriverPayoutDestination.empty(),
          ),
        ),
      ),
      hasLiveBackendData: false,
      businessManagedWithdrawalsBlocked:
          businessManagedWithdrawalsBlockedFromDriverData(driverData),
    );
  }

  Map<String, dynamic> _mergeMaps(
    Map<String, dynamic> primary,
    Map<String, dynamic> secondary,
  ) {
    return <String, dynamic>{...primary, ...secondary};
  }

  Map<String, dynamic> _mergeRecordCollections(
    Map<String, dynamic> primary,
    Map<String, dynamic> secondary,
  ) {
    return <String, dynamic>{...primary, ...secondary};
  }

  Map<String, dynamic> _recordCollectionMap(dynamic value) {
    if (value is List) {
      final records = <String, dynamic>{};
      for (var index = 0; index < value.length; index += 1) {
        final record = _map(value[index]);
        if (record.isEmpty) {
          continue;
        }
        final recordId = _rideIdFromRecord(record, fallbackId: 'record_$index');
        records[recordId] = record;
      }
      return records;
    }
    return _map(value);
  }

  bool _isDriverWithdrawRequestRecord(
    Map<String, dynamic> rawRecord,
    String driverId,
  ) {
    final entityType =
        _text(rawRecord['entity_type'] ?? rawRecord['entityType']).toLowerCase();
    if (entityType.isNotEmpty && entityType != 'driver') {
      return false;
    }
    final rowDriver = _text(rawRecord['driver_id'] ?? rawRecord['driverId']);
    if (rowDriver.isNotEmpty && rowDriver != driverId) {
      return false;
    }
    return true;
  }

  List<DriverWithdrawalRecord> _buildWithdrawalRecords({
    required String driverId,
    required DriverPayoutDestination payoutDestination,
    required List<Map<String, dynamic>> rawCollections,
  }) {
    final withdrawalsById = <String, DriverWithdrawalRecord>{};

    for (final collection in rawCollections) {
      for (final entry in _recordEntries(collection)) {
        final rawRecord = entry.value;
        if (!_isDriverWithdrawRequestRecord(rawRecord, driverId)) {
          continue;
        }
        final amount = _firstPositiveDouble(<dynamic>[
          rawRecord['requested_amount'],
          rawRecord['requestedAmount'],
          rawRecord['amount_ngn'],
          rawRecord['amountNgn'],
          rawRecord['amount'],
        ]);
        if (amount <= 0) {
          continue;
        }

        final destination = _resolvePayoutDestination(
          _parseDestinationFromRecord(rawRecord),
          payoutDestination,
        );
        final id = _text(rawRecord['withdrawalId']).isNotEmpty
            ? _text(rawRecord['withdrawalId'])
            : entry.key;
        withdrawalsById[id] = DriverWithdrawalRecord(
          id: id,
          amount: amount,
          requestDate: _dateFromCandidates(<dynamic>[
            rawRecord['requestedAt'],
            rawRecord['requestDate'],
            rawRecord['request_date'],
            rawRecord['timestamp'],
            rawRecord['createdAt'],
            rawRecord['created_at'],
          ]),
          processedDate: _dateFromCandidates(<dynamic>[
            rawRecord['processedAt'],
            rawRecord['processed_at'],
            rawRecord['paidAt'],
            rawRecord['paid_at'],
            rawRecord['completedAt'],
            rawRecord['updatedAt'],
            rawRecord['updated_at'],
          ]),
          status: driverWithdrawalStatusFromRtdb(_text(rawRecord['status'])),
          payoutReference: _firstText(<dynamic>[
            rawRecord['payoutReference'],
            rawRecord['payout_reference'],
            rawRecord['reference'],
            rawRecord['transactionReference'],
            rawRecord['transaction_reference'],
          ]),
          destination: destination,
        );
        debugPrint(
          'DRIVER_WITHDRAWAL_ROW_STATUS '
          'driverId=$driverId '
          'withdrawalId=$id '
          'status=${_text(rawRecord['status'])} '
          'amount=$amount',
        );
      }
    }

    final withdrawals = withdrawalsById.values.toList()
      ..sort(
        (DriverWithdrawalRecord a, DriverWithdrawalRecord b) =>
            (b.requestDate?.millisecondsSinceEpoch ?? 0)
                .compareTo(a.requestDate?.millisecondsSinceEpoch ?? 0),
      );
    return withdrawals;
  }

  DriverEarningRecord? _earningFromRecord({
    required Map<String, dynamic> rawRecord,
    required Map<String, dynamic> rideData,
    required String recordId,
    required Map<String, dynamic> businessModel,
    required bool Function(String rideId) rideWalletCredited,
  }) {
    final rawSettlement = _map(rawRecord['settlement']);
    final rideSettlement = _map(rideData['settlement']);
    final ridePricingSnapshot = _map(
      rideData['pricing_snapshot'] ?? rideData['pricingSnapshot'],
    );
    final ridePaymentPlaceholder = _map(
      rideData['payment_placeholder'] ?? rideData['paymentPlaceholder'],
    );
    final settlementContext =
        rawSettlement.isNotEmpty ? rawSettlement : rideSettlement;
    final settlementBusinessModel = _map(
      settlementContext['businessModelSnapshot'],
    );
    final rawRecordBusinessModel = _map(rawRecord['businessModel']);
    final effectiveBusinessModel = settlementBusinessModel.isNotEmpty
        ? settlementBusinessModel
        : (rawRecordBusinessModel.isNotEmpty
            ? rawRecordBusinessModel
            : businessModel);
    final grossFare = _firstPositiveDouble(<dynamic>[
      ridePricingSnapshot['fareEstimateNgn'],
      ridePricingSnapshot['fareEstimate'],
      ridePricingSnapshot['fare_estimate_ngn'],
      ridePricingSnapshot['fare_estimate'],
      settlementContext['grossFareNgn'],
      settlementContext['grossFare'],
      rawRecord['grossFare'],
      rawRecord['gross_fare'],
      rawRecord['fareEstimateNgn'],
      rawRecord['fareEstimate'],
      rawRecord['fare_estimate_ngn'],
      rawRecord['fare_estimate'],
      rawRecord['fare'],
      rideData['fareEstimateNgn'],
      rideData['fareEstimate'],
      rideData['fare_estimate_ngn'],
      rideData['fare_estimate'],
      rideData['grossFare'],
      rideData['fare'],
    ]);

    if (grossFare <= 0) {
      return null;
    }

    final settlement = calculateDriverTripSettlement(
      grossFare: grossFare,
      businessModel: effectiveBusinessModel,
    );
    final explicitCommission = _firstAvailableDoubleOrNull(<dynamic>[
      settlementContext['commissionAmountNgn'],
      settlementContext['commissionAmount'],
      settlementContext['commission'],
      rawRecord['commission'],
      rawRecord['commissionAmount'],
      rawRecord['commission_amount'],
      rideData['commission'],
      rideData['commissionAmount'],
      rideData['commission_amount'],
    ]);
    final isSubscriptionModel = settlement.appliedModel == 'subscription';
    final commission = isSubscriptionModel
        ? 0.0
        : (explicitCommission ?? settlement.commissionAmount);

    final explicitNet = _firstAvailableDoubleOrNull(<dynamic>[
      settlementContext['driverPayoutNgn'],
      settlementContext['driverPayout'],
      settlementContext['netEarningNgn'],
      settlementContext['netEarning'],
      rawRecord['netEarning'],
      rawRecord['net_earning'],
      rawRecord['netAmount'],
      rawRecord['driverPayout'],
      rawRecord['driver_payout'],
      rideData['netEarning'],
      rideData['driverPayout'],
    ]);
    final netEarning = isSubscriptionModel
        ? grossFare
        : (explicitNet ?? (grossFare - commission < 0 ? 0.0 : grossFare - commission));

    final settlementStatus = _normalizedSettlementStatus(
      _firstText(<dynamic>[
        settlementContext['settlementStatus'],
        rawRecord['settlementStatus'],
        rawRecord['status'],
        rideData['settlementStatus'],
        rideData['status'],
      ]),
    );
    final resolvedRideId = _rideIdFromRecord(rawRecord, fallbackId: recordId);
    final walletCreditConfirmed = rideWalletCredited(resolvedRideId);
    final explicitCountsTowardWallet =
        _boolOrNull(rawRecord['countsTowardWallet']) ??
            _boolOrNull(settlementContext['countsTowardWallet']);
    final countsTowardWallet =
        driverSettlementCountsTowardWallet(settlementStatus) &&
            walletCreditConfirmed &&
            (explicitCountsTowardWallet ?? true);
    final displaySettlementStatus =
        driverSettlementCountsTowardWallet(settlementStatus) && !walletCreditConfirmed
            ? 'wallet_pending'
            : settlementStatus;

    return DriverEarningRecord(
      id: recordId,
      rideId: _rideIdFromRecord(rawRecord, fallbackId: recordId),
      tripDate: _dateFromCandidates(<dynamic>[
        rideData['completed_at'],
        rideData['trip_completed_at'],
        rawRecord['completedAt'],
        rawRecord['completed_at'],
        rawRecord['updatedAt'],
        rawRecord['createdAt'],
        rideData['timestamp'],
      ]),
      pickupSummary: _firstText(<dynamic>[
        rideData['pickup_address'],
        rawRecord['pickup_address'],
        rawRecord['pickupAddress'],
      ]),
      destinationSummary: _firstText(<dynamic>[
        rideData['destination_address'],
        rideData['final_destination_address'],
        rawRecord['destination_address'],
        rawRecord['final_destination_address'],
        rawRecord['destinationAddress'],
      ]),
      grossFare: grossFare,
      commission: commission,
      netEarning: netEarning,
      paymentMethod: _paymentMethodLabel(
        _firstText(<dynamic>[
          rawRecord['paymentMethod'],
          rawRecord['payment_method'],
          rideData['payment_method'],
          rideData['paymentMethod'],
          ridePaymentPlaceholder['method'],
          ridePaymentPlaceholder['provider'],
          ridePaymentPlaceholder['status'],
          _map(rideData['payment_context'])['method'],
          _map(rideData['settlement'])['paymentMethod'],
        ]),
      ),
      settlementStatus: displaySettlementStatus,
      countsTowardWallet: countsTowardWallet,
    );
  }

  DriverPayoutDestination _parseDestinationFromRecord(
    Map<String, dynamic> record,
  ) {
    final candidateMaps = <Map<String, dynamic>>[
      record,
      _map(record['destination']),
      _map(record['bankDetails']),
      _map(record['bank_details']),
      _map(record['payoutDestination']),
      _map(record['payout_destination']),
      _map(record['payoutAccount']),
      _map(record['payout_account']),
      _map(record['withdrawalAccount']),
      _map(record['withdrawal_account']),
      _map(record['withdrawal_destination_snapshot']),
      _map(record['withdrawalDestinationSnapshot']),
      _map(record['settlementAccount']),
      _map(record['settlement_account']),
      _map(record['bankAccount']),
      _map(record['bank_account']),
      _map(record['account']),
    ];

    return DriverPayoutDestination(
      bankName: _firstMappedText(
        candidateMaps,
        <String>['bankName', 'bank_name', 'bank'],
      ),
      accountName: _firstMappedText(
        candidateMaps,
        <String>[
          'accountName',
          'account_name',
          'account_holder_name',
          'accountHolderName',
          'beneficiaryName',
          'beneficiary_name',
          'holderName',
          'holder_name',
          'recipientName',
          'recipient_name',
        ],
      ),
      accountNumber: _firstMappedText(
        candidateMaps,
        <String>['accountNumber', 'account_number', 'accountNo', 'account_no'],
      ),
      bankCode: _firstMappedText(
        candidateMaps,
        <String>['bankCode', 'bank_code', 'account_bank', 'accountBank'],
      ),
    );
  }

  DriverPayoutDestination _resolvePayoutDestination(
    DriverPayoutDestination primary,
    DriverPayoutDestination fallback,
  ) {
    return DriverPayoutDestination(
      bankName:
          primary.bankName.isNotEmpty ? primary.bankName : fallback.bankName,
      accountName: primary.accountName.isNotEmpty
          ? primary.accountName
          : fallback.accountName,
      accountNumber: primary.accountNumber.isNotEmpty
          ? primary.accountNumber
          : fallback.accountNumber,
      bankCode: primary.bankCode.isNotEmpty ? primary.bankCode : fallback.bankCode,
    );
  }

  Map<String, dynamic> _legacyEarningRecordMap(Map<String, dynamic> data) {
    if (data.isEmpty) {
      return const <String, dynamic>{};
    }

    final candidates = <Map<String, dynamic>>[
      _map(data['records']),
      _map(data['history']),
      _map(data['trips']),
      _map(data['earnings']),
    ];

    for (final candidate in candidates) {
      if (candidate.isNotEmpty) {
        return candidate;
      }
    }
    return const <String, dynamic>{};
  }

  List<MapEntry<String, Map<String, dynamic>>> _recordEntries(
    Map<String, dynamic> data,
  ) {
    if (data.isEmpty) {
      return const <MapEntry<String, Map<String, dynamic>>>[];
    }

    if (_looksLikeSingleRecord(data)) {
      return <MapEntry<String, Map<String, dynamic>>>[
        MapEntry<String, Map<String, dynamic>>(
          _rideIdFromRecord(data, fallbackId: 'record'),
          data,
        ),
      ];
    }

    return data.entries
        .where((MapEntry<String, dynamic> entry) => entry.value is Map)
        .map(
          (MapEntry<String, dynamic> entry) =>
              MapEntry<String, Map<String, dynamic>>(
            entry.key,
            _map(entry.value),
          ),
        )
        .toList(growable: false);
  }

  bool _looksLikeSingleRecord(Map<String, dynamic> data) {
    const signatureKeys = <String>{
      'amount',
      'status',
      'fare',
      'grossFare',
      'requestedAt',
      'timestamp',
      'withdrawalId',
      'rideId',
      'ride_id',
      'driverId',
      'driver_id',
    };
    return data.keys.any(signatureKeys.contains);
  }

  String _rideIdFromRecord(
    Map<String, dynamic> record, {
    required String fallbackId,
  }) {
    final rideId = _firstText(<dynamic>[
      record['rideId'],
      record['ride_id'],
      record['tripReference'],
      record['trip_reference'],
      fallbackId,
    ]);
    return rideId;
  }

  String _normalizedSettlementStatus(String value) {
    final normalized = value.trim().toLowerCase();
    if (normalized == 'completed' || normalized == 'trip_completed') {
      return 'completed';
    }
    if (normalized == 'reversed' ||
        normalized == 'reversal' ||
        normalized == 'trip_reversed') {
      return 'reversed';
    }
    if (normalized.isEmpty ||
        normalized == 'none' ||
        normalized == 'not_applicable' ||
        normalized == 'cancelled' ||
        normalized == 'canceled') {
      return 'none';
    }
    if (normalized == 'payment_review') {
      return 'payment_review';
    }
    if (normalized == 'failed') {
      return 'failed';
    }
    return normalized;
  }

  DateTime? _dateFromCandidates(List<dynamic> candidates) {
    for (final candidate in candidates) {
      final date = _dateFromValue(candidate);
      if (date != null) {
        return date;
      }
    }
    return null;
  }

  DateTime? _dateFromValue(dynamic value) {
    if (value == null) {
      return null;
    }
    if (value is int) {
      return DateTime.fromMillisecondsSinceEpoch(value).toLocal();
    }
    if (value is double) {
      return DateTime.fromMillisecondsSinceEpoch(value.round()).toLocal();
    }
    final parsedInt = int.tryParse(value.toString());
    if (parsedInt != null) {
      return DateTime.fromMillisecondsSinceEpoch(parsedInt).toLocal();
    }
    return DateTime.tryParse(value.toString())?.toLocal();
  }

  double _firstPositiveDouble(List<dynamic> candidates) {
    for (final candidate in candidates) {
      final value = _doubleOrNull(candidate);
      if (value != null && value > 0) {
        return value;
      }
    }
    return 0;
  }

  double? _firstAvailableDoubleOrNull(List<dynamic> candidates) {
    for (final candidate in candidates) {
      if (candidate == null) {
        continue;
      }
      if (candidate is String && candidate.trim().isEmpty) {
        continue;
      }
      final value = _doubleOrNull(candidate);
      if (value != null) {
        return value;
      }
    }
    return null;
  }

  String _firstText(List<dynamic> candidates) {
    for (final candidate in candidates) {
      final value = _text(candidate);
      if (value.isNotEmpty) {
        return value;
      }
    }
    return '';
  }

  String _firstMappedText(
    List<Map<String, dynamic>> maps,
    List<String> keys,
  ) {
    for (final map in maps) {
      for (final key in keys) {
        final value = _text(map[key]);
        if (value.isNotEmpty) {
          return value;
        }
      }
    }
    return '';
  }

  double? _doubleOrNull(dynamic value) {
    if (value is double) {
      return value;
    }
    if (value is int) {
      return value.toDouble();
    }
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '');
  }

  bool? _boolOrNull(dynamic value) {
    if (value is bool) {
      return value;
    }
    final normalized = value?.toString().trim().toLowerCase();
    if (normalized == 'true' || normalized == '1' || normalized == 'yes') {
      return true;
    }
    if (normalized == 'false' || normalized == '0' || normalized == 'no') {
      return false;
    }
    return null;
  }

  Map<String, dynamic> _map(dynamic value) {
    if (value is Map) {
      return value.map<String, dynamic>(
        (dynamic key, dynamic entryValue) =>
            MapEntry<String, dynamic>(key.toString(), entryValue),
      );
    }
    return <String, dynamic>{};
  }

  String _text(dynamic value) {
    if (value == null || value is Map || value is List) {
      return '';
    }
    return value.toString().trim();
  }

  String _titleCase(String value) {
    if (value.isEmpty) {
      return value;
    }
    final cleaned = value.replaceAll('_', ' ');
    return cleaned
        .split(' ')
        .where((String part) => part.isNotEmpty)
        .map(
          (String part) =>
              '${part[0].toUpperCase()}${part.substring(1).toLowerCase()}',
        )
        .join(' ');
  }

  String _paymentMethodLabel(String value) {
    return switch (value.trim().toLowerCase()) {
      'cash' => 'In-app',
      'card' => 'Card',
      'flutterwave' => 'Flutterwave',
      'bank_transfer' => 'Bank transfer',
      '' || 'unspecified' => 'Unspecified',
      _ => _titleCase(value),
    };
  }

  static String formatNaira(double amount) {
    final absolute = amount.abs();
    final isWholeNumber = absolute.truncateToDouble() == absolute;
    final base = isWholeNumber
        ? absolute.toStringAsFixed(0)
        : absolute.toStringAsFixed(2);
    final parts = base.split('.');
    final wholeDigits = parts.first;
    final formattedWhole = _formatWholeNumberWithCommas(wholeDigits);
    final decimalPart = parts.length > 1 ? '.${parts[1]}' : '';
    return '${amount < 0 ? '-' : ''}₦$formattedWhole$decimalPart';
  }

  static String formatDate(DateTime? date) {
    if (date == null) {
      return 'Date unavailable';
    }
    const months = <String>[
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
    ];
    return '${date.day} ${months[date.month - 1]} ${date.year}';
  }

  static String formatDateTime(DateTime? date) {
    if (date == null) {
      return 'Date unavailable';
    }
    final hour = date.hour == 0
        ? 12
        : date.hour > 12
            ? date.hour - 12
            : date.hour;
    final minute = date.minute.toString().padLeft(2, '0');
    final suffix = date.hour >= 12 ? 'PM' : 'AM';
    return '${formatDate(date)} - $hour:$minute $suffix';
  }

  static String _formatWholeNumberWithCommas(String digits) {
    if (digits.length <= 3) {
      return digits;
    }

    final buffer = StringBuffer();
    for (var index = 0; index < digits.length; index++) {
      final reverseIndex = digits.length - index;
      buffer.write(digits[index]);
      if (reverseIndex > 1 && reverseIndex % 3 == 1) {
        buffer.write(',');
      }
    }
    return buffer.toString();
  }
}

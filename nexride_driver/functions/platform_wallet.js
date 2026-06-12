/**
 * Platform revenue wallet helpers.
 *
 * Production settlement SSOT (read-only for admin finance display):
 *   `wallets/nexride_platform` + `wallets/nexride_platform/transactions`
 *
 * Future write/debit SSOT (not populated in production yet):
 *   `platform_wallet` + `platform_wallet/ledger`
 */

const adminPerms = require("./admin_permissions");
const { writeAdminAuditLog } = require("./admin_audit_log");
const {
  buildDriverWithdrawalDestinationRecord,
  trimBankCode,
} = require("./flutterwave_bank_codes");
const {
  canonicalizeSelectedBankFromFlutterwaveList,
  isFlutterwaveSelectedDestination,
  resolvePayoutAccountBank,
} = require("./flutterwave_bank_catalog");
const { withdrawalStatusReservesBalance } = require("./withdraw_flow");

const PLATFORM_PAYOUT_CONFIG_PATH = "app_config/platform_payout_destination";
const PLATFORM_WITHDRAW_ROOT = "platform_withdraw_requests";
/** Production settlement credits land here today (`creditPlatformRevenueWallet`). */
const PRODUCTION_PLATFORM_WALLET_UID = "nexride_platform";
const PRODUCTION_PLATFORM_WALLET_PATH = `wallets/${PRODUCTION_PLATFORM_WALLET_UID}`;
const PRODUCTION_PLATFORM_TRANSACTIONS_PATH = `${PRODUCTION_PLATFORM_WALLET_PATH}/transactions`;
const PLATFORM_WITHDRAWALS_DISABLED_REASON = "platform_wallet_migration_pending";
const PLATFORM_WITHDRAWALS_DISABLED_MESSAGE =
  "Platform withdrawals are disabled until platform_wallet migration is complete. " +
  "Finance balance is read from wallets/nexride_platform (production SSOT).";
const OFFICIAL_PLATFORM_PAYOUT_NOT_CONFIGURED_MSG =
  "Official NexRide payout account is not configured.";

function officialPlatformPayoutNotConfigured(reason = "platform_payout_destination_not_configured") {
  return {
    ok: false,
    reason,
    message: OFFICIAL_PLATFORM_PAYOUT_NOT_CONFIGURED_MSG,
  };
}

function blockedOfficialPlatformPayoutResponse(payoutDest) {
  return {
    success: false,
    reason: payoutDest?.reason || "platform_payout_destination_not_configured",
    message: payoutDest?.message || OFFICIAL_PLATFORM_PAYOUT_NOT_CONFIGURED_MSG,
  };
}

function normUid(v) {
  return String(v ?? "").trim();
}

function nowMs() {
  return Date.now();
}

function roundNgn(n) {
  return Math.round(Math.max(0, Number(n) || 0));
}

function digitsOnlyAccountNumber(v) {
  return String(v ?? "").replace(/\D/g, "");
}

function platformRevenueLedgerId(tripOrDeliveryId) {
  const id = normUid(tripOrDeliveryId);
  return id ? `platform_revenue_${id}` : "";
}

async function enforceSuperAdminOnly(db, context, callableName) {
  const deny = await adminPerms.enforceCallable(db, context, callableName);
  if (deny) return deny;
  const role = await adminPerms.resolveEffectiveAdminRole(db, context);
  if (role !== "super_admin") {
    return {
      success: false,
      reason: "forbidden",
      reason_code: "super_admin_required",
      required_role: "super_admin",
    };
  }
  return null;
}

function isProductionPlatformCreditTransaction(row) {
  if (!row || typeof row !== "object") return false;
  const direction = String(row.direction ?? "").trim().toLowerCase();
  if (direction === "debit") return false;
  const type = String(row.type ?? "").trim().toLowerCase();
  if (!type) return roundNgn(row.amount) > 0;
  if (
    type === "withdrawal_paid" ||
    type === "platform_withdrawal_paid" ||
    type === "platform_fee_debit" ||
    type === "rider_payment_debit"
  ) {
    return false;
  }
  return true;
}

function isProductionPlatformWithdrawalDebit(row) {
  if (!row || typeof row !== "object") return false;
  const direction = String(row.direction ?? "").trim().toLowerCase();
  const type = String(row.type ?? "").trim().toLowerCase();
  if (direction === "debit") return true;
  return type === "withdrawal_paid" || type === "platform_withdrawal_paid";
}

function classifyProductionPlatformRevenueType(typeRaw) {
  const type = String(typeRaw ?? "").trim().toLowerCase();
  if (type === "booking_fee_revenue") return "booking_fee_revenue";
  if (type === "commission_revenue") return "commission_revenue";
  if (type === "subscription_revenue") return "subscription_revenue";
  if (
    type === "withdrawal_fee_revenue" ||
    type === "withdrawal_fee" ||
    type.includes("withdrawal_fee")
  ) {
    return "withdrawal_fee_revenue";
  }
  return "other_revenue";
}

function aggregateProductionPlatformTransactions(transactions) {
  const txMap =
    transactions && typeof transactions === "object" ? transactions : {};
  let totalRevenue = 0;
  let totalWithdrawn = 0;
  let totalCommission = 0;
  let totalBookingFee = 0;
  let totalSubscription = 0;
  let totalWithdrawalFee = 0;
  let latestUpdatedAt = 0;

  for (const row of Object.values(txMap)) {
    if (!row || typeof row !== "object") continue;
    const amount = roundNgn(row.amount);
    const createdAt = Number(row.created_at ?? row.updated_at ?? 0) || 0;
    if (createdAt > latestUpdatedAt) latestUpdatedAt = createdAt;

    if (isProductionPlatformWithdrawalDebit(row)) {
      totalWithdrawn += amount;
      continue;
    }
    if (!isProductionPlatformCreditTransaction(row) || amount <= 0) continue;

    totalRevenue += amount;
    const bucket = classifyProductionPlatformRevenueType(row.type);
    if (bucket === "booking_fee_revenue") totalBookingFee += amount;
    else if (bucket === "commission_revenue") totalCommission += amount;
    else if (bucket === "subscription_revenue") totalSubscription += amount;
    else if (bucket === "withdrawal_fee_revenue") totalWithdrawalFee += amount;
  }

  return {
    total_revenue: totalRevenue,
    total_withdrawn: totalWithdrawn,
    total_commission_revenue: totalCommission,
    total_booking_fee_revenue: totalBookingFee,
    total_subscription_revenue: totalSubscription,
    total_withdrawal_fee_revenue: totalWithdrawalFee,
    total_gross_bookings: 0,
    updated_at: latestUpdatedAt,
  };
}

function mapProductionTransactionToLedgerRow(id, row) {
  if (!row || typeof row !== "object") return null;
  const type = String(row.type ?? "").trim();
  const amount = roundNgn(row.amount);
  const bucket = classifyProductionPlatformRevenueType(type);
  const createdAt = Number(row.created_at ?? row.updated_at ?? 0) || 0;
  return {
    id: String(id ?? "").trim(),
    type: type || "platform_revenue_credit",
    amount,
    platform_total: amount,
    commission_amount: bucket === "commission_revenue" ? amount : 0,
    booking_fee_amount: bucket === "booking_fee_revenue" ? amount : 0,
    subscription_amount: bucket === "subscription_revenue" ? amount : 0,
    withdrawal_fee_amount: bucket === "withdrawal_fee_revenue" ? amount : 0,
    direction: String(row.direction ?? "").trim() || null,
    transaction_id: String(row.transactionId ?? id ?? "").trim() || null,
    source_store: PRODUCTION_PLATFORM_TRANSACTIONS_PATH,
    created_at: createdAt,
    completed: true,
  };
}

/**
 * Admin finance display SSOT — production settlement wallet (read-only).
 * @param {import("firebase-admin/database").Database} db
 */
async function readProductionPlatformWalletDisplayState(db) {
  const snap = await db.ref(PRODUCTION_PLATFORM_WALLET_PATH).get();
  const w = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
  const balance = roundNgn(w.balance);
  const aggregates = aggregateProductionPlatformTransactions(w.transactions);
  return {
    balance,
    total_revenue: aggregates.total_revenue,
    total_withdrawn: aggregates.total_withdrawn,
    total_commission_revenue: aggregates.total_commission_revenue,
    total_booking_fee_revenue: aggregates.total_booking_fee_revenue,
    total_subscription_revenue: aggregates.total_subscription_revenue,
    total_withdrawal_fee_revenue: aggregates.total_withdrawal_fee_revenue,
    total_gross_bookings: aggregates.total_gross_bookings,
    updated_at: Number(w.updated_at ?? aggregates.updated_at ?? 0) || 0,
    balance_ssot_path: PRODUCTION_PLATFORM_WALLET_PATH,
    transactions_ssot_path: PRODUCTION_PLATFORM_TRANSACTIONS_PATH,
  };
}

/**
 * Future platform_wallet node (write/debit path — empty in production today).
 * @param {import("firebase-admin/database").Database} db
 */
async function readPlatformWalletState(db) {
  const snap = await db.ref("platform_wallet").get();
  const w = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
  const balance = roundNgn(w.balance);
  const totalRevenue = roundNgn(w.total_revenue);
  const totalWithdrawn = roundNgn(w.total_withdrawn);
  const totalCommission = roundNgn(w.total_commission_revenue ?? w.total_commission);
  const totalBookingFee = roundNgn(w.total_booking_fee_revenue ?? w.total_booking_fee);
  const totalSubscription = roundNgn(w.total_subscription_revenue);
  const totalGrossBookings = roundNgn(w.total_gross_bookings);
  return {
    balance,
    total_revenue: totalRevenue,
    total_withdrawn: totalWithdrawn,
    total_commission_revenue: totalCommission,
    total_booking_fee_revenue: totalBookingFee,
    total_subscription_revenue: totalSubscription,
    total_gross_bookings: totalGrossBookings,
    updated_at: Number(w.updated_at ?? 0) || 0,
  };
}

async function listProductionPlatformWalletTransactions(db, limit) {
  const snap = await db.ref(PRODUCTION_PLATFORM_TRANSACTIONS_PATH).orderByKey().limitToLast(limit).get();
  const val = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
  return Object.entries(val)
    .map(([id, row]) => mapProductionTransactionToLedgerRow(id, row))
    .filter(Boolean)
    .sort((a, b) => (Number(b.created_at) || 0) - (Number(a.created_at) || 0));
}

async function sumReservedPlatformWithdrawalAmountNgn(db, excludeWithdrawalId = "") {
  const excludeId = normUid(excludeWithdrawalId);
  const snap = await db.ref(PLATFORM_WITHDRAW_ROOT).get();
  const all = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
  let sum = 0;
  for (const [wid, row] of Object.entries(all)) {
    if (!row || typeof row !== "object") continue;
    const withdrawalId = normUid(row.withdrawalId ?? row.withdrawal_id ?? wid);
    if (excludeId && withdrawalId === excludeId) continue;
    if (!withdrawalStatusReservesBalance(row.status)) continue;
    sum += roundNgn(row.amount ?? row.amount_ngn ?? row.requested_amount);
  }
  return sum;
}

function computeAvailablePlatformBalanceNgn(balance, reserved) {
  return Math.max(0, roundNgn(balance) - roundNgn(reserved));
}

/**
 * Idempotent platform revenue credit (commission + booking fee + optional buckets).
 * @param {import("firebase-admin/database").Database} db
 */
async function creditPlatformRevenueOnce(db, params = {}) {
  const ledgerId =
    String(params.ledgerId ?? "").trim() ||
    platformRevenueLedgerId(params.tripId ?? params.deliveryId);
  const tripId = normUid(params.tripId) || null;
  const deliveryId = normUid(params.deliveryId) || null;
  const commissionAmount = roundNgn(params.commissionAmount ?? params.commission_amount);
  const bookingFeeAmount = roundNgn(params.bookingFeeAmount ?? params.booking_fee_amount);
  const subscriptionAmount = roundNgn(params.subscriptionAmount ?? params.subscription_amount);
  const waitFeeAmount = roundNgn(params.waitFeeAmount ?? params.wait_fee_amount);
  const otherAmount = roundNgn(params.otherAmount ?? params.other_amount);
  const grossAmount = roundNgn(params.grossAmount ?? params.gross_amount);
  const driverPayout = roundNgn(params.driverPayout ?? params.driver_payout);
  const fleetPayout = roundNgn(params.fleetPayout ?? params.fleet_payout);
  const platformTotal =
    commissionAmount + bookingFeeAmount + subscriptionAmount + waitFeeAmount + otherAmount;

  if (!ledgerId) {
    return { success: false, reason: "invalid_ledger_id" };
  }
  if (platformTotal <= 0) {
    return { success: true, reason: "skipped_zero", idempotent: true, ledger_id: ledgerId };
  }

  const ledgerRef = db.ref(`platform_wallet/ledger/${ledgerId}`);
  let ledgerReason = "unknown";
  const settledAt = nowMs();
  const ledgerRow = {
    type: "platform_revenue_credit",
    ledger_id: ledgerId,
    trip_id: tripId,
    delivery_id: deliveryId,
    gross_amount: grossAmount,
    driver_payout: driverPayout,
    fleet_payout: fleetPayout,
    commission_amount: commissionAmount,
    booking_fee_amount: bookingFeeAmount,
    subscription_amount: subscriptionAmount,
    wait_fee_amount: waitFeeAmount,
    other_amount: otherAmount,
    platform_total: platformTotal,
    source: String(params.source ?? "").trim() || null,
    revenue_kind: String(params.revenueKind ?? params.revenue_kind ?? "").trim() || null,
    currency: String(params.currency ?? "NGN").trim().toUpperCase() || "NGN",
    created_at: settledAt,
    completed: true,
  };

  const ledgerTx = await ledgerRef.transaction((cur) => {
    if (cur && typeof cur === "object" && cur.completed === true) {
      ledgerReason = "already_applied";
      return;
    }
    if (cur != null && cur !== undefined && !(cur && cur.completed === true)) {
      ledgerReason = "ledger_key_conflict";
      return;
    }
    return ledgerRow;
  });

  if (!ledgerTx.committed) {
    if (ledgerReason === "already_applied") {
      console.log(
        "PLATFORM_REVENUE_ALREADY_CREDITED",
        `ledgerId=${ledgerId}`,
        `tripId=${tripId || ""}`,
        `deliveryId=${deliveryId || ""}`,
      );
      return {
        success: true,
        reason: "already_applied",
        idempotent: true,
        ledger_id: ledgerId,
      };
    }
    return { success: false, reason: ledgerReason, ledger_id: ledgerId };
  }

  const walletRef = db.ref("platform_wallet");
  let walletReason = "unknown";
  const walletTx = await walletRef.transaction((cur) => {
    const w = cur && typeof cur === "object" ? cur : {};
    const applied =
      w.applied_revenue_keys && typeof w.applied_revenue_keys === "object"
        ? w.applied_revenue_keys
        : {};
    if (applied[ledgerId] === true) {
      walletReason = "already_applied";
      return;
    }
    const nextApplied = { ...applied, [ledgerId]: true };
    return {
      ...w,
      balance: roundNgn(w.balance) + platformTotal,
      total_revenue: roundNgn(w.total_revenue) + platformTotal,
      total_commission_revenue: roundNgn(w.total_commission_revenue) + commissionAmount,
      total_booking_fee_revenue: roundNgn(w.total_booking_fee_revenue) + bookingFeeAmount,
      total_subscription_revenue: roundNgn(w.total_subscription_revenue) + subscriptionAmount,
      total_gross_bookings: roundNgn(w.total_gross_bookings) + (grossAmount > 0 ? grossAmount : 0),
      applied_revenue_keys: nextApplied,
      updated_at: settledAt,
    };
  });

  if (!walletTx.committed) {
    if (walletReason === "already_applied") {
      console.log(
        "PLATFORM_REVENUE_ALREADY_CREDITED",
        `ledgerId=${ledgerId}`,
        "note=wallet_applied_keys",
      );
      return {
        success: true,
        reason: "already_applied",
        idempotent: true,
        ledger_id: ledgerId,
      };
    }
    return { success: false, reason: walletReason, ledger_id: ledgerId };
  }

  console.log(
    "PLATFORM_REVENUE_CREDITED",
    `ledgerId=${ledgerId}`,
    `tripId=${tripId || ""}`,
    `deliveryId=${deliveryId || ""}`,
    `commission=${commissionAmount}`,
    `booking_fee=${bookingFeeAmount}`,
    `subscription=${subscriptionAmount}`,
    `wait_fee=${waitFeeAmount}`,
    `platform_total=${platformTotal}`,
    `gross=${grossAmount}`,
    `driver_payout=${driverPayout}`,
    `fleet_payout=${fleetPayout}`,
  );

  return {
    success: true,
    reason: "credited",
    idempotent: false,
    ledger_id: ledgerId,
    platform_total: platformTotal,
  };
}

async function readPlatformPayoutDestination(db) {
  const snap = await db.ref(PLATFORM_PAYOUT_CONFIG_PATH).get();
  const dest = snap.val() && typeof snap.val() === "object" ? snap.val() : null;
  if (!dest) {
    return officialPlatformPayoutNotConfigured("platform_payout_destination_missing");
  }
  if (dest.selected_from_flutterwave_list !== true) {
    return officialPlatformPayoutNotConfigured("platform_payout_not_from_flutterwave_list");
  }
  const account_bank = trimBankCode(
    dest.account_bank ?? dest.bank_code ?? dest.accountBank ?? dest.bankCode,
  );
  const account_number = digitsOnlyAccountNumber(dest.account_number ?? dest.accountNumber);
  const account_name = String(
    dest.account_name ?? dest.account_holder_name ?? dest.accountName ?? "",
  ).trim();
  const bank_name = String(dest.bank_name ?? dest.bankName ?? "").trim();
  if (!/^\d{3,6}$/.test(account_bank)) {
    return officialPlatformPayoutNotConfigured("bank_code_required");
  }
  if (!account_number || account_number.length < 8) {
    return officialPlatformPayoutNotConfigured("invalid_account_number");
  }
  if (!account_name) {
    return officialPlatformPayoutNotConfigured("invalid_account_name");
  }
  return {
    ok: true,
    destination: {
      bank_name,
      bank_code: account_bank,
      account_bank,
      account_number,
      account_holder_name: account_name,
      account_name,
      selected_from_flutterwave_list: true,
    },
  };
}

async function adminGetPlatformPayoutDestination(data, context, db) {
  const deny = await adminPerms.enforceCallable(db, context, "adminGetPlatformPayoutDestination");
  if (deny) return deny;

  const payoutDest = await readPlatformPayoutDestination(db);
  if (!payoutDest.ok) {
    return {
      success: true,
      configured: false,
      reason: payoutDest.reason,
      message: payoutDest.message || OFFICIAL_PLATFORM_PAYOUT_NOT_CONFIGURED_MSG,
      destination: null,
    };
  }
  return {
    success: true,
    configured: true,
    destination: payoutDest.destination,
  };
}

async function adminListFlutterwavePayoutBanks(data, context, db) {
  const deny = await adminPerms.enforceCallable(db, context, "adminListFlutterwavePayoutBanks");
  if (deny) return deny;

  const { listNigeriaFlutterwaveBanks } = require("./flutterwave_api");
  const listed = await listNigeriaFlutterwaveBanks();
  if (!listed.ok || !Array.isArray(listed.banks)) {
    return { success: false, reason: listed.reason || "banks_unavailable" };
  }
  const banks = listed.banks
    .map((row) => {
      const code = trimBankCode(row.code ?? row.bank_code ?? row.account_bank ?? row.id);
      const name = String(row.name ?? row.bank_name ?? "").trim();
      if (!/^\d{3,6}$/.test(code) || !name) return null;
      return { code, name, bank_code: code, account_bank: code, bank_name: name };
    })
    .filter(Boolean);
  return { success: true, banks, source: listed.source || "flutterwave_api" };
}

async function adminSavePlatformPayoutDestination(data, context, db) {
  const deny = await enforceSuperAdminOnly(db, context, "adminSavePlatformPayoutDestination");
  if (deny) return deny;

  const { validateDriverWithdrawalDestinationInput } = require("./withdraw_flow");
  const v = validateDriverWithdrawalDestinationInput(data);
  if (!v.ok) {
    return { success: false, reason: v.reason };
  }

  const { listNigeriaFlutterwaveBanks } = require("./flutterwave_api");
  const listed = await listNigeriaFlutterwaveBanks();
  if (!listed.ok || !Array.isArray(listed.banks) || listed.banks.length === 0) {
    return { success: false, reason: "banks_unavailable" };
  }

  const selected = canonicalizeSelectedBankFromFlutterwaveList(v.value, listed.banks);
  if (!selected.ok) {
    return { success: false, reason: selected.reason };
  }

  const now = nowMs();
  const adminUid = normUid(context.auth.uid);
  const payload = {
    bank_name: selected.bank.name,
    bank_code: selected.bank.code,
    account_bank: selected.bank.code,
    account_number: v.value.account_number,
    account_name: v.value.account_holder_name,
    account_holder_name: v.value.account_holder_name,
    selected_from_flutterwave_list: true,
    flutterwave_banks_source: listed.source || "flutterwave_api",
    updated_at: now,
    updated_by_admin_uid: adminUid,
  };

  await db.ref(PLATFORM_PAYOUT_CONFIG_PATH).set(payload);

  console.log(
    "PLATFORM_PAYOUT_DESTINATION_SAVED",
    `adminUid=${adminUid}`,
    `bank_name=${payload.bank_name}`,
    `account_bank=${payload.account_bank}`,
  );

  return { success: true, destination: payload };
}

async function adminGetPlatformWalletSnapshot(data, context, db) {
  const deny = await adminPerms.enforceCallable(db, context, "adminGetPlatformWalletSnapshot");
  if (deny) return deny;

  const state = await readProductionPlatformWalletDisplayState(db);
  const reserved = await sumReservedPlatformWithdrawalAmountNgn(db);
  const available = computeAvailablePlatformBalanceNgn(state.balance, reserved);

  let pendingCount = 0;
  const snap = await db.ref(PLATFORM_WITHDRAW_ROOT).get();
  const all = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
  for (const row of Object.values(all)) {
    if (!row || typeof row !== "object") continue;
    if (!withdrawalStatusReservesBalance(row.status)) continue;
    pendingCount += 1;
  }

  const payoutDest = await readPlatformPayoutDestination(db);

  return {
    success: true,
    wallet: {
      balance: state.balance,
      available_balance: available,
      total_revenue: state.total_revenue,
      total_withdrawn: state.total_withdrawn,
      total_commission_revenue: state.total_commission_revenue,
      total_booking_fee_revenue: state.total_booking_fee_revenue,
      total_subscription_revenue: state.total_subscription_revenue,
      total_withdrawal_fee_revenue: state.total_withdrawal_fee_revenue ?? 0,
      total_gross_bookings: state.total_gross_bookings,
      pending_withdrawals_reserved: reserved,
      pending_withdrawals_count: pendingCount,
    },
    balance_ssot_path: state.balance_ssot_path,
    transactions_ssot_path: state.transactions_ssot_path,
    platform_withdrawals_enabled: false,
    platform_withdrawals_disabled_reason: PLATFORM_WITHDRAWALS_DISABLED_REASON,
    platform_withdrawals_message: PLATFORM_WITHDRAWALS_DISABLED_MESSAGE,
    payout_destination_configured: payoutDest.ok,
    payout_destination_reason: payoutDest.ok ? null : payoutDest.reason,
    payout_destination_message: payoutDest.ok
      ? null
      : payoutDest.message || OFFICIAL_PLATFORM_PAYOUT_NOT_CONFIGURED_MSG,
  };
}

async function adminListPlatformWalletLedger(data, context, db) {
  const deny = await adminPerms.enforceCallable(db, context, "adminListPlatformWalletLedger");
  if (deny) return deny;
  const limit = Math.min(200, Math.max(1, Number(data?.limit ?? 50) || 50));
  const rows = await listProductionPlatformWalletTransactions(db, limit);
  return {
    success: true,
    ledger: rows,
    count: rows.length,
    source_store: PRODUCTION_PLATFORM_TRANSACTIONS_PATH,
  };
}

async function requestPlatformWithdrawal(data, context, db) {
  const deny = await enforceSuperAdminOnly(db, context, "requestPlatformWithdrawal");
  if (deny) return deny;

  return {
    success: false,
    reason: "platform_withdrawals_disabled",
    reason_code: PLATFORM_WITHDRAWALS_DISABLED_REASON,
    message: PLATFORM_WITHDRAWALS_DISABLED_MESSAGE,
  };
}

async function debitPlatformWalletForWithdrawalPaid(db, { withdrawalId, amount }) {
  const wid = normUid(withdrawalId);
  const numericAmount = roundNgn(amount);
  const ledgerId = `platform_withdraw_paid_${wid}`;
  if (!wid || numericAmount <= 0) {
    return { success: false, reason: "invalid_input" };
  }

  const ledgerRef = db.ref(`platform_wallet/ledger/${ledgerId}`);
  let ledgerReason = "unknown";
  const ledgerTx = await ledgerRef.transaction((cur) => {
    if (cur && typeof cur === "object" && cur.completed === true) {
      ledgerReason = "already_applied";
      return;
    }
    if (cur != null && cur !== undefined) {
      ledgerReason = "ledger_key_conflict";
      return;
    }
    return {
      type: "platform_withdrawal_paid",
      withdrawal_id: wid,
      amount: numericAmount,
      completed: true,
      created_at: nowMs(),
    };
  });

  if (!ledgerTx.committed) {
    if (ledgerReason === "already_applied") {
      return { success: true, reason: "already_applied", idempotent: true, ledger_id: ledgerId };
    }
    return { success: false, reason: ledgerReason };
  }

  const walletRef = db.ref("platform_wallet");
  let failReason = "unknown";
  const tx = await walletRef.transaction((cur) => {
    const w = cur && typeof cur === "object" ? cur : {};
    const balance = roundNgn(w.balance);
    if (balance < numericAmount) {
      failReason = "insufficient_balance";
      return;
    }
    return {
      ...w,
      balance: balance - numericAmount,
      total_withdrawn: roundNgn(w.total_withdrawn) + numericAmount,
      updated_at: nowMs(),
    };
  });

  if (!tx.committed) {
    if (failReason === "insufficient_balance") {
      return { success: false, reason: "insufficient_balance" };
    }
    return { success: false, reason: failReason };
  }

  return { success: true, reason: "debited", ledger_id: ledgerId };
}

async function adminMarkPlatformWithdrawalPaid(data, context, db) {
  const deny = await enforceSuperAdminOnly(db, context, "adminMarkPlatformWithdrawalPaid");
  if (deny) return deny;

  const withdrawalId = normUid(data?.withdrawal_id ?? data?.withdrawalId);
  if (!withdrawalId) {
    return { success: false, reason: "withdrawal_id_required" };
  }

  console.log("PLATFORM_WITHDRAWAL_MARK_PAID_START", `withdrawalId=${withdrawalId}`);

  const ref = db.ref(`${PLATFORM_WITHDRAW_ROOT}/${withdrawalId}`);
  const snap = await ref.get();
  const w = snap.val();
  if (!w || typeof w !== "object") {
    return { success: false, reason: "not_found" };
  }

  const currentStatus = String(w.status ?? "").trim().toLowerCase();
  if (currentStatus === "paid") {
    return { success: true, reason: "already_paid", idempotent: true, withdrawal_id: withdrawalId };
  }
  if (currentStatus === "rejected") {
    return { success: false, reason: "already_rejected" };
  }

  const amount = roundNgn(w.amount ?? w.amount_ngn ?? w.requested_amount);
  const walletState = await readPlatformWalletState(db);
  const reservedOthers = await sumReservedPlatformWithdrawalAmountNgn(db, withdrawalId);
  const available = computeAvailablePlatformBalanceNgn(walletState.balance, reservedOthers);
  if (amount > available) {
    return {
      success: false,
      reason: "insufficient_available_balance",
      balance: walletState.balance,
      reserved_withdrawals: reservedOthers,
      available_balance: available,
    };
  }
  const debit = await debitPlatformWalletForWithdrawalPaid(db, {
    withdrawalId,
    amount,
  });
  if (!debit.success && debit.reason !== "already_applied") {
    console.log(
      "PLATFORM_WITHDRAWAL_MARK_PAID_FAIL",
      `withdrawalId=${withdrawalId}`,
      `reason=${debit.reason}`,
    );
    return { success: false, reason: debit.reason || "debit_failed" };
  }

  const now = nowMs();
  await ref.update({
    status: "paid",
    paid_at: now,
    paid_by_admin_uid: normUid(context.auth.uid),
    updated_at: now,
    payout_method: "manual_mark_paid",
  });

  console.log("PLATFORM_WITHDRAWAL_MARK_PAID_SUCCESS", `withdrawalId=${withdrawalId}`, `amount=${amount}`);

  return {
    success: true,
    reason: debit.idempotent ? "already_paid" : "paid",
    withdrawal_id: withdrawalId,
    idempotent: Boolean(debit.idempotent),
  };
}

async function adminRejectPlatformWithdrawal(data, context, db) {
  const deny = await enforceSuperAdminOnly(db, context, "adminRejectPlatformWithdrawal");
  if (deny) return deny;

  const withdrawalId = normUid(data?.withdrawal_id ?? data?.withdrawalId);
  if (!withdrawalId) {
    return { success: false, reason: "withdrawal_id_required" };
  }

  const ref = db.ref(`${PLATFORM_WITHDRAW_ROOT}/${withdrawalId}`);
  const snap = await ref.get();
  const w = snap.val();
  if (!w || typeof w !== "object") {
    return { success: false, reason: "not_found" };
  }

  const currentStatus = String(w.status ?? "").trim().toLowerCase();
  if (currentStatus === "rejected") {
    return { success: true, reason: "already_rejected", idempotent: true };
  }
  if (currentStatus === "paid") {
    return { success: false, reason: "already_paid" };
  }

  const now = nowMs();
  await ref.update({
    status: "rejected",
    rejected_at: now,
    rejected_by_admin_uid: normUid(context.auth.uid),
    reject_reason: String(data?.reason ?? data?.reject_reason ?? "").trim().slice(0, 500),
    updated_at: now,
  });

  console.log("PLATFORM_WITHDRAWAL_REJECTED", `withdrawalId=${withdrawalId}`);

  return { success: true, reason: "rejected", withdrawal_id: withdrawalId };
}

function platformFlutterwavePayoutReference(withdrawalId) {
  return `nr_platform_withdraw_${normUid(withdrawalId)}`.slice(0, 90);
}

function payoutBankFromOfficialDestination(dest) {
  if (!dest || typeof dest !== "object") {
    return { bank_code: "", account_number: "", account_name: "", bank_name: "" };
  }
  const bank_name = String(dest.bank_name ?? "").trim();
  const stored_account_bank = String(dest.account_bank ?? dest.bank_code ?? "").trim();
  const account_number = digitsOnlyAccountNumber(dest.account_number);
  const account_name = String(
    dest.account_holder_name ?? dest.account_name ?? "",
  ).trim();
  const resolved = resolvePayoutAccountBank({
    bank_name,
    bank_code: stored_account_bank,
    account_bank: stored_account_bank,
    selected_from_flutterwave_list: dest.selected_from_flutterwave_list === true,
  });
  return {
    bank_name,
    bank_code: resolved.bank_code,
    account_bank: resolved.account_bank,
    account_number,
    account_name,
  };
}

async function claimPlatformWithdrawalForProcessing(ref, adminUid) {
  const tx = await ref.transaction((current) => {
    if (!current || typeof current !== "object") return;
    const st = String(current.status ?? "").trim().toLowerCase();
    if (st !== "pending") return;
    return {
      ...current,
      status: "processing",
      payout_provider: "flutterwave",
      flutterwave_payout_requested_at: nowMs(),
      flutterwave_payout_requested_by: adminUid,
      updated_at: nowMs(),
    };
  });
  if (!tx.committed) {
    return { ok: false, reason: "withdrawal_not_pending" };
  }
  return { ok: true, row: tx.snapshot.val() };
}

async function finalizePlatformWithdrawalAfterFlutterwaveSuccess(
  db,
  withdrawalId,
  w,
  adminUid,
  verifyPayload,
) {
  const {
    normalizeFlutterwaveTransferStatus,
  } = require("./flutterwave_api");
  const normalizedStatus = normalizeFlutterwaveTransferStatus(verifyPayload?.transfer_status);
  if (normalizedStatus !== "successful") {
    return {
      success: false,
      reason: "flutterwave_transfer_not_successful",
      transfer_status: normalizedStatus,
    };
  }

  const amount = roundNgn(w.amount ?? w.amount_ngn ?? w.requested_amount);
  const debit = await debitPlatformWalletForWithdrawalPaid(db, { withdrawalId, amount });
  if (!debit.success && debit.reason !== "already_applied") {
    return debit;
  }

  const ref = db.ref(`${PLATFORM_WITHDRAW_ROOT}/${withdrawalId}`);
  const now = nowMs();
  await ref.update({
    status: "paid",
    payout_provider: "flutterwave",
    payout_method: "flutterwave_transfer",
    flutterwave_transfer_id:
      verifyPayload?.transfer_id ?? w?.flutterwave_transfer_id ?? w?.transfer_id ?? null,
    flutterwave_transfer_reference:
      verifyPayload?.transfer_reference ??
      w?.flutterwave_transfer_reference ??
      platformFlutterwavePayoutReference(withdrawalId),
    flutterwave_payout_status: "successful",
    flutterwave_payout_paid_at: now,
    paid_at: now,
    paid_by_admin_uid: adminUid,
    updated_at: now,
  });

  console.log("PLATFORM_WITHDRAWAL_FLUTTERWAVE_SUCCESS", `withdrawalId=${withdrawalId}`, `amount=${amount}`);
  return {
    success: true,
    reason: debit.idempotent ? "already_paid" : "paid",
    withdrawal_id: withdrawalId,
    idempotent: Boolean(debit.idempotent),
  };
}

async function adminPayPlatformWithdrawalViaFlutterwave(data, context, db) {
  const deny = await enforceSuperAdminOnly(db, context, "adminPayPlatformWithdrawalViaFlutterwave");
  if (deny) return deny;

  const withdrawalId = normUid(data?.withdrawal_id ?? data?.withdrawalId);
  if (!withdrawalId) {
    return { success: false, reason: "withdrawal_id_required" };
  }

  console.log("PLATFORM_WITHDRAWAL_FLUTTERWAVE_START", `withdrawalId=${withdrawalId}`);

  const ref = db.ref(`${PLATFORM_WITHDRAW_ROOT}/${withdrawalId}`);
  const snap = await ref.get();
  const w = snap.val();
  if (!w || typeof w !== "object") {
    return { success: false, reason: "not_found" };
  }

  const st = String(w.status ?? "").trim().toLowerCase();
  if (st === "paid") {
    return { success: true, reason: "already_paid", idempotent: true };
  }
  if (st !== "pending" && st !== "processing") {
    return { success: false, reason: "withdrawal_not_pending", status: st };
  }

  const payoutDest = await readPlatformPayoutDestination(db);
  if (!payoutDest.ok) {
    return blockedOfficialPlatformPayoutResponse(payoutDest);
  }
  const bank = payoutBankFromOfficialDestination(payoutDest.destination);
  if (!bank.bank_code || !bank.account_number || !bank.account_name) {
    return blockedOfficialPlatformPayoutResponse(
      officialPlatformPayoutNotConfigured("platform_payout_destination_invalid"),
    );
  }

  const amount = roundNgn(w.amount ?? w.amount_ngn);
  if (amount <= 0) {
    return { success: false, reason: "invalid_amount" };
  }

  const walletState = await readPlatformWalletState(db);
  const reservedOthers = await sumReservedPlatformWithdrawalAmountNgn(db, withdrawalId);
  const available = computeAvailablePlatformBalanceNgn(walletState.balance, reservedOthers);
  if (amount > available) {
    return {
      success: false,
      reason: "insufficient_available_balance",
      balance: walletState.balance,
      reserved_withdrawals: reservedOthers,
      available_balance: available,
    };
  }

  const { createNgnBankTransfer, getTransferByReference, normalizeFlutterwaveTransferStatus } =
    require("./flutterwave_api");
  const { flutterwaveTransferPinForPayout } = require("./params");
  const adminUid = normUid(context.auth.uid);
  const reference =
    String(w.flutterwave_transfer_reference ?? w.transfer_reference ?? "").trim() ||
    platformFlutterwavePayoutReference(withdrawalId);

  if (!String(w.flutterwave_transfer_reference ?? "").trim()) {
    await ref.update({
      flutterwave_transfer_reference: reference,
      transfer_reference: reference,
      withdrawal_destination_snapshot: payoutDest.destination,
      payout_destination_source: PLATFORM_PAYOUT_CONFIG_PATH,
      updated_at: nowMs(),
    });
  }

  if (st === "pending") {
    const claim = await claimPlatformWithdrawalForProcessing(ref, adminUid);
    if (!claim.ok) {
      return { success: false, reason: claim.reason };
    }
  }

  if (String(w.flutterwave_transfer_id ?? w.transfer_id ?? "").trim()) {
    return {
      success: true,
      reason: "transfer_already_submitted",
      withdrawal_id: withdrawalId,
      transfer_id: w.flutterwave_transfer_id ?? w.transfer_id,
      requires_verify: true,
    };
  }

  if (!String(flutterwaveTransferPinForPayout() || "").trim()) {
    return { success: false, reason: "flutterwave_transfer_pin_missing" };
  }

  let created = await createNgnBankTransfer({
    account_bank: bank.account_bank || bank.bank_code,
    account_number: bank.account_number,
    amount,
    narration: "NexRide platform withdrawal",
    currency: "NGN",
    reference,
    debit_currency: "NGN",
    beneficiary_name: bank.account_name,
    meta: { withdrawal_id: withdrawalId, entity_type: "platform" },
  });

  if (!created.ok && created.duplicate_reference) {
    created = await getTransferByReference(reference);
  }

  if (!created.ok) {
    const errMsg =
      created.flutterwave_message || created.reason || "transfer_create_failed";
    await ref.update({
      status: "pending",
      flutterwave_last_error: String(errMsg).slice(0, 500),
      flutterwave_payout_last_error: String(errMsg).slice(0, 500),
      flutterwave_transfer_reference: reference,
      transfer_reference: reference,
      updated_at: nowMs(),
    });
    return {
      success: false,
      reason: "flutterwave_transfer_create_failed",
      flutterwave_message: created.flutterwave_message ?? null,
      reason_code: created.reason_code ?? null,
    };
  }

  const transferId = created.transfer_id;
  const transferStatus = normalizeFlutterwaveTransferStatus(created.transfer_status);

  await ref.update({
    status: "processing",
    payout_provider: "flutterwave",
    payout_method: "flutterwave_transfer",
    flutterwave_transfer_id: transferId,
    transfer_id: transferId,
    flutterwave_transfer_reference: created.transfer_reference || reference,
    transfer_reference: created.transfer_reference || reference,
    flutterwave_transfer_status: transferStatus,
    flutterwave_payout_status: transferStatus,
    flutterwave_payout_requested_at: nowMs(),
    flutterwave_payout_requested_by: adminUid,
    updated_at: nowMs(),
  });

  if (transferStatus !== "successful") {
    console.log(
      "PLATFORM_WITHDRAWAL_FLUTTERWAVE_PENDING",
      `withdrawalId=${withdrawalId}`,
      `transfer_status=${transferStatus}`,
    );
    return {
      success: true,
      reason: "flutterwave_transfer_submitted",
      withdrawal_id: withdrawalId,
      transfer_id: transferId,
      transfer_status: transferStatus,
      requires_verify: true,
      status: "processing",
    };
  }

  const freshSnap = await ref.get();
  return finalizePlatformWithdrawalAfterFlutterwaveSuccess(
    db,
    withdrawalId,
    freshSnap.val() || w,
    adminUid,
    {
      transfer_status: transferStatus,
      transfer_id: transferId,
      transfer_reference: created.transfer_reference || reference,
    },
  );
}

async function adminVerifyPlatformWithdrawalFlutterwavePayout(data, context, db) {
  const deny = await enforceSuperAdminOnly(db, context, "adminVerifyPlatformWithdrawalFlutterwavePayout");
  if (deny) return deny;

  const withdrawalId = normUid(data?.withdrawal_id ?? data?.withdrawalId);
  if (!withdrawalId) {
    return { success: false, reason: "withdrawal_id_required" };
  }

  const ref = db.ref(`${PLATFORM_WITHDRAW_ROOT}/${withdrawalId}`);
  const snap = await ref.get();
  const w = snap.val();
  if (!w || typeof w !== "object") {
    return { success: false, reason: "not_found" };
  }

  const st = String(w.status ?? "").trim().toLowerCase();
  if (st === "paid") {
    return { success: true, reason: "already_paid", idempotent: true };
  }
  if (st !== "processing" && st !== "pending") {
    return { success: false, reason: "withdrawal_not_processing", status: st };
  }

  const {
    getTransferById,
    getTransferByReference,
    normalizeFlutterwaveTransferStatus,
  } = require("./flutterwave_api");

  const transferId = String(w.flutterwave_transfer_id ?? w.transfer_id ?? "").trim();
  const reference =
    String(w.flutterwave_transfer_reference ?? w.transfer_reference ?? "").trim() ||
    platformFlutterwavePayoutReference(withdrawalId);

  let verifyResult;
  try {
    verifyResult = transferId
      ? await getTransferById(transferId)
      : await getTransferByReference(reference);
  } catch (err) {
    return { success: false, reason: "flutterwave_verify_failed", message: String(err?.message || err) };
  }

  if (!verifyResult.ok) {
    await ref.update({
      flutterwave_payout_last_checked_at: nowMs(),
      flutterwave_last_error:
        verifyResult.flutterwave_message || verifyResult.reason || "fetch_failed",
      updated_at: nowMs(),
    });
    return {
      success: false,
      reason: "flutterwave_transfer_fetch_failed",
      flutterwave_message: verifyResult.flutterwave_message ?? null,
    };
  }

  const transferStatus = normalizeFlutterwaveTransferStatus(verifyResult?.transfer_status);
  const adminUid = normUid(context.auth.uid);

  await ref.update({
    flutterwave_transfer_id: verifyResult?.transfer_id ?? (transferId || null),
    flutterwave_transfer_reference: verifyResult?.transfer_reference ?? reference,
    flutterwave_transfer_status: transferStatus,
    flutterwave_payout_status: transferStatus,
    flutterwave_payout_last_checked_at: nowMs(),
    updated_at: nowMs(),
  });

  if (transferStatus === "successful") {
    const fresh = (await ref.get()).val() || w;
    return finalizePlatformWithdrawalAfterFlutterwaveSuccess(db, withdrawalId, fresh, adminUid, {
      transfer_status: transferStatus,
      transfer_id: verifyResult?.transfer_id ?? transferId,
      transfer_reference: verifyResult?.transfer_reference ?? reference,
    });
  }

  if (transferStatus === "failed") {
    await ref.update({
      status: "pending",
      flutterwave_last_error: verifyResult?.flutterwave_message ?? "transfer_failed",
      updated_at: nowMs(),
    });
    return {
      success: false,
      reason: "flutterwave_transfer_failed",
      transfer_status: transferStatus,
      status: "pending",
    };
  }

  await ref.update({ status: "processing" });
  return {
    success: true,
    reason: "processing",
    withdrawal_id: withdrawalId,
    transfer_status: transferStatus,
    requires_verify: true,
  };
}

const { platformFeeNgn } = require("./params");
const {
  commissionRateFromEntity,
  bookingFeeFromEntity,
  resolveFleetOwnerCommissionRate,
  DEFAULT_COMMISSION_RATE,
} = require("./app_config_pricing");

const DELIVERY_COMMISSION_RATE = DEFAULT_COMMISSION_RATE;

function deliveryFleetHelpers() {
  return require("./fleet_delivery_settlement");
}

function deliveryHasVerifiedOnlinePayment(row) {
  if (!row || typeof row !== "object") return false;
  const ps = String(row.payment_status ?? "").trim().toLowerCase();
  const ptid = String(row.payment_transaction_id ?? row.flw_tx_id ?? "").trim();
  if (ps === "paid_verified" && Boolean(ptid)) {
    return row.payment_verified === true;
  }
  return ps === "verified" && Boolean(ptid) && row.payment_verified === true;
}

function computeDeliveryPlatformBreakdown(deliveryRow) {
  const { deliveryTripFareNgn, computeDeliveryDriverNetNgn } = deliveryFleetHelpers();
  const gross = deliveryTripFareNgn(deliveryRow);
  const bookingFee = roundNgn(bookingFeeFromEntity(deliveryRow));
  const commissionRate = commissionRateFromEntity(deliveryRow);
  const commission = roundNgn(gross * commissionRate);
  const driverPayout = computeDeliveryDriverNetNgn(deliveryRow, false, commissionRate);
  const waitPaid =
    String(deliveryRow?.wait_fee_payment_status ?? "").trim().toLowerCase() === "paid" ||
    deliveryRow?.wait_fee_status === "paid";
  const waitFeeAmount = waitPaid ? roundNgn(deliveryRow?.wait_fee_total) : 0;
  return {
    gross_amount: gross,
    booking_fee_amount: bookingFee,
    commission_amount: commission,
    driver_payout: driverPayout,
    wait_fee_amount: waitFeeAmount,
    platform_total: commission + bookingFee + waitFeeAmount,
  };
}

function computeDeliveryPlatformBreakdownForFleet(deliveryRow, fleetOwnerCommissionRate) {
  const { deliveryTripFareNgn, computeDeliveryDriverNetNgn } = deliveryFleetHelpers();
  const gross = deliveryTripFareNgn(deliveryRow);
  const bookingFee = roundNgn(bookingFeeFromEntity(deliveryRow));
  const rate =
    Number.isFinite(Number(fleetOwnerCommissionRate)) && Number(fleetOwnerCommissionRate) >= 0
      ? Number(fleetOwnerCommissionRate)
      : DEFAULT_COMMISSION_RATE;
  const commissionExempt = rate === 0;
  const commission = commissionExempt ? 0 : roundNgn(gross * rate);
  const fleetPayout = computeDeliveryDriverNetNgn(deliveryRow, commissionExempt, rate);
  const waitPaid =
    String(deliveryRow?.wait_fee_payment_status ?? "").trim().toLowerCase() === "paid" ||
    deliveryRow?.wait_fee_status === "paid";
  const waitFeeAmount = waitPaid ? roundNgn(deliveryRow?.wait_fee_total) : 0;
  return {
    gross_amount: gross,
    booking_fee_amount: bookingFee,
    commission_amount: commission,
    driver_payout: fleetPayout,
    wait_fee_amount: waitFeeAmount,
    platform_total: commission + bookingFee + waitFeeAmount,
    fleet_commission_rate: rate,
  };
}

async function computeDeliveryPlatformBreakdownForSettlement(db, deliveryRow, driverId, fsOverride) {
  const { fleetBusinessIdFromDriverProfile } = deliveryFleetHelpers();
  const did = normUid(driverId ?? deliveryRow?.driver_id ?? deliveryRow?.driverId);
  if (did) {
    const driverSnap = await db.ref(`drivers/${did}`).get();
    const profile =
      driverSnap.val() && typeof driverSnap.val() === "object" ? driverSnap.val() : {};
    const fleetId = fleetBusinessIdFromDriverProfile(profile);
    if (fleetId) {
      const fleetRate = await resolveFleetOwnerCommissionRate(db, fleetId, fsOverride);
      return computeDeliveryPlatformBreakdownForFleet(deliveryRow, fleetRate);
    }
  }
  return computeDeliveryPlatformBreakdown(deliveryRow);
}

/**
 * Credit platform commission + booking fee when a paid delivery completes.
 */
async function settleDeliveryPlatformRevenueOnce(db, { deliveryId, deliveryRow, driverId, source }) {
  const delId = normUid(deliveryId);
  if (!delId || !deliveryRow || typeof deliveryRow !== "object") {
    return { success: true, reason: "skipped_invalid", idempotent: true };
  }
  if (!deliveryHasVerifiedOnlinePayment(deliveryRow)) {
    return { success: true, reason: "payment_not_verified", idempotent: true };
  }

  const breakdown = await computeDeliveryPlatformBreakdownForSettlement(
    db,
    deliveryRow,
    driverId,
  );
  if (breakdown.platform_total <= 0) {
    return { success: true, reason: "skipped_zero", idempotent: true };
  }

  return creditPlatformRevenueOnce(db, {
    ledgerId: platformRevenueLedgerId(delId),
    deliveryId: delId,
    tripId: null,
    grossAmount: breakdown.gross_amount,
    driverPayout: breakdown.driver_payout,
    fleetPayout: breakdown.driver_payout,
    commissionAmount: breakdown.commission_amount,
    bookingFeeAmount: breakdown.booking_fee_amount,
    waitFeeAmount: breakdown.wait_fee_amount,
    source: source || "delivery_completed",
    revenueKind: "delivery",
  });
}

module.exports = {
  PLATFORM_PAYOUT_CONFIG_PATH,
  PLATFORM_WITHDRAW_ROOT,
  PRODUCTION_PLATFORM_WALLET_PATH,
  PRODUCTION_PLATFORM_TRANSACTIONS_PATH,
  platformRevenueLedgerId,
  readPlatformWalletState,
  readProductionPlatformWalletDisplayState,
  listProductionPlatformWalletTransactions,
  readPlatformPayoutDestination,
  creditPlatformRevenueOnce,
  settleDeliveryPlatformRevenueOnce,
  computeDeliveryPlatformBreakdown,
  computeDeliveryPlatformBreakdownForFleet,
  computeDeliveryPlatformBreakdownForSettlement,
  sumReservedPlatformWithdrawalAmountNgn,
  computeAvailablePlatformBalanceNgn,
  debitPlatformWalletForWithdrawalPaid,
  OFFICIAL_PLATFORM_PAYOUT_NOT_CONFIGURED_MSG,
  adminGetPlatformWalletSnapshot,
  adminListPlatformWalletLedger,
  adminGetPlatformPayoutDestination,
  adminListFlutterwavePayoutBanks,
  adminSavePlatformPayoutDestination,
  requestPlatformWithdrawal,
  adminMarkPlatformWithdrawalPaid,
  adminRejectPlatformWithdrawal,
  adminPayPlatformWithdrawalViaFlutterwave,
  adminVerifyPlatformWithdrawalFlutterwavePayout,
  platformFlutterwavePayoutReference,
  enforceSuperAdminOnly,
};

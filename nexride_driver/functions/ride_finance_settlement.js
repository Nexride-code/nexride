/**
 * Authoritative ride + subscription finance settlement (idempotent RTDB ledgers).
 * Booking fee (₦30) and 10% commission are separate platform revenue buckets.
 */

const { platformFeeNgn } = require("./params");
const { createWalletTransactionInternal } = require("./wallet_core");
const { resolveCommissionPolicy } = require("./driver_monetization");

const COMMISSION_RATE = 0.1;
const PLATFORM_WALLET_UID = "nexride_platform";

function normUid(uid) {
  return String(uid ?? "").trim();
}

function nowMs() {
  return Date.now();
}

function roundNgn(n) {
  return Math.round(Math.max(0, Number(n) || 0));
}

/**
 * Trip fare component only — never use rider total or delivery totals that include booking fee.
 * Production rides store trip component on `fare` / `trip_fare_ngn`.
 * @param {object} ride
 */
function tripFareFromRide(ride) {
  if (!ride || typeof ride !== "object") return 0;
  const candidates = [ride.fare, ride.trip_fare_ngn, ride.trip_fare, ride.grossFare, ride.gross_fare];
  for (const c of candidates) {
    const n = Number(c);
    if (Number.isFinite(n) && n > 0) return roundNgn(n);
  }
  return 0;
}

/**
 * Rider-facing total: trip_fare + booking_fee + other rider-side fees on the ride record.
 * @param {object} ride
 */
function computeRiderTotalNgn(ride) {
  const tripFare = tripFareFromRide(ride);
  const bookingFee = roundNgn(
    Number(ride?.booking_fee_ngn ?? ride?.platform_fee_ngn ?? platformFeeNgn()) || platformFeeNgn(),
  );
  const smallOrder = roundNgn(Number(ride?.small_order_fee_ngn ?? 0) || 0);
  const explicitTotal = roundNgn(Number(ride?.total_ngn ?? 0) || 0);
  if (explicitTotal > 0) {
    return explicitTotal;
  }
  return tripFare + bookingFee + smallOrder;
}

/**
 * @param {object} ride
 * @param {{ commissionExempt?: boolean }} [opts]
 */
function computeRideFinanceBreakdown(ride, opts = {}) {
  const tripFare = tripFareFromRide(ride);
  const bookingFee = roundNgn(platformFeeNgn());
  const commissionExempt = opts.commissionExempt === true;
  const commission = commissionExempt ? 0 : roundNgn(tripFare * COMMISSION_RATE);
  const driverNet = Math.max(0, tripFare - commission);
  return {
    trip_fare_ngn: tripFare,
    booking_fee_ngn: bookingFee,
    commission_ngn: commission,
    commission_rate: commissionExempt ? 0 : COMMISSION_RATE,
    driver_net_ngn: driverNet,
    rider_total_ngn: computeRiderTotalNgn(ride),
    commission_exempt: commissionExempt,
    currency: String(ride?.currency ?? "NGN").trim().toUpperCase() || "NGN",
  };
}

function financeLog(event, detail) {
  console.log(event, detail);
}

function breakdownFromRideRecord(ride) {
  const fs = ride?.finance_settlement;
  if (fs && typeof fs === "object" && Number(fs.trip_fare_ngn ?? 0) > 0) {
    return {
      trip_fare_ngn: roundNgn(fs.trip_fare_ngn),
      booking_fee_ngn: roundNgn(fs.booking_fee_ngn),
      commission_ngn: roundNgn(fs.commission_ngn),
      commission_rate: Number(fs.commission_rate ?? COMMISSION_RATE),
      driver_net_ngn: roundNgn(fs.driver_net_ngn),
      commission_exempt: !!fs.commission_exempt,
      currency: String(fs.currency ?? ride?.currency ?? "NGN"),
      settled_at: Number(fs.settled_at ?? ride.finance_settled_at ?? 0) || 0,
      source: String(fs.source ?? "").trim() || null,
    };
  }
  return computeRideFinanceBreakdown(ride, {
    commissionExempt:
      ride?.commission_exempt === true ||
      Number(ride?.commission_ngn ?? ride?.commission ?? -1) === 0,
  });
}

function assertBreakdownConsistent(breakdown) {
  const trip = roundNgn(breakdown.trip_fare_ngn);
  const commission = roundNgn(breakdown.commission_ngn);
  const driverNet = roundNgn(breakdown.driver_net_ngn);
  const bookingFee = roundNgn(breakdown.booking_fee_ngn);
  if (trip <= 0) {
    return { ok: true };
  }
  const sum = driverNet + commission;
  if (Math.abs(trip - sum) > 1) {
    return {
      ok: false,
      reason: "trip_fare_not_equal_driver_net_plus_commission",
      trip_fare_ngn: trip,
      driver_net_ngn: driverNet,
      commission_ngn: commission,
      booking_fee_ngn: bookingFee,
    };
  }
  if (bookingFee > 0 && breakdown.booking_fee_revenue_type !== "booking_fee_revenue") {
    /* booking fee is separate from trip fare — no sum check with trip */
  }
  return { ok: true };
}

async function readExistingRideSettlement(db, rideId, driverId) {
  const rid = normUid(rideId);
  const did = normUid(driverId);
  if (!rid) return null;

  const rideSnap = await db.ref(`ride_requests/${rid}`).get();
  const ride = rideSnap.val() && typeof rideSnap.val() === "object" ? rideSnap.val() : null;
  if (ride?.finance_settled_at && ride?.finance_settlement) {
    return {
      alreadySettled: true,
      settlement: breakdownFromRideRecord(ride),
      ride,
    };
  }

  if (did) {
    const [netSnap, legacySnap] = await Promise.all([
      db.ref(`driver_wallet_ledger/${did}/${rid}_driver_net`).get(),
      db.ref(`driver_wallet_ledger/${did}/${rid}_fare_credit`).get(),
    ]);
    const netRow = netSnap.val();
    const legacyRow = legacySnap.val();
    if (
      (netRow && netRow.completed === true) ||
      (legacyRow && legacyRow.completed === true)
    ) {
      return {
        alreadySettled: true,
        settlement: ride ? breakdownFromRideRecord(ride) : null,
        ride,
      };
    }
  }

  return { alreadySettled: false, ride };
}

async function writePlatformLedgerOnce(db, ledgerKey, row) {
  const key = String(ledgerKey ?? "").trim();
  if (!key) {
    return { success: false, reason: "invalid_ledger_key" };
  }
  const ref = db.ref(`platform_ledger/${key}`);
  let reason = "unknown";
  const tx = await ref.transaction((cur) => {
    if (cur && typeof cur === "object" && cur.completed === true) {
      reason = "already_applied";
      return;
    }
    if (cur != null && cur !== undefined && !(cur && cur.completed === true)) {
      reason = "ledger_key_conflict";
      return;
    }
    return {
      ...row,
      completed: true,
      updated_at: nowMs(),
    };
  });
  if (!tx.committed) {
    if (reason === "already_applied") {
      return { success: true, reason: "already_applied", idempotent: true };
    }
    return { success: false, reason };
  }
  return { success: true, reason: "ledger_written", idempotent: false };
}

async function creditPlatformRevenueWallet(db, { amount, type, idempotencyKey, rideId, txRef }) {
  const amt = roundNgn(amount);
  if (amt <= 0) {
    return { success: true, reason: "skipped_zero", idempotent: true };
  }
  return createWalletTransactionInternal(db, {
    userId: PLATFORM_WALLET_UID,
    amount: amt,
    type,
    idempotencyKey,
  });
}

async function creditDriverNetOnce(db, driverId, rideId, driverNet, source) {
  const did = normUid(driverId);
  const rid = normUid(rideId);
  const amount = roundNgn(driverNet);
  if (!did || !rid || amount <= 0) {
    return { success: true, reason: "skipped_zero", idempotent: true };
  }

  const ledgerRef = db.ref(`driver_wallet_ledger/${did}/${rid}_driver_net`);
  let lockReason = "unknown";
  const lock = await ledgerRef.transaction((cur) => {
    if (cur && typeof cur === "object" && cur.completed === true) {
      lockReason = "already_applied";
      return;
    }
    if (cur && typeof cur === "object" && cur.pending === true) {
      lockReason = "pending";
      return;
    }
    if (cur != null && cur !== undefined) {
      lockReason = "ledger_conflict";
      return;
    }
    return { pending: true, at: nowMs(), source: source || "settle_completed_ride" };
  });

  if (!lock.committed) {
    if (lockReason === "already_applied") {
      return { success: true, reason: "already_applied", idempotent: true };
    }
    return { success: false, reason: lockReason };
  }

  const wt = await createWalletTransactionInternal(db, {
    userId: did,
    amount,
    type: "driver_earning_credit",
    idempotencyKey: `${rid}_driver_net`,
  });

  if (!wt.success) {
    try {
      await ledgerRef.remove();
    } catch (_) {
      /* ignore */
    }
    return wt;
  }

  await ledgerRef.update({
    completed: true,
    amount_ngn: amount,
    revenue_type: "driver_net_earning",
    credited_at: nowMs(),
    source: source || "settle_completed_ride",
    wallet_transaction_id: wt.transactionId,
  });

  return { ...wt, ledger: "driver_wallet_ledger" };
}

/**
 * Idempotent settlement for a completed ride (driver net + platform ledgers).
 * @param {import("firebase-admin/database").Database} db
 * @param {{ rideId: string, ride?: object, driverId?: string, riderId?: string, source?: string }} opts
 */
async function settleCompletedRideOnce(db, opts = {}) {
  const rideId = normUid(opts.rideId);
  const source = String(opts.source ?? "settle_completed_ride").trim();
  if (!rideId) {
    return { success: false, reason: "invalid_ride_id" };
  }

  let ride = opts.ride && typeof opts.ride === "object" ? opts.ride : null;
  const existing = await readExistingRideSettlement(db, rideId, opts.driverId || ride?.driver_id);
  if (existing.alreadySettled) {
    const settlement = existing.settlement || (ride ? breakdownFromRideRecord(ride) : null);
    return {
      success: true,
      reason: "already_settled",
      idempotent: true,
      settlement,
      rideId,
    };
  }
  if (!ride && existing.ride) {
    ride = existing.ride;
  }
  if (!ride) {
    const snap = await db.ref(`ride_requests/${rideId}`).get();
    ride = snap.val() && typeof snap.val() === "object" ? snap.val() : null;
  }
  if (!ride) {
    return { success: false, reason: "ride_missing" };
  }

  const driverId = normUid(opts.driverId || ride.driver_id);
  const riderId = normUid(opts.riderId || ride.rider_id);
  if (!driverId) {
    return { success: false, reason: "missing_driver_id" };
  }

  const commissionPolicy = await resolveCommissionPolicy(db, driverId);
  const breakdown = computeRideFinanceBreakdown(ride, {
    commissionExempt: commissionPolicy.exempt,
  });
  breakdown.booking_fee_revenue_type = "booking_fee_revenue";
  breakdown.commission_revenue_type = "commission_revenue";

  financeLog(
    "FINANCE_TRIP_SETTLEMENT_START",
    `rideId=${rideId} driverId=${driverId} trip_fare=${breakdown.trip_fare_ngn} booking_fee=${breakdown.booking_fee_ngn} commission=${breakdown.commission_ngn} driver_net=${breakdown.driver_net_ngn} source=${source}`,
  );

  const consistent = assertBreakdownConsistent(breakdown);
  if (!consistent.ok) {
    financeLog(
      "FINANCE_LEDGER_MISMATCH",
      `rideId=${rideId} ${consistent.reason} trip=${consistent.trip_fare_ngn} net=${consistent.driver_net_ngn} commission=${consistent.commission_ngn}`,
    );
    return { success: false, reason: "ledger_mismatch", detail: consistent };
  }

  const settledAt = nowMs();
  const results = {
    booking_fee: null,
    commission: null,
    driver_net: null,
  };

  if (breakdown.booking_fee_ngn > 0) {
    results.booking_fee = await writePlatformLedgerOnce(db, `${rideId}_booking_fee`, {
      revenue_type: "booking_fee_revenue",
      amount_ngn: breakdown.booking_fee_ngn,
      ride_id: rideId,
      rider_id: riderId || null,
      driver_id: driverId,
      currency: breakdown.currency,
      created_at: settledAt,
      source,
    });
    if (!results.booking_fee.success && results.booking_fee.reason !== "already_applied") {
      return { success: false, reason: "booking_fee_ledger_failed", detail: results.booking_fee };
    }
    const walletBf = await creditPlatformRevenueWallet(db, {
      amount: breakdown.booking_fee_ngn,
      type: "booking_fee_revenue",
      idempotencyKey: `${rideId}_booking_fee`,
      rideId,
    });
    if (!walletBf.success && walletBf.reason !== "already_applied") {
      financeLog(
        "FINANCE_LEDGER_MISMATCH",
        `rideId=${rideId} booking_fee_wallet_failed reason=${walletBf.reason}`,
      );
      return { success: false, reason: "booking_fee_wallet_failed", detail: walletBf };
    }
    financeLog(
      "FINANCE_BOOKING_FEE_CREDITED",
      `rideId=${rideId} amount=${breakdown.booking_fee_ngn}`,
    );
  }

  if (breakdown.commission_ngn > 0) {
    results.commission = await writePlatformLedgerOnce(db, `${rideId}_commission`, {
      revenue_type: "commission_revenue",
      amount_ngn: breakdown.commission_ngn,
      ride_id: rideId,
      rider_id: riderId || null,
      driver_id: driverId,
      commission_rate: breakdown.commission_rate,
      trip_fare_ngn: breakdown.trip_fare_ngn,
      currency: breakdown.currency,
      created_at: settledAt,
      source,
    });
    if (!results.commission.success && results.commission.reason !== "already_applied") {
      return { success: false, reason: "commission_ledger_failed", detail: results.commission };
    }
    const walletComm = await creditPlatformRevenueWallet(db, {
      amount: breakdown.commission_ngn,
      type: "commission_revenue",
      idempotencyKey: `${rideId}_commission`,
      rideId,
    });
    if (!walletComm.success && walletComm.reason !== "already_applied") {
      financeLog(
        "FINANCE_LEDGER_MISMATCH",
        `rideId=${rideId} commission_wallet_failed reason=${walletComm.reason}`,
      );
      return { success: false, reason: "commission_wallet_failed", detail: walletComm };
    }
    financeLog(
      "FINANCE_PLATFORM_COMMISSION_CREDITED",
      `rideId=${rideId} amount=${breakdown.commission_ngn}`,
    );
  }

  if (breakdown.driver_net_ngn > 0) {
    results.driver_net = await creditDriverNetOnce(db, driverId, rideId, breakdown.driver_net_ngn, source);
    if (!results.driver_net.success && results.driver_net.reason !== "already_applied") {
      return { success: false, reason: "driver_net_credit_failed", detail: results.driver_net };
    }
    financeLog(
      "FINANCE_DRIVER_NET_CREDITED",
      `rideId=${rideId} driverId=${driverId} amount=${breakdown.driver_net_ngn}`,
    );
  }

  const settlementRecord = {
    ...breakdown,
    settled_at: settledAt,
    source,
  };

  const ridePatch = {
    finance_settlement: settlementRecord,
    finance_settled_at: settledAt,
    trip_fare_ngn: breakdown.trip_fare_ngn,
    booking_fee_ngn: breakdown.booking_fee_ngn,
    platform_fee_ngn: breakdown.booking_fee_ngn,
    commission_ngn: breakdown.commission_ngn,
    commissionAmountNgn: breakdown.commission_ngn,
    commission: breakdown.commission_ngn,
    commissionAmount: breakdown.commission_ngn,
    driver_net_ngn: breakdown.driver_net_ngn,
    driverPayout: breakdown.driver_net_ngn,
    driverPayoutNgn: breakdown.driver_net_ngn,
    netEarning: breakdown.driver_net_ngn,
    netEarningNgn: breakdown.driver_net_ngn,
    grossFare: breakdown.trip_fare_ngn,
    grossFareNgn: breakdown.trip_fare_ngn,
    wallet_credit_status: "credited",
    updated_at: settledAt,
    settlement: {
      grossFareNgn: breakdown.trip_fare_ngn,
      bookingFeeNgn: breakdown.booking_fee_ngn,
      commissionAmountNgn: breakdown.commission_ngn,
      driverPayoutNgn: breakdown.driver_net_ngn,
      netEarningNgn: breakdown.driver_net_ngn,
      currency: breakdown.currency,
      commission_exempt: breakdown.commission_exempt,
      recorded_at: settledAt,
      source,
    },
  };

  await db.ref(`ride_requests/${rideId}`).update(ridePatch);

  await db.ref(`driver_earnings/${driverId}/${rideId}`).update({
    rideId,
    amount: breakdown.driver_net_ngn,
    driver_net_ngn: breakdown.driver_net_ngn,
    commission_ngn: breakdown.commission_ngn,
    booking_fee_ngn: breakdown.booking_fee_ngn,
    trip_fare_ngn: breakdown.trip_fare_ngn,
    grossAmount: breakdown.trip_fare_ngn,
    platformFee: breakdown.booking_fee_ngn,
    status: "credited",
    created_at: settledAt,
    updated_at: settledAt,
  });

  return {
    success: true,
    reason: "settled",
    idempotent: false,
    settlement: settlementRecord,
    rideId,
    results,
  };
}

/**
 * Subscription payments → platform subscription_revenue only (never driver trip wallet).
 * @param {import("firebase-admin/database").Database} db
 */
async function recordSubscriptionRevenueOnce(db, { txRef, amountNgn, driverId, ownerUid, planType, source }) {
  const ref = String(txRef ?? "").trim();
  const amount = roundNgn(amountNgn);
  if (!ref || amount <= 0) {
    return { success: false, reason: "invalid_input" };
  }
  const ledgerKey = `${ref}_subscription`;
  const existing = await db.ref(`platform_ledger/${ledgerKey}`).get();
  if (existing.exists() && existing.val()?.completed === true) {
    return {
      success: true,
      reason: "already_settled",
      idempotent: true,
      ledger_key: ledgerKey,
    };
  }

  const now = nowMs();
  const ledger = await writePlatformLedgerOnce(db, ledgerKey, {
    revenue_type: "subscription_revenue",
    amount_ngn: amount,
    tx_ref: ref,
    driver_id: normUid(driverId) || null,
    owner_uid: normUid(ownerUid) || null,
    plan_type: String(planType ?? "").trim() || null,
    currency: "NGN",
    created_at: now,
    source: source || "driver_subscription",
  });
  if (!ledger.success && ledger.reason !== "already_applied") {
    return { success: false, reason: "subscription_ledger_failed", detail: ledger };
  }

  const wallet = await creditPlatformRevenueWallet(db, {
    amount,
    type: "subscription_revenue",
    idempotencyKey: ledgerKey,
    txRef: ref,
  });
  if (!wallet.success && wallet.reason !== "already_applied") {
    financeLog(
      "FINANCE_LEDGER_MISMATCH",
      `txRef=${ref} subscription_wallet_failed reason=${wallet.reason}`,
    );
    return { success: false, reason: "subscription_wallet_failed", detail: wallet };
  }

  financeLog(
    "FINANCE_SUBSCRIPTION_REVENUE_CREDITED",
    `txRef=${ref} amount=${amount} driverId=${normUid(driverId)}`,
  );

  return {
    success: true,
    reason: "subscription_revenue_recorded",
    idempotent: ledger.idempotent === true,
    ledger_key: ledgerKey,
    amount_ngn: amount,
  };
}

function buildRideSettlementPatch(breakdown, source) {
  const recordedAt = nowMs();
  return {
    grossFare: breakdown.trip_fare_ngn,
    grossFareNgn: breakdown.trip_fare_ngn,
    bookingFeeNgn: breakdown.booking_fee_ngn,
    commissionAmountNgn: breakdown.commission_ngn,
    commission: breakdown.commission_ngn,
    driverPayout: breakdown.driver_net_ngn,
    driverPayoutNgn: breakdown.driver_net_ngn,
    netEarning: breakdown.driver_net_ngn,
    netEarningNgn: breakdown.driver_net_ngn,
    currency: breakdown.currency,
    commission_exempt: breakdown.commission_exempt,
    recorded_at: recordedAt,
    source: source || "complete_trip",
    settlement: {
      grossFareNgn: breakdown.trip_fare_ngn,
      bookingFeeNgn: breakdown.booking_fee_ngn,
      commissionAmountNgn: breakdown.commission_ngn,
      driverPayoutNgn: breakdown.driver_net_ngn,
      netEarningNgn: breakdown.driver_net_ngn,
      currency: breakdown.currency,
      commission_exempt: breakdown.commission_exempt,
      recorded_at: recordedAt,
      source: source || "complete_trip",
    },
  };
}

/**
 * Aggregate platform revenue buckets from `platform_ledger` (callable/admin read).
 * @param {import("firebase-admin/database").Database} db
 */
async function summarizePlatformRevenueBuckets(db, opts = {}) {
  const createdFrom = Number(opts.createdFrom ?? opts.created_from ?? 0) || 0;
  const createdTo = Number(opts.createdTo ?? opts.created_to ?? 0) || 0;
  const MAX_SCAN = Math.min(8000, Math.max(200, Number(opts.maxScan ?? 4000) || 4000));
  const buckets = {
    booking_fee_revenue: 0,
    commission_revenue: 0,
    subscription_revenue: 0,
    refunds_voids_ngn: 0,
  };
  let driverNetEarnings = 0;
  let payoutLiabilities = 0;
  let scannedPlatform = 0;
  let scannedDriverNet = 0;
  let resumeKey = "";
  const BATCH = 150;

  while (scannedPlatform < MAX_SCAN) {
    let q = db.ref("platform_ledger").orderByKey();
    if (resumeKey) {
      q = q.startAfter(resumeKey);
    }
    const snap = await q.limitToFirst(BATCH).get();
    const val = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
    const keys = Object.keys(val).sort();
    if (keys.length === 0) break;
    for (const k of keys) {
      scannedPlatform += 1;
      resumeKey = k;
      const row = val[k];
      if (!row || typeof row !== "object" || row.completed !== true) continue;
      const at = Number(row.created_at ?? row.updated_at ?? 0) || 0;
      if (createdFrom > 0 && at > 0 && at < createdFrom) continue;
      if (createdTo > 0 && at > 0 && at > createdTo) continue;
      const amt = roundNgn(row.amount_ngn ?? row.amount ?? 0);
      const rt = String(row.revenue_type ?? "").trim();
      if (rt === "booking_fee_revenue") buckets.booking_fee_revenue += amt;
      else if (rt === "commission_revenue") buckets.commission_revenue += amt;
      else if (rt === "subscription_revenue") buckets.subscription_revenue += amt;
    }
    if (keys.length < BATCH) break;
  }

  let dResume = "";
  while (scannedDriverNet < MAX_SCAN) {
    let q = db.ref("driver_wallet_ledger").orderByKey();
    if (dResume) q = q.startAfter(dResume);
    const snap = await q.limitToFirst(BATCH).get();
    const val = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
    const driverIds = Object.keys(val).sort();
    if (driverIds.length === 0) break;
    for (const did of driverIds) {
      dResume = did;
      const perDriver = val[did];
      if (!perDriver || typeof perDriver !== "object") continue;
      for (const [entryKey, row] of Object.entries(perDriver)) {
        if (!row || typeof row !== "object" || row.completed !== true) continue;
        if (!String(entryKey).endsWith("_driver_net")) continue;
        scannedDriverNet += 1;
        const at = Number(row.credited_at ?? row.created_at ?? 0) || 0;
        if (createdFrom > 0 && at > 0 && at < createdFrom) continue;
        if (createdTo > 0 && at > 0 && at > createdTo) continue;
        driverNetEarnings += roundNgn(row.amount_ngn ?? row.amount ?? 0);
      }
    }
    if (driverIds.length < BATCH) break;
  }

  let scannedPaymentTx = 0;
  let ptResume = "";
  while (scannedPaymentTx < MAX_SCAN) {
    let q = db.ref("payment_transactions").orderByKey();
    if (ptResume) q = q.startAfter(ptResume);
    const snap = await q.limitToFirst(BATCH).get();
    const val = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
    const keys = Object.keys(val).sort();
    if (keys.length === 0) break;
    for (const k of keys) {
      scannedPaymentTx += 1;
      ptResume = k;
      const row = val[k];
      if (!row || typeof row !== "object") continue;
      const at = Number(row.updated_at ?? row.created_at ?? 0) || 0;
      if (createdFrom > 0 && at > 0 && at < createdFrom) continue;
      if (createdTo > 0 && at > 0 && at > createdTo) continue;
      const st = String(row.status ?? "").trim().toLowerCase();
      if (!st.includes("void") && !st.includes("refund")) continue;
      buckets.refunds_voids_ngn += roundNgn(row.amount ?? row.amount_ngn ?? 0);
    }
    if (keys.length < BATCH) break;
  }

  try {
    const wSnap = await db.ref("withdraw_requests").orderByKey().limitToFirst(500).get();
    const wVal = wSnap.val() && typeof wSnap.val() === "object" ? wSnap.val() : {};
    for (const row of Object.values(wVal)) {
      if (!row || typeof row !== "object") continue;
      const st = String(row.status ?? "").trim().toLowerCase();
      if (st !== "pending" && st !== "processing" && st !== "reviewing") continue;
      payoutLiabilities += roundNgn(row.amount ?? 0);
    }
  } catch (_) {
    /* optional */
  }

  return {
    success: true,
    buckets: {
      booking_fee_revenue: buckets.booking_fee_revenue,
      commission_revenue: buckets.commission_revenue,
      subscription_revenue: buckets.subscription_revenue,
      driver_net_earnings: driverNetEarnings,
      payout_liabilities: payoutLiabilities,
      refunds_voids_ngn: buckets.refunds_voids_ngn,
    },
    scanned_platform_rows: scannedPlatform,
    scanned_driver_net_rows: scannedDriverNet,
    scanned_payment_tx_rows: scannedPaymentTx,
    capped:
      scannedPlatform >= MAX_SCAN ||
      scannedDriverNet >= MAX_SCAN ||
      scannedPaymentTx >= MAX_SCAN,
  };
}

module.exports = {
  COMMISSION_RATE,
  PLATFORM_WALLET_UID,
  tripFareFromRide,
  computeRiderTotalNgn,
  computeRideFinanceBreakdown,
  assertBreakdownConsistent,
  settleCompletedRideOnce,
  recordSubscriptionRevenueOnce,
  buildRideSettlementPatch,
  writePlatformLedgerOnce,
  creditDriverNetOnce,
  summarizePlatformRevenueBuckets,
};

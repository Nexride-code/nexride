/**
 * Wallet credits (platform / driver / fleet) only after authoritative Flutterwave verification.
 * Never trust client-written payment_status or payment_verified on ride/delivery rows alone.
 */

const { verifyFlutterwavePaymentStrict } = require("./flutterwave_api");
const rideFinance = require("./ride_finance_settlement");
const { entityPaymentMinAmountNgn, assertExactFlutterwaveAmount } = require("./payment_charge_expectations");
const { frozenTotalNgn } = require("./pricing_snapshot");

const SETTLEMENT_SOURCES = new Set([
  "verify_flutterwave_payment",
  "flutterwave_webhook",
  "trip_completed",
  "delivery_completed",
  "record_trip_completion",
]);

function normUid(v) {
  return String(v ?? "").trim();
}

function nowMs() {
  return Date.now();
}

function roundNgn(n) {
  return Math.round(Math.max(0, Number(n) || 0));
}

function entityMinFareNgn(row, entityType) {
  const charge = entityPaymentMinAmountNgn(row);
  if (charge > 0) {
    return charge;
  }
  if (!row || typeof row !== "object") return 0;
  if (entityType === "delivery") {
    const candidates = [row.fare, row.trip_fare_ngn, row.total_delivery_fee, row.amount_ngn];
    for (const c of candidates) {
      const n = Number(c);
      if (Number.isFinite(n) && n > 0) return roundNgn(n);
    }
    return 0;
  }
  const candidates = [row.fare, row.trip_fare_ngn, row.trip_fare, row.grossFare, row.gross_fare];
  for (const c of candidates) {
    const n = Number(c);
    if (Number.isFinite(n) && n > 0) return roundNgn(n);
  }
  return 0;
}

function entityExpectedTxRef(row) {
  return String(
    row?.customer_transaction_reference ??
      row?.payment_reference ??
      row?.payment_tx_ref ??
      row?.tx_ref ??
      "",
  ).trim();
}

function entityPayTid(row) {
  return String(row?.payment_transaction_id ?? row?.flw_tx_id ?? row?.paymentTransactionId ?? "").trim();
}

function rideIsCompleted(ride) {
  if (!ride || typeof ride !== "object") return false;
  const status = String(ride.status ?? "").trim().toLowerCase();
  const tripState = String(ride.trip_state ?? "").trim().toLowerCase();
  return (
    status === "completed" ||
    status === "trip_completed" ||
    tripState === "completed" ||
    tripState === "trip_completed"
  );
}

function deliveryIsCompleted(row) {
  const s = String(row?.delivery_state ?? row?.status ?? "").trim().toLowerCase();
  return s === "completed" || s === "delivered";
}

function paymentRowLooksAuthoritative(row) {
  if (!row || typeof row !== "object") return false;
  if (row.verified !== true) return false;
  const payStatus = String(row.status ?? "").trim().toLowerCase();
  const providerStatus = String(row.provider_status ?? "").trim().toLowerCase();
  return payStatus === "verified" || providerStatus === "successful";
}

/**
 * Resolve `payments/{flutterwaveTransactionId}` with fallback to `payment_transactions/{tx_ref}`.
 * @returns {Promise<{ ok: boolean, payTid?: string, paymentRow?: object, reason?: string }>}
 */
async function resolveAuthoritativePaymentRecord(db, entityRow) {
  const payTidRaw = entityPayTid(entityRow);
  if (!payTidRaw) {
    return { ok: false, reason: "payment_transaction_id_missing" };
  }

  const tryPayTid = async (payTid) => {
    const tid = String(payTid ?? "").trim();
    if (!tid) return null;
    const snap = await db.ref(`payments/${tid}`).get();
    const row = snap.val() && typeof snap.val() === "object" ? snap.val() : null;
    if (!row) return null;
    return { payTid: tid, paymentRow: row };
  };

  let resolved = await tryPayTid(payTidRaw);
  if (!resolved) {
    const txCandidates = new Set(
      [payTidRaw, entityExpectedTxRef(entityRow)].map((v) => String(v ?? "").trim()).filter(Boolean),
    );
    for (const txRef of txCandidates) {
      const ptSnap = await db.ref(`payment_transactions/${txRef}`).get();
      const pt = ptSnap.val() && typeof ptSnap.val() === "object" ? ptSnap.val() : null;
      if (!pt) continue;
      const flwId = String(
        pt.flutterwave_transaction_id ?? pt.transaction_id ?? pt.payment_transaction_id ?? "",
      ).trim();
      if (flwId) {
        resolved = await tryPayTid(flwId);
        if (resolved) break;
      }
      if (paymentRowLooksAuthoritative(pt)) {
        resolved = { payTid: flwId || payTidRaw, paymentRow: pt };
        break;
      }
    }
  }

  if (!resolved) {
    return { ok: false, reason: "authoritative_payment_record_missing" };
  }
  return { ok: true, payTid: resolved.payTid, paymentRow: resolved.paymentRow };
}

/**
 * Authoritative payment proof: `payments/{flutterwaveTransactionId}` written only by
 * verifyFlutterwavePayment / webhook after verifyFlutterwavePaymentStrict succeeds.
 */
async function loadAuthoritativeFlutterwavePayment(db, { rideId, deliveryId }) {
  const rid = normUid(rideId);
  const did = normUid(deliveryId);
  if ((rid && did) || (!rid && !did)) {
    return { ok: false, reason: "invalid_entity_scope" };
  }

  const entityType = rid ? "ride" : "delivery";
  const entityPath = rid ? `ride_requests/${rid}` : `delivery_requests/${did}`;
  const entitySnap = await db.ref(entityPath).get();
  const entityRow =
    entitySnap.val() && typeof entitySnap.val() === "object" ? entitySnap.val() : null;
  if (!entityRow) {
    return { ok: false, reason: "entity_missing" };
  }

  const resolvedPayment = await resolveAuthoritativePaymentRecord(db, entityRow);
  if (!resolvedPayment.ok) {
    return resolvedPayment;
  }
  const payTid = resolvedPayment.payTid;
  const paymentRow = resolvedPayment.paymentRow;

  if (!paymentRowLooksAuthoritative(paymentRow)) {
    return { ok: false, reason: "payment_not_verified" };
  }

  const boundRide = normUid(paymentRow.ride_id);
  const boundDelivery = normUid(paymentRow.delivery_id);
  if (rid && boundRide !== rid) {
    return { ok: false, reason: "ride_id_ownership_mismatch" };
  }
  if (did && boundDelivery !== did) {
    return { ok: false, reason: "delivery_id_ownership_mismatch" };
  }

  const txRef = String(paymentRow.tx_ref ?? "").trim();
  const expectedTxRef = entityExpectedTxRef(entityRow);
  if (expectedTxRef && txRef && txRef !== expectedTxRef) {
    return { ok: false, reason: "tx_ref_mismatch" };
  }

  const expectCur = "NGN";
  const payCur = String(paymentRow.currency ?? "").trim().toUpperCase();
  if (payCur !== expectCur) {
    return { ok: false, reason: "currency_must_be_ngn", currency: payCur || null };
  }
  const entityCur = String(entityRow.currency ?? "NGN").trim().toUpperCase() || "NGN";
  if (entityCur !== expectCur) {
    return { ok: false, reason: "entity_currency_must_be_ngn", currency: entityCur };
  }

  const paidAmount = roundNgn(paymentRow.amount);
  const amountCheck = assertExactFlutterwaveAmount(paidAmount, entityRow);
  if (!amountCheck.ok) {
    return {
      ok: false,
      reason: amountCheck.reason,
      expected_total_ngn: amountCheck.expected_total_ngn,
      paid_amount_ngn: amountCheck.paid_amount_ngn,
    };
  }

  const duplicateTid = String(paymentRow.transaction_id ?? "").trim();
  if (duplicateTid && duplicateTid !== payTid) {
    return { ok: false, reason: "duplicate_transaction_id_mismatch" };
  }

  const fwClaimSnap = await db.ref(`webhook_applied/flutterwave/${payTid}`).get();
  const hasFwClaim = fwClaimSnap.exists();
  if (!hasFwClaim && paymentRow.webhook_applied !== true) {
    return { ok: false, reason: "flutterwave_settlement_claim_missing" };
  }

  return {
    ok: true,
    entityType,
    entityId: rid || did,
    rideId: rid || null,
    deliveryId: did || null,
    payTid,
    txRef: txRef || expectedTxRef,
    amount: paidAmount,
    currency: payCur || expectCur,
    paymentRow,
    entityRow,
    expectedTotalNgn: frozenTotalNgn(entityRow) || amountCheck.expected,
  };
}

/**
 * Primary settlement lock — one credit per Flutterwave payment id.
 * Path: payment_settlements/{paymentId}
 */
async function claimPaymentSettlementOnce(db, {
  payTid,
  entityType,
  entityId,
  source,
  amount,
  txRef,
}) {
  const ref = db.ref(`payment_settlements/${payTid}`);
  let reason = "unknown";
  const tx = await ref.transaction((cur) => {
    if (cur && typeof cur === "object" && cur.completed === true) {
      reason = "already_settled";
      return;
    }
    if (cur != null && cur !== undefined) {
      reason = "settlement_key_conflict";
      return;
    }
    return {
      completed: true,
      pay_tid: payTid,
      entity_type: entityType,
      entity_id: entityId,
      source,
      amount_ngn: roundNgn(amount),
      tx_ref: String(txRef ?? "").trim() || null,
      applied_at: nowMs(),
    };
  });
  if (!tx.committed) {
    return {
      ok: reason === "already_settled",
      idempotent: reason === "already_settled",
      reason,
    };
  }
  return { ok: true, idempotent: false, reason: "claimed" };
}

async function claimWalletSettlementOnce(db, { entityType, entityId, payTid, source }) {
  const src = String(source ?? "").trim();
  if (!SETTLEMENT_SOURCES.has(src)) {
    return { ok: false, reason: "invalid_settlement_source" };
  }
  const root =
    entityType === "ride"
      ? `wallet_settlement_applied/rides/${entityId}`
      : `wallet_settlement_applied/deliveries/${entityId}`;
  const ref = db.ref(root);
  let reason = "unknown";
  const tx = await ref.transaction((cur) => {
    if (cur && typeof cur === "object" && cur.completed === true) {
      reason = "already_applied";
      return;
    }
    if (cur != null && cur !== undefined) {
      reason = "settlement_key_conflict";
      return;
    }
    return {
      completed: true,
      pay_tid: payTid,
      source: src,
      applied_at: nowMs(),
    };
  });
  if (!tx.committed) {
    return {
      ok: reason === "already_applied",
      idempotent: reason === "already_applied",
      reason,
    };
  }
  return { ok: true, idempotent: false, reason: "claimed" };
}

async function applyRideWalletSettlement(db, { rideId, source, requireCompleted }) {
  const auth = await loadAuthoritativeFlutterwavePayment(db, { rideId });
  if (!auth.ok) {
    console.log(
      "WALLET_SETTLEMENT_BLOCKED",
      `entity=ride`,
      `rideId=${rideId}`,
      `reason=${auth.reason}`,
      `source=${source}`,
    );
    return { success: false, reason: auth.reason };
  }

  if (requireCompleted && !rideIsCompleted(auth.entityRow)) {
    return { success: true, reason: "trip_not_completed_yet", skipped: true };
  }

  const reverify = await assertFlutterwaveProviderStillSuccessful({
    payTid: auth.payTid,
    txRef: auth.txRef,
    currency: "NGN",
    exactAmount: auth.expectedTotalNgn || auth.amount,
  });
  if (!reverify.ok) {
    console.log(
      "WALLET_SETTLEMENT_BLOCKED",
      `entity=ride`,
      `rideId=${rideId}`,
      `reason=${reverify.reason}`,
      `source=${source}`,
    );
    return { success: false, reason: reverify.reason || "flutterwave_reverify_failed" };
  }

  const payClaim = await claimPaymentSettlementOnce(db, {
    payTid: auth.payTid,
    entityType: "ride",
    entityId: rideId,
    source,
    amount: auth.amount,
    txRef: auth.txRef,
  });
  if (!payClaim.ok && !payClaim.idempotent) {
    return { success: false, reason: payClaim.reason || "payment_settlement_claim_failed" };
  }

  const claim = await claimWalletSettlementOnce(db, {
    entityType: "ride",
    entityId: rideId,
    payTid: auth.payTid,
    source,
  });
  if (!claim.ok && !claim.idempotent) {
    return { success: false, reason: claim.reason || "settlement_claim_failed" };
  }

  const driverId = normUid(auth.entityRow.driver_id);
  const riderId = normUid(auth.entityRow.rider_id);
  const fin = await rideFinance.settleCompletedRideOnce(db, {
    rideId,
    ride: auth.entityRow,
    driverId,
    riderId,
    source,
  });
  if (!fin.success && fin.reason !== "already_settled") {
    console.log(
      "WALLET_SETTLEMENT_FAIL",
      `entity=ride`,
      `rideId=${rideId}`,
      `reason=${fin.reason}`,
    );
    return { success: false, reason: fin.reason || "ride_settlement_failed", detail: fin };
  }

  console.log(
    "WALLET_SETTLEMENT_APPLIED",
    `entity=ride`,
    `rideId=${rideId}`,
    `payTid=${auth.payTid}`,
    `txRef=${auth.txRef}`,
    `amount=${auth.amount}`,
    `source=${source}`,
  );
  return { success: true, reason: fin.reason || "settled", idempotent: fin.idempotent === true };
}

async function applyDeliveryWalletSettlement(db, { deliveryId, source, requireCompleted }) {
  const auth = await loadAuthoritativeFlutterwavePayment(db, { deliveryId });
  if (!auth.ok) {
    console.log(
      "WALLET_SETTLEMENT_BLOCKED",
      `entity=delivery`,
      `deliveryId=${deliveryId}`,
      `reason=${auth.reason}`,
      `source=${source}`,
    );
    return { success: false, reason: auth.reason };
  }

  if (requireCompleted && !deliveryIsCompleted(auth.entityRow)) {
    return { success: true, reason: "delivery_not_completed_yet", skipped: true };
  }

  const reverify = await assertFlutterwaveProviderStillSuccessful({
    payTid: auth.payTid,
    txRef: auth.txRef,
    currency: "NGN",
    exactAmount: auth.expectedTotalNgn || auth.amount,
  });
  if (!reverify.ok) {
    return { success: false, reason: reverify.reason || "flutterwave_reverify_failed" };
  }

  const payClaim = await claimPaymentSettlementOnce(db, {
    payTid: auth.payTid,
    entityType: "delivery",
    entityId: deliveryId,
    source,
    amount: auth.amount,
    txRef: auth.txRef,
  });
  if (!payClaim.ok && !payClaim.idempotent) {
    return { success: false, reason: payClaim.reason || "payment_settlement_claim_failed" };
  }
  if (payClaim.idempotent) {
    return { success: true, reason: "already_settled", idempotent: true };
  }

  const claim = await claimWalletSettlementOnce(db, {
    entityType: "delivery",
    entityId: deliveryId,
    payTid: auth.payTid,
    source,
  });
  if (!claim.ok && !claim.idempotent) {
    return { success: false, reason: claim.reason || "settlement_claim_failed" };
  }
  if (claim.idempotent) {
    return { success: true, reason: "already_settled", idempotent: true };
  }

  const driverId = normUid(auth.entityRow.driver_id ?? auth.entityRow.driverId);
  const results = {};

  try {
    const { settleFleetLinkedDeliveryEarningOnce } = require("./fleet_delivery_settlement");
    results.fleet = await settleFleetLinkedDeliveryEarningOnce(db, {
      deliveryId,
      deliveryRow: auth.entityRow,
      driverId,
      source,
    });
  } catch (e) {
    results.fleet = { success: false, reason: String(e?.message || e) };
  }

  try {
    const { settleIndependentDeliveryDriverEarningOnce } = require("./fleet_delivery_settlement");
    results.driver = await settleIndependentDeliveryDriverEarningOnce(db, {
      deliveryId,
      deliveryRow: auth.entityRow,
      driverId,
      source,
    });
  } catch (e) {
    results.driver = { success: false, reason: String(e?.message || e) };
  }

  try {
    const { settleDeliveryPlatformRevenueOnce } = require("./platform_wallet");
    results.platform = await settleDeliveryPlatformRevenueOnce(db, {
      deliveryId,
      deliveryRow: auth.entityRow,
      driverId,
      source,
    });
  } catch (e) {
    results.platform = { success: false, reason: String(e?.message || e) };
  }

  const fleetOk =
    !results.fleet ||
    results.fleet.success === true ||
    results.fleet.reason === "already_applied" ||
    results.fleet.reason === "not_fleet_managed" ||
    results.fleet.skipped === true;
  const driverOk =
    !results.driver ||
    results.driver.success === true ||
    results.driver.reason === "already_applied" ||
    results.driver.reason === "fleet_managed_skipped" ||
    results.driver.skipped === true;
  const platformOk =
    !results.platform ||
    results.platform.success === true ||
    results.platform.idempotent === true ||
    results.platform.reason === "already_settled";
  if (!fleetOk || !driverOk || !platformOk) {
    console.log(
      "WALLET_SETTLEMENT_FAIL",
      `entity=delivery`,
      `deliveryId=${deliveryId}`,
      `fleet=${JSON.stringify(results.fleet)}`,
      `driver=${JSON.stringify(results.driver)}`,
      `platform=${JSON.stringify(results.platform)}`,
    );
    return {
      success: false,
      reason: "delivery_settlement_partial_failure",
      results,
    };
  }

  console.log(
    "WALLET_SETTLEMENT_APPLIED",
    `entity=delivery`,
    `deliveryId=${deliveryId}`,
    `payTid=${auth.payTid}`,
    `txRef=${auth.txRef}`,
    `amount=${auth.amount}`,
    `source=${source}`,
  );

  return {
    success: true,
    reason: "settled",
    results,
  };
}

/**
 * Entry used by verifyFlutterwavePayment, webhook, and trip/delivery completion.
 */
async function applyWalletSettlementsAfterAuthoritativePayment(db, opts = {}) {
  const source = String(opts.source ?? "").trim();
  const rideId = normUid(opts.rideId);
  const deliveryId = normUid(opts.deliveryId);
  const requireCompleted = opts.requireCompleted !== false;

  if (rideId) {
    return applyRideWalletSettlement(db, { rideId, source, requireCompleted });
  }
  if (deliveryId) {
    return applyDeliveryWalletSettlement(db, { deliveryId, source, requireCompleted });
  }
  return { success: false, reason: "invalid_input" };
}

/**
 * Re-verify with Flutterwave API before first settlement claim (webhook/verify paths).
 */
async function assertFlutterwaveProviderStillSuccessful({
  payTid,
  txRef,
  currency,
  minAmount,
  exactAmount,
}) {
  const { flutterwaveSecretForVerify } = require("./params");
  if (!String(flutterwaveSecretForVerify() || "").trim()) {
    return { ok: true, skipped: true, reason: "flutterwave_secret_missing" };
  }
  const expect = {
    expectedCurrency: currency || "NGN",
  };
  const exact = roundNgn(exactAmount ?? minAmount ?? 0);
  if (exact > 0) {
    expect.exactAmount = exact;
    expect.minAmount = exact;
  } else if (minAmount > 0) {
    expect.minAmount = minAmount;
  }
  const v = await verifyFlutterwavePaymentStrict({
    transactionId: /^\d+$/.test(payTid) ? payTid : "",
    txRef: txRef || payTid,
    expect,
  });
  if (!v.ok) {
    return { ok: false, reason: v.reason || "flutterwave_verify_failed" };
  }
  if (exact > 0 && Math.abs(roundNgn(v.amount) - exact) > 1) {
    return { ok: false, reason: "amount_mismatch", expected: exact, paid: v.amount };
  }
  return { ok: true, verify: v };
}

module.exports = {
  SETTLEMENT_SOURCES,
  resolveAuthoritativePaymentRecord,
  loadAuthoritativeFlutterwavePayment,
  applyWalletSettlementsAfterAuthoritativePayment,
  applyRideWalletSettlement,
  applyDeliveryWalletSettlement,
  assertFlutterwaveProviderStillSuccessful,
  claimPaymentSettlementOnce,
  rideIsCompleted,
  deliveryIsCompleted,
};

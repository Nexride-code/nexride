/**
 * Admin finance adjustments — audited, server-only wallet mutations.
 */

const adminPerms = require("./admin_permissions");
const adminAuditLog = require("./admin_audit_log");
const { createWalletTransactionInternal } = require("./wallet_core");
const { resolveRideRequestId } = require("./ride_id_resolver");

function normUid(v) {
  return String(v ?? "").trim();
}

function num(v) {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
}

async function adminApplyRiderTripCredit(data, context, db) {
  const deny = await adminPerms.enforceCallable(db, context, "adminApplyRiderTripCredit");
  if (deny) return deny;
  const adminUid = normUid(context?.auth?.uid);
  const riderId = normUid(data?.riderId ?? data?.rider_id);
  const amountNgn = num(data?.amountNgn ?? data?.amount_ngn);
  const note = String(data?.note ?? data?.reason ?? "").trim();
  const rideId = normUid(data?.rideId ?? data?.ride_id);
  if (!riderId || amountNgn <= 0 || note.length < 8) {
    return { success: false, reason: "invalid_input" };
  }

  const creditId = db.ref("rider_trip_credits").push().key;
  const idemKey = `admin_rider_credit_${creditId}`;
  const now = Date.now();

  await db.ref(`rider_trip_credits/${creditId}`).set({
    rider_id: riderId,
    ride_id: rideId || null,
    amount_ngn: amountNgn,
    note,
    created_by: adminUid,
    created_at: now,
    idempotency_key: idemKey,
  });

  await db.ref(`rider_payment_flags/${riderId}`).transaction((cur) => {
    const flags = cur && typeof cur === "object" ? cur : {};
    const prev = num(flags.trip_credit_ngn, 0);
    return {
      ...flags,
      trip_credit_ngn: prev + amountNgn,
      updated_at: now,
    };
  });

  await adminAuditLog.writeAdminAuditLog(db, {
    action: "admin_apply_rider_trip_credit",
    admin_uid: adminUid,
    target_type: "rider",
    target_id: riderId,
    ride_id: rideId || null,
    amount_ngn: amountNgn,
    note,
    credit_id: creditId,
    created_at: now,
  });

  return { success: true, credit_id: creditId, amount_ngn: amountNgn };
}

async function adminApplyDriverWalletCredit(data, context, db) {
  const deny = await adminPerms.enforceCallable(db, context, "adminApplyDriverWalletCredit");
  if (deny) return deny;
  const adminUid = normUid(context?.auth?.uid);
  const driverId = normUid(data?.driverId ?? data?.driver_id);
  const amountNgn = num(data?.amountNgn ?? data?.amount_ngn);
  const note = String(data?.note ?? data?.reason ?? "").trim();
  if (!driverId || amountNgn <= 0 || note.length < 8) {
    return { success: false, reason: "invalid_input" };
  }

  const adjustmentId = db.ref("admin_wallet_adjustments").push().key;
  const idemKey = `admin_driver_wallet_credit_${adjustmentId}`;
  const wt = await createWalletTransactionInternal(db, {
    userId: driverId,
    amount: amountNgn,
    type: "admin_wallet_credit",
    idempotencyKey: idemKey,
  });
  if (!wt.success && wt.reason !== "already_applied") {
    return { success: false, reason: wt.reason || "wallet_credit_failed" };
  }

  const now = Date.now();
  await db.ref(`admin_wallet_adjustments/${adjustmentId}`).set({
    driver_id: driverId,
    amount_ngn: amountNgn,
    note,
    created_by: adminUid,
    created_at: now,
    idempotency_key: idemKey,
    wallet_transaction_id: wt.transactionId || idemKey,
  });

  await adminAuditLog.writeAdminAuditLog(db, {
    action: "admin_apply_driver_wallet_credit",
    admin_uid: adminUid,
    target_type: "driver",
    target_id: driverId,
    amount_ngn: amountNgn,
    note,
    adjustment_id: adjustmentId,
    created_at: now,
  });

  return {
    success: true,
    adjustment_id: adjustmentId,
    idempotent: wt.idempotent === true,
  };
}

/**
 * Admin-only repair: re-run idempotent ride wallet settlement for one completed ride.
 */
async function adminRepairCompletedRideSettlement(data, context, db) {
  const deny = await adminPerms.enforceCallable(db, context, "adminRepairCompletedRideSettlement");
  if (deny) return deny;

  const adminUid = normUid(context?.auth?.uid);
  const rawRideId = normUid(data?.rideId ?? data?.ride_id);
  if (!rawRideId) {
    return { success: false, reason: "invalid_ride_id" };
  }

  const resolved = await resolveRideRequestId(db, rawRideId);
  if (!resolved.ok) {
    return {
      success: false,
      reason: resolved.reason || "ride_missing",
      input_ride_id: rawRideId,
      tried: resolved.tried ?? null,
    };
  }
  const rideId = resolved.rideId;
  const ride = resolved.ride && typeof resolved.ride === "object" ? resolved.ride : null;
  if (!ride) {
    return { success: false, reason: "ride_missing", input_ride_id: rawRideId };
  }

  const paymentWalletSettlement = require("./payment_wallet_settlement");
  if (!paymentWalletSettlement.rideIsCompleted(ride)) {
    return { success: false, reason: "ride_not_completed" };
  }

  const auth = await paymentWalletSettlement.loadAuthoritativeFlutterwavePayment(db, { rideId });
  if (!auth.ok) {
    return {
      success: false,
      reason: auth.reason || "authoritative_payment_missing",
      ride_id: rideId,
      input_ride_id: rawRideId,
      resolved_via: resolved.resolved_via,
    };
  }

  const before = {
    driver_id: normUid(ride.driver_id),
    payment_transaction_id: String(ride.payment_transaction_id ?? "").trim() || null,
    wallet_settlement_applied: null,
    driver_wallet_ledger: null,
  };
  const driverId = before.driver_id;
  if (driverId) {
    const walletAppliedSnap = await db.ref(`wallet_settlement_applied/rides/${rideId}`).get();
    before.wallet_settlement_applied = walletAppliedSnap.val() ?? null;
    const ledgerSnap = await db
      .ref(`driver_wallet_ledger/${driverId}/${rideId}_driver_net`)
      .get();
    before.driver_wallet_ledger = ledgerSnap.val() ?? null;
  }

  const fin = await paymentWalletSettlement.applyWalletSettlementsAfterAuthoritativePayment(db, {
    rideId,
    source: "trip_completed",
    requireCompleted: true,
  });

  const afterWalletApplied = (
    await db.ref(`wallet_settlement_applied/rides/${rideId}`).get()
  ).val();
  const afterDriverLedger = driverId
    ? (await db.ref(`driver_wallet_ledger/${driverId}/${rideId}_driver_net`).get()).val()
    : null;

  await adminAuditLog.writeAdminAuditLog(db, {
    action: "admin_repair_completed_ride_settlement",
    admin_uid: adminUid,
    target_type: "ride",
    target_id: rideId,
    ride_id: rideId,
    driver_id: driverId || null,
    before,
    after: {
      settlement: fin,
      wallet_settlement_applied: afterWalletApplied ?? null,
      driver_wallet_ledger: afterDriverLedger ?? null,
    },
    created_at: Date.now(),
  });

  if (!fin.success && fin.reason !== "already_settled" && fin.skipped !== true) {
    return {
      success: false,
      reason: fin.reason || "settlement_failed",
      ride_id: rideId,
      detail: fin,
    };
  }

  return {
    success: true,
    reason: fin.reason || "settled",
    ride_id: rideId,
    input_ride_id: rawRideId !== rideId ? rawRideId : null,
    resolved_via: resolved.resolved_via,
    idempotent: fin.idempotent === true,
    settlement: fin,
  };
}

module.exports = {
  adminApplyRiderTripCredit,
  adminApplyDriverWalletCredit,
  adminRepairCompletedRideSettlement,
};

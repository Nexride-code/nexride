/**
 * Admin finance adjustments — audited, server-only wallet mutations.
 */

const adminPerms = require("./admin_permissions");
const adminAuditLog = require("./admin_audit_log");
const { createWalletTransactionInternal } = require("./wallet_core");

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

module.exports = {
  adminApplyRiderTripCredit,
  adminApplyDriverWalletCredit,
};

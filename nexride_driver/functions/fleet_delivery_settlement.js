/**
 * Delivery earnings settlement:
 * - business_managed / fleet-linked drivers → fleet business wallet only (not driver RTDB wallet)
 * - independent drivers → driver RTDB wallet
 */

const admin = require("firebase-admin");
const { logger } = require("firebase-functions");
const { applyFleetWalletCreditOnce } = require("./fleet_wallet");
const { creditDriverNetOnce } = require("./ride_finance_settlement");
const { deliveryHasVerifiedOnlinePayment } = require("./delivery_callables");
const {
  DEFAULT_COMMISSION_RATE,
  commissionRateFromEntity,
  resolveFleetOwnerCommissionRate,
} = require("./app_config_pricing");

function normUid(uid) {
  return String(uid ?? "").trim();
}

function nowMs() {
  return Date.now();
}

function roundNgn(n) {
  return Math.round(Math.max(0, Number(n) || 0));
}

function deliveryTripFareNgn(row) {
  if (!row || typeof row !== "object") return 0;
  const candidates = [row.fare, row.trip_fare_ngn, row.trip_fare, row.delivery_fee_ngn];
  for (const c of candidates) {
    const n = Number(c);
    if (Number.isFinite(n) && n > 0) return roundNgn(n);
  }
  return 0;
}

function computeDeliveryDriverNetNgn(row, commissionExempt, commissionRate = DEFAULT_COMMISSION_RATE) {
  const tripFare = deliveryTripFareNgn(row);
  if (tripFare <= 0) return 0;
  const rate =
    Number.isFinite(Number(commissionRate)) && Number(commissionRate) >= 0
      ? Number(commissionRate)
      : DEFAULT_COMMISSION_RATE;
  const commission = commissionExempt ? 0 : roundNgn(tripFare * rate);
  return Math.max(0, tripFare - commission);
}

function fleetBusinessIdFromDriverProfile(profile) {
  if (!profile || typeof profile !== "object") return "";
  const mode = String(profile.ownership_mode ?? profile.ownershipMode ?? "")
    .trim()
    .toLowerCase();
  if (mode !== "business_managed") return "";
  return normUid(profile.business_id ?? profile.businessId);
}

/**
 * Idempotent: fleet_delivery_earnings_ledger/{fleetId}/{deliveryId} + Firestore fleet_wallet_ledger.
 * Commission is charged to the fleet business — not the assigned biker's subscription policy.
 * @param {import("firebase-admin/database").Database} db
 */
async function settleFleetLinkedDeliveryEarningOnce(
  db,
  { deliveryId, deliveryRow, driverId, source, fs: fsOverride },
) {
  const delId = normUid(deliveryId);
  const did = normUid(driverId);
  if (!delId || !did) {
    return { success: true, reason: "skipped_invalid", idempotent: true };
  }

  const driverSnap = await db.ref(`drivers/${did}`).get();
  const profile =
    driverSnap.val() && typeof driverSnap.val() === "object" ? driverSnap.val() : {};
  const fleetId = fleetBusinessIdFromDriverProfile(profile);
  if (!fleetId) {
    return { success: true, reason: "not_fleet_managed", idempotent: true };
  }

  if (!deliveryHasVerifiedOnlinePayment(deliveryRow)) {
    console.log(
      "DELIVERY_WALLET_CREDIT_BLOCKED",
      `deliveryId=${delId}`,
      `driverId=${did}`,
      `reason=payment_not_verified`,
    );
    return { success: false, reason: "payment_not_verified", idempotent: true };
  }

  const fleetCommissionRate = await resolveFleetOwnerCommissionRate(db, fleetId, fsOverride);
  const commissionExempt = fleetCommissionRate === 0;
  const fleetNet = computeDeliveryDriverNetNgn(
    deliveryRow,
    commissionExempt,
    fleetCommissionRate,
  );
  if (fleetNet <= 0) {
    return { success: true, reason: "skipped_zero", idempotent: true };
  }

  const ledgerRef = db.ref(`fleet_delivery_earnings_ledger/${fleetId}/${delId}`);
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
    return { pending: true, at: nowMs(), source: source || "delivery_completed" };
  });

  if (!lock.committed) {
    if (lockReason === "already_applied") {
      return { success: true, reason: "already_applied", idempotent: true };
    }
    return { success: false, reason: lockReason };
  }

  const fs = fsOverride || admin.firestore();
  const cr = await applyFleetWalletCreditOnce(fs, fleetId, fleetNet, `delivery_earning_${delId}`, {
    type: "delivery_fleet_net_earning",
    delivery_id: delId,
    driver_id: did,
    amount_ngn: fleetNet,
    source: source || "delivery_completed",
  });

  if (!cr.success) {
    try {
      await ledgerRef.remove();
    } catch (_) {
      /* ignore */
    }
    return cr;
  }

  await ledgerRef.update({
    completed: true,
    amount_ngn: fleetNet,
    driver_id: did,
    fleet_business_id: fleetId,
    credited_at: nowMs(),
    source: source || "delivery_completed",
  });

  logger.info("FLEET_DELIVERY_EARNING_CREDITED", {
    fleetId,
    deliveryId: delId,
    driverId: did,
    amount_ngn: fleetNet,
  });
  console.log(
    "DELIVERY_WALLET_CREDITED",
    `deliveryId=${delId}`,
    `driverId=${did}`,
    `fleetId=${fleetId}`,
    `amount_ngn=${fleetNet}`,
  );

  return {
    success: true,
    reason: "credited",
    fleet_business_id: fleetId,
    delivery_id: delId,
    driver_id: did,
    amount_ngn: fleetNet,
  };
}

/**
 * Idempotent: driver_wallet_ledger/{driverId}/{deliveryId}_driver_net + wallets/{driverId}.
 * Skipped when the assigned driver is fleet-managed (payout goes to fleet wallet instead).
 * @param {import("firebase-admin/database").Database} db
 */
async function settleIndependentDeliveryDriverEarningOnce(
  db,
  { deliveryId, deliveryRow, driverId, source },
) {
  const delId = normUid(deliveryId);
  const did = normUid(driverId);
  if (!delId || !did) {
    return { success: true, reason: "skipped_invalid", idempotent: true };
  }

  const driverSnap = await db.ref(`drivers/${did}`).get();
  const profile =
    driverSnap.val() && typeof driverSnap.val() === "object" ? driverSnap.val() : {};
  if (fleetBusinessIdFromDriverProfile(profile)) {
    return { success: true, reason: "fleet_managed_skipped", idempotent: true };
  }

  if (!deliveryHasVerifiedOnlinePayment(deliveryRow)) {
    console.log(
      "DELIVERY_WALLET_CREDIT_BLOCKED",
      `deliveryId=${delId}`,
      `driverId=${did}`,
      `reason=payment_not_verified`,
    );
    return { success: false, reason: "payment_not_verified", idempotent: true };
  }

  const commissionRate = commissionRateFromEntity(deliveryRow);
  const driverNet = computeDeliveryDriverNetNgn(deliveryRow, false, commissionRate);
  if (driverNet <= 0) {
    return { success: true, reason: "skipped_zero", idempotent: true };
  }

  const credit = await creditDriverNetOnce(db, did, delId, driverNet, source || "delivery_completed");
  if (!credit.success && credit.reason !== "already_applied") {
    return credit;
  }

  logger.info("INDEPENDENT_DELIVERY_EARNING_CREDITED", {
    deliveryId: delId,
    driverId: did,
    amount_ngn: driverNet,
  });
  console.log(
    "DELIVERY_WALLET_CREDITED",
    `deliveryId=${delId}`,
    `driverId=${did}`,
    `walletPath=wallets/${did}`,
    `amount_ngn=${driverNet}`,
  );

  return {
    success: true,
    reason: credit.reason === "already_applied" ? "already_applied" : "credited",
    idempotent: credit.reason === "already_applied",
    delivery_id: delId,
    driver_id: did,
    amount_ngn: driverNet,
    wallet_path: `wallets/${did}`,
  };
}

module.exports = {
  deliveryTripFareNgn,
  computeDeliveryDriverNetNgn,
  fleetBusinessIdFromDriverProfile,
  settleFleetLinkedDeliveryEarningOnce,
  settleIndependentDeliveryDriverEarningOnce,
};

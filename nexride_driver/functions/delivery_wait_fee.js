/**
 * Dispatch delivery waiting fee — ₦250 after 5 minutes at pickup (driver_arriving_pickup).
 * Idempotent per delivery via wait_fee_applied + wait_fee_applied_keys.
 */

const DELIVERY_WAIT_FEE_NGN = 250;
const DELIVERY_WAIT_GRACE_MS = 5 * 60 * 1000;

function normUid(v) {
  return String(v ?? "").trim();
}

function num(v, fallback = 0) {
  const n = Number(v);
  return Number.isFinite(n) ? n : fallback;
}

function nowMs() {
  return Date.now();
}

/**
 * Start the 5-minute grace window when the driver reaches pickup.
 */
async function startDeliveryWaitFeeWindow(db, deliveryId, row = {}) {
  const rid = normUid(deliveryId);
  if (!rid) return { ok: false, reason: "invalid_delivery_id" };
  if (num(row.wait_fee_started_at, 0) > 0) {
    return { ok: true, reason: "already_started", idempotent: true };
  }
  const now = nowMs();
  const graceUntil = now + DELIVERY_WAIT_GRACE_MS;
  await db.ref(`delivery_requests/${rid}`).update({
    wait_fee_started_at: now,
    wait_fee_grace_until: graceUntil,
    wait_fee_applied: false,
    wait_fee_total: 0,
    wait_fee_status: "pending",
    wait_fee_payment_status: "pending",
    updated_at: now,
  });
  console.log(
    "DELIVERY_WAIT_FEE_PENDING",
    `deliveryId=${rid}`,
    `grace_until=${graceUntil}`,
    `amount=${DELIVERY_WAIT_FEE_NGN}`,
  );
  return { ok: true, reason: "wait_fee_pending", grace_until: graceUntil };
}

/**
 * Apply the single ₦250 waiting fee once grace has elapsed (callable or internal).
 */
async function applyDeliveryWaitFeeIfDue(data, context, db) {
  const uid = normUid(context?.auth?.uid);
  if (!uid) return { success: false, reason: "unauthorized" };

  const deliveryId = normUid(data?.deliveryId ?? data?.delivery_id);
  if (!deliveryId) return { success: false, reason: "invalid_delivery_id" };

  const ref = db.ref(`delivery_requests/${deliveryId}`);
  const snap = await ref.get();
  const row = snap.val();
  if (!row || typeof row !== "object") {
    return { success: false, reason: "delivery_missing" };
  }

  const customerId = normUid(row.customer_id ?? row.customerId);
  const driverId = normUid(row.driver_id ?? row.driverId);
  const isCustomer = customerId === uid;
  const isDriver = driverId === uid;
  if (!isCustomer && !isDriver) {
    return { success: false, reason: "forbidden" };
  }

  const startedAt = num(row.wait_fee_started_at, 0);
  if (startedAt <= 0) {
    return { success: false, reason: "wait_fee_not_started" };
  }

  const graceUntil = num(row.wait_fee_grace_until, startedAt + DELIVERY_WAIT_GRACE_MS);
  const now = nowMs();
  if (now < graceUntil) {
    return {
      success: true,
      reason: "grace_active",
      grace_until: graceUntil,
      remaining_ms: graceUntil - now,
    };
  }

  if (row.wait_fee_applied === true || num(row.wait_fee_total, 0) >= DELIVERY_WAIT_FEE_NGN) {
    return {
      success: true,
      reason: "already_applied",
      idempotent: true,
      wait_fee_total: num(row.wait_fee_total, DELIVERY_WAIT_FEE_NGN),
    };
  }

  const idemKey = `delivery_wait_fee_${deliveryId}`;
  const idemRef = db.ref(`wait_fee_applied_keys/${idemKey}`);
  const idemSnap = await idemRef.get();
  if (idemSnap.exists()) {
    return { success: true, reason: "already_applied", idempotent: true };
  }

  const prevFare = num(row.fare ?? row.amount_ngn, 0);
  const nextFare = prevFare + DELIVERY_WAIT_FEE_NGN;
  const patch = {
    wait_fee_applied: true,
    wait_fee_total: DELIVERY_WAIT_FEE_NGN,
    wait_fee_status: "applied",
    wait_fee_payment_status: "pending",
    wait_fee_applied_at: now,
    wait_fee_last_applied_at: now,
    fare: nextFare,
    amount_ngn: nextFare,
    total_ngn: num(row.total_ngn, nextFare) > 0 ? num(row.total_ngn, nextFare) + DELIVERY_WAIT_FEE_NGN : nextFare,
    updated_at: now,
  };
  const fareBreakdown =
    row.fare_breakdown && typeof row.fare_breakdown === "object"
      ? { ...row.fare_breakdown }
      : {};
  fareBreakdown.waitingCharge = DELIVERY_WAIT_FEE_NGN;
  fareBreakdown.deliveryWaitFeeNgn = DELIVERY_WAIT_FEE_NGN;
  patch.fare_breakdown = fareBreakdown;

  await idemRef.set({
    delivery_id: deliveryId,
    amount_ngn: DELIVERY_WAIT_FEE_NGN,
    applied_at: now,
  });
  await ref.update(patch);

  console.log(
    "DELIVERY_WAIT_FEE_APPLIED",
    `deliveryId=${deliveryId}`,
    `amount=${DELIVERY_WAIT_FEE_NGN}`,
    `customerId=${customerId}`,
    `driverId=${driverId}`,
  );

  return {
    success: true,
    reason: "applied",
    wait_fee_total: DELIVERY_WAIT_FEE_NGN,
    fare: nextFare,
  };
}

/**
 * Mark waiting fee paid or carry forward to customer's next delivery.
 */
async function finalizeDeliveryWaitFeeOnTerminal(db, deliveryId, row, { paid = false } = {}) {
  const rid = normUid(deliveryId);
  const customerId = normUid(row?.customer_id ?? row?.customerId);
  if (!rid || num(row?.wait_fee_total, 0) <= 0) {
    return { ok: true, reason: "no_wait_fee" };
  }
  const now = nowMs();
  if (paid || row.wait_fee_payment_status === "paid") {
    await db.ref(`delivery_requests/${rid}`).update({
      wait_fee_payment_status: "paid",
      wait_fee_status: "paid",
      wait_fee_paid_at: now,
      updated_at: now,
    });
    console.log("DELIVERY_WAIT_FEE_PAID", `deliveryId=${rid}`, `amount=${row.wait_fee_total}`);
    return { ok: true, reason: "paid" };
  }
  await db.ref(`delivery_requests/${rid}`).update({
    wait_fee_payment_status: "carried_forward",
    wait_fee_status: "carried_forward",
    wait_fee_carried_forward_at: now,
    updated_at: now,
  });
  if (customerId) {
    const custRef = db.ref(`customers/${customerId}/outstanding_delivery_wait_fee_ngn`);
    const custSnap = await custRef.get();
    const cur = num(custSnap.val(), 0);
    await custRef.set(cur + num(row.wait_fee_total, DELIVERY_WAIT_FEE_NGN));
  }
  console.log(
    "DELIVERY_WAIT_FEE_CARRIED_FORWARD",
    `deliveryId=${rid}`,
    `customerId=${customerId}`,
    `amount=${row.wait_fee_total}`,
  );
  return { ok: true, reason: "carried_forward" };
}

async function readCustomerOutstandingDeliveryWaitFee(db, customerId) {
  const cid = normUid(customerId);
  if (!cid) return 0;
  const snap = await db.ref(`customers/${cid}/outstanding_delivery_wait_fee_ngn`).get();
  return num(snap.val(), 0);
}

/**
 * Zero outstanding carry-forward after rider pays a delivery that included it.
 */
async function clearCustomerOutstandingDeliveryWaitFee(db, customerId, { source = "payment" } = {}) {
  const cid = normUid(customerId);
  if (!cid) return { ok: true, reason: "no_customer" };
  const ref = db.ref(`customers/${cid}/outstanding_delivery_wait_fee_ngn`);
  const snap = await ref.get();
  const cur = num(snap.val(), 0);
  if (cur <= 0) {
    return { ok: true, reason: "already_clear", amount: 0 };
  }
  await ref.set(0);
  console.log(
    "DELIVERY_WAIT_FEE_PAID",
    `customerId=${cid}`,
    `cleared_outstanding=${cur}`,
    `source=${source}`,
  );
  return { ok: true, reason: "cleared", amount: cur };
}

/**
 * Mark in-delivery waiting fee paid when full delivery payment is verified.
 */
async function markDeliveryWaitFeePaidOnPaymentVerified(db, deliveryId, row = {}) {
  const rid = normUid(deliveryId);
  if (!rid || num(row.wait_fee_total, 0) <= 0) {
    return { ok: true, reason: "no_wait_fee" };
  }
  if (row.wait_fee_payment_status === "paid") {
    return { ok: true, reason: "already_paid", idempotent: true };
  }
  const now = nowMs();
  await db.ref(`delivery_requests/${rid}`).update({
    wait_fee_payment_status: "paid",
    wait_fee_status: "paid",
    wait_fee_paid_at: now,
    updated_at: now,
  });
  console.log(
    "DELIVERY_WAIT_FEE_PAID",
    `deliveryId=${rid}`,
    `amount=${row.wait_fee_total}`,
    `source=payment_verified`,
  );
  return { ok: true, reason: "paid" };
}

module.exports = {
  DELIVERY_WAIT_FEE_NGN,
  DELIVERY_WAIT_GRACE_MS,
  startDeliveryWaitFeeWindow,
  applyDeliveryWaitFeeIfDue,
  finalizeDeliveryWaitFeeOnTerminal,
  readCustomerOutstandingDeliveryWaitFee,
  clearCustomerOutstandingDeliveryWaitFee,
  markDeliveryWaitFeePaidOnPaymentVerified,
};

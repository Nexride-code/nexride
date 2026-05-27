/**
 * Card ride payments: authorize before matching, capture on completion, void on cancel.
 * Bank-transfer flows are unchanged (see ride_callables payment gates).
 */

const { flutterwaveSecretForVerify } = require("./params");
const { verifyFlutterwavePaymentStrict } = require("./flutterwave_api");

const CARD_AUTHORIZED_STATUSES = new Set([
  "card_authorized",
  "preauthorized",
  "paid",
  "verified",
  "prepaid",
  "card_captured",
]);

const CARD_BLOCKED_MATCH_STATUSES = new Set([
  "card_authorizing",
  "card_authorization_failed",
  "card_capture_pending",
  "card_void_pending",
  "card_voided",
  "card_authorization_released",
  "failed",
  "declined",
]);

function normUid(uid) {
  return String(uid ?? "").trim();
}

function nowMs() {
  return Date.now();
}

function isCardPaymentMethod(method) {
  const m = String(method ?? "")
    .trim()
    .toLowerCase()
    .replace(/[\s-]+/g, "_");
  return (
    m === "card" ||
    m === "flutterwave" ||
    m === "credit_card" ||
    m === "creditcard" ||
    m === "debit_card"
  );
}

function cardPaymentStatus(ride) {
  return String(ride?.payment_status ?? ride?.paymentStatus ?? "")
    .trim()
    .toLowerCase();
}

function cardPaymentAllowsMatching(ride) {
  if (!ride || typeof ride !== "object") {
    return false;
  }
  if (!isCardPaymentMethod(ride.payment_method ?? ride.paymentMethod)) {
    return false;
  }
  const status = cardPaymentStatus(ride);
  if (CARD_BLOCKED_MATCH_STATUSES.has(status)) {
    return false;
  }
  return CARD_AUTHORIZED_STATUSES.has(status);
}

async function resolveRiderCardToken(db, riderId, paymentMethodId) {
  const uid = normUid(riderId);
  if (!uid) {
    return null;
  }
  let methodKey = String(paymentMethodId ?? "").trim();
  if (!methodKey) {
    const userSnap = await db.ref(`users/${uid}`).get();
    const user = userSnap.val();
    if (user && typeof user === "object") {
      methodKey = String(user.defaultPaymentMethodId ?? user.default_payment_method_id ?? "").trim();
    }
  }
  const methodsSnap = await db.ref(`users/${uid}/payment_methods`).get();
  const methods = methodsSnap.val();
  if (!methods || typeof methods !== "object") {
    return null;
  }
  if (methodKey && methods[methodKey] && typeof methods[methodKey] === "object") {
    const row = methods[methodKey];
    const token = String(row.token_ref ?? row.authorization_code ?? "").trim();
    if (token) {
      return { methodId: methodKey, token, brand: String(row.brand ?? "Card").trim() };
    }
  }
  for (const [key, row] of Object.entries(methods)) {
    if (!row || typeof row !== "object") {
      continue;
    }
    const isDefault = row.isDefault === true || row.is_default === true;
    const token = String(row.token_ref ?? row.authorization_code ?? "").trim();
    if (isDefault && token) {
      return { methodId: key, token, brand: String(row.brand ?? "Card").trim() };
    }
  }
  for (const [key, row] of Object.entries(methods)) {
    if (!row || typeof row !== "object") {
      continue;
    }
    const token = String(row.token_ref ?? row.authorization_code ?? "").trim();
    if (token) {
      return { methodId: key, token, brand: String(row.brand ?? "Card").trim() };
    }
  }
  return null;
}

async function flutterwaveTokenizedCharge({ token, email, amount, currency, txRef, meta }) {
  const secret = String(flutterwaveSecretForVerify() || "").trim();
  if (!secret) {
    return { ok: false, reason: "flutterwave_secret_missing" };
  }
  const chargeAmount = Number(amount);
  if (!Number.isFinite(chargeAmount) || chargeAmount <= 0) {
    return { ok: false, reason: "invalid_amount" };
  }
  const body = {
    token: String(token).trim(),
    email: String(email || "rider@nexride.local").trim(),
    amount: chargeAmount,
    currency: String(currency || "NGN").trim().toUpperCase() || "NGN",
    tx_ref: String(txRef).trim(),
    narration: "NexRide trip card authorization",
    meta: meta && typeof meta === "object" ? meta : {},
  };
  let response;
  let payload = {};
  try {
    response = await fetch("https://api.flutterwave.com/v3/tokenized-charges", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${secret}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(body),
    });
    payload = await response.json().catch(() => ({}));
  } catch (error) {
    return { ok: false, reason: "network_error", error: String(error?.message || error) };
  }
  const providerStatus = String(payload?.status ?? "").trim().toLowerCase();
  const data = payload?.data && typeof payload.data === "object" ? payload.data : {};
  const dataStatus = String(data.status ?? "").trim().toLowerCase();
  const ok =
    response.ok &&
    providerStatus === "success" &&
    (dataStatus === "successful" || dataStatus === "success");
  return {
    ok,
    reason: ok ? undefined : String(payload?.message || dataStatus || providerStatus || "charge_failed"),
    payload,
    flwTransactionId: String(data.id ?? "").trim(),
    flwRef: String(data.flw_ref ?? data.flwRef ?? "").trim(),
    txRef: String(data.tx_ref ?? txRef).trim(),
    authorization:
      data.authorization && typeof data.authorization === "object" ? data.authorization : {},
  };
}

async function flutterwaveRefundTransaction(transactionId, amount) {
  const secret = String(flutterwaveSecretForVerify() || "").trim();
  const id = String(transactionId ?? "").trim();
  if (!secret || !/^\d+$/.test(id)) {
    return { ok: false, reason: "invalid_transaction_id" };
  }
  const body = {};
  const amt = Number(amount);
  if (Number.isFinite(amt) && amt > 0) {
    body.amount = amt;
  }
  let response;
  let payload = {};
  try {
    response = await fetch(`https://api.flutterwave.com/v3/transactions/${encodeURIComponent(id)}/refund`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${secret}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(body),
    });
    payload = await response.json().catch(() => ({}));
  } catch (error) {
    return { ok: false, reason: "network_error", error: String(error?.message || error) };
  }
  const providerStatus = String(payload?.status ?? "").trim().toLowerCase();
  const ok = response.ok && providerStatus === "success";
  return { ok, reason: ok ? undefined : String(payload?.message || "refund_failed"), payload };
}

/**
 * Authorize (tokenized charge) estimated fare before ride row + matching.
 */
async function authorizeCardForRideCreation({
  db,
  riderId,
  context,
  data,
  pricing,
  currency,
  rideId,
}) {
  const uid = normUid(riderId);
  const chargeAmount = Number(pricing?.total_ngn ?? data?.total_ngn ?? data?.totalNgn ?? 0);
  const email = String(
    data?.email ?? context?.auth?.token?.email ?? `${uid}@nexride.local`,
  ).trim();
  const paymentMethodId = String(
    data?.payment_method_id ?? data?.paymentMethodId ?? "",
  ).trim();

  const card = await resolveRiderCardToken(db, uid, paymentMethodId);
  if (!card?.token) {
    console.log("CARD_AUTH_FAIL", `riderId=${uid}`, "reason=no_linked_card");
    return { ok: false, reason: "card_not_linked" };
  }

  const txRefKey = db.ref("payment_transactions").push().key;
  const tx_ref = txRefKey
    ? `nexride_cardauth_${rideId || nowMs()}_${txRefKey}`
    : `nexride_cardauth_${rideId || nowMs()}`;

  console.log(
    "CARD_AUTH_START",
    `riderId=${uid}`,
    `rideId=${rideId || ""}`,
    `tx_ref=${tx_ref}`,
    `amount=${chargeAmount}`,
    `methodId=${card.methodId || ""}`,
  );

  await db.ref(`payment_transactions/${tx_ref}`).set({
    tx_ref,
    rider_id: uid,
    ride_id: rideId || null,
    amount: chargeAmount,
    currency: String(currency || "NGN").trim().toUpperCase() || "NGN",
    status: "card_authorizing",
    card_authorization: true,
    payment_method_id: card.methodId || null,
    verified: false,
    created_at: nowMs(),
    updated_at: nowMs(),
  });

  const charge = await flutterwaveTokenizedCharge({
    token: card.token,
    email,
    amount: chargeAmount,
    currency,
    txRef: tx_ref,
    meta: {
      rider_id: uid,
      ride_id: rideId || "",
      card_authorization: "1",
    },
  });

  if (!charge.ok) {
    console.log(
      "CARD_AUTH_FAIL",
      `riderId=${uid}`,
      `rideId=${rideId || ""}`,
      `tx_ref=${tx_ref}`,
      `reason=${charge.reason || "charge_failed"}`,
    );
    await db.ref(`payment_transactions/${tx_ref}`).update({
      status: "card_authorization_failed",
      failure_reason: String(charge.reason || "charge_failed").slice(0, 240),
      updated_at: nowMs(),
    });
    return { ok: false, reason: "card_authorization_failed", tx_ref };
  }

  const authorizationRef = String(
    charge.authorization?.authorization_code ?? card.token,
  ).trim();
  const flwTransactionId = String(charge.flwTransactionId || "").trim();
  const flwRef = String(charge.flwRef || "").trim();

  await db.ref(`payment_transactions/${tx_ref}`).update({
    status: "card_authorized",
    verified: true,
    transaction_id: flwTransactionId || null,
    flutterwave_transaction_id: flwTransactionId || null,
    flw_ref: flwRef || null,
    authorization_ref: authorizationRef || null,
    updated_at: nowMs(),
  });

  console.log(
    "CARD_AUTH_OK",
    `riderId=${uid}`,
    `rideId=${rideId || ""}`,
    `tx_ref=${tx_ref}`,
    `flw_id=${flwTransactionId || ""}`,
  );

  return {
    ok: true,
    tx_ref,
    flw_ref: flwRef,
    authorization_ref: authorizationRef,
    payment_intent_id: tx_ref,
    payment_transaction_id: flwTransactionId,
    payment_method_id: card.methodId || null,
    payment_method: "card",
    payment_status: "card_authorized",
  };
}

async function rollbackCardAuthorization(db, auth) {
  const tx_ref = String(auth?.tx_ref ?? "").trim();
  const flwId = String(auth?.payment_transaction_id ?? "").trim();
  if (!tx_ref && !flwId) {
    return { ok: false, reason: "nothing_to_rollback" };
  }
  console.log("CARD_AUTH_ROLLBACK", `tx_ref=${tx_ref}`, `flw_id=${flwId}`);
  let refund = { ok: false, reason: "skipped" };
  if (flwId) {
    refund = await flutterwaveRefundTransaction(flwId);
  }
  if (tx_ref) {
    await db.ref(`payment_transactions/${tx_ref}`).update({
      status: refund.ok ? "card_voided" : "card_void_pending",
      void_attempted_at: nowMs(),
      updated_at: nowMs(),
    });
  }
  if (!refund.ok && flwId) {
    console.log("CARD_VOID_FAIL", `flw_id=${flwId}`, `reason=${refund.reason || ""}`);
    return { ok: false, reason: refund.reason || "void_failed" };
  }
  if (refund.ok) {
    console.log("CARD_VOID_OK", `flw_id=${flwId}`, `tx_ref=${tx_ref}`);
  }
  return { ok: refund.ok, reason: refund.reason };
}

async function captureRideCardOnCompletion({ db, rideId, ride }) {
  const rid = normUid(rideId);
  if (!ride || !isCardPaymentMethod(ride.payment_method ?? ride.paymentMethod)) {
    return { ok: true, reason: "not_card_ride" };
  }
  const status = cardPaymentStatus(ride);
  if (status === "card_captured" || status === "paid" || status === "verified") {
    return { ok: true, reason: "already_captured" };
  }
  if (!CARD_AUTHORIZED_STATUSES.has(status)) {
    return { ok: false, reason: "card_not_authorized" };
  }

  const txRef = String(
    ride.payment_intent_id ??
      ride.customer_transaction_reference ??
      ride.payment_reference ??
      "",
  ).trim();
  const flwId = String(
    ride.payment_transaction_id ?? ride.flw_tx_id ?? ride.flw_ref ?? "",
  ).trim();

  console.log("CARD_CAPTURE_START", `rideId=${rid}`, `tx_ref=${txRef}`, `flw_id=${flwId}`);

  if (flwId) {
    const v = await verifyFlutterwavePaymentStrict({
      transactionId: flwId,
      txRef,
      expect: {
        expectedTxRef: txRef || undefined,
        expectedCurrency: String(ride.currency ?? "NGN").trim().toUpperCase() || "NGN",
      },
    });
    if (!v.ok) {
      console.log("CARD_CAPTURE_FAIL", `rideId=${rid}`, `reason=${v.reason || "verify_failed"}`);
      return { ok: false, reason: v.reason || "capture_verify_failed" };
    }
  }

  const now = nowMs();
  await db.ref(`ride_requests/${rid}`).update({
    payment_status: "card_captured",
    payment_confirmed: true,
    card_captured_at: now,
    updated_at: now,
  });
  if (txRef) {
    await db.ref(`payment_transactions/${txRef}`).update({
      status: "card_captured",
      ride_id: rid,
      updated_at: now,
    });
  }
  console.log("CARD_CAPTURE_OK", `rideId=${rid}`, `tx_ref=${txRef}`);
  return { ok: true, reason: "card_captured" };
}

async function voidRideCardOnCancel({ db, rideId, ride }) {
  if (!ride || !isCardPaymentMethod(ride.payment_method ?? ride.paymentMethod)) {
    return { ok: true, reason: "not_card_ride" };
  }
  const status = cardPaymentStatus(ride);
  if (status === "card_voided" || status === "card_authorization_released") {
    return { ok: true, reason: "already_voided" };
  }
  if (!CARD_AUTHORIZED_STATUSES.has(status) && status !== "card_authorizing") {
    return { ok: true, reason: "not_voidable_status" };
  }

  const rid = normUid(rideId);
  const flwId = String(
    ride.payment_transaction_id ?? ride.flw_tx_id ?? "",
  ).trim();
  const txRef = String(
    ride.payment_intent_id ??
      ride.customer_transaction_reference ??
      ride.payment_reference ??
      "",
  ).trim();

  console.log("CARD_VOID_START", `rideId=${rid}`, `tx_ref=${txRef}`, `flw_id=${flwId}`);

  let refund = { ok: true, reason: "no_flw_id" };
  if (flwId) {
    refund = await flutterwaveRefundTransaction(flwId);
  }

  const now = nowMs();
  const nextStatus = refund.ok ? "card_voided" : "card_void_pending";
  await db.ref(`ride_requests/${rid}`).update({
    payment_status: refund.ok ? "card_voided" : "card_void_pending",
    card_void_attempted_at: now,
    updated_at: now,
  });
  if (txRef) {
    await db.ref(`payment_transactions/${txRef}`).update({
      status: nextStatus,
      updated_at: now,
    });
  }

  if (refund.ok) {
    console.log("CARD_VOID_OK", `rideId=${rid}`, `flw_id=${flwId}`);
    return { ok: true, reason: "card_voided" };
  }
  console.log("CARD_VOID_FAIL", `rideId=${rid}`, `reason=${refund.reason || ""}`);
  return { ok: false, reason: refund.reason || "void_failed" };
}

module.exports = {
  CARD_AUTHORIZED_STATUSES,
  CARD_BLOCKED_MATCH_STATUSES,
  isCardPaymentMethod,
  cardPaymentAllowsMatching,
  authorizeCardForRideCreation,
  rollbackCardAuthorization,
  captureRideCardOnCompletion,
  voidRideCardOnCancel,
};

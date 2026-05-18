/**
 * Flutterwave dynamic virtual-account bank transfer intents (server-side only).
 * Manual proof / static corporate account flows are not used for newly issued intents.
 */

"use strict";

const crypto = require("crypto");
const admin = require("firebase-admin");
const { FieldValue } = require("firebase-admin/firestore");
const { logger } = require("firebase-functions");
const { normUid } = require("./admin_auth");
const { createDynamicNgnVirtualAccount } = require("./flutterwave_api");
const payDiag = require("./payment_diagnostics_store");

const INTENT_COLLECTION = "payment_intents";

/** Minimum VA window shown to riders/drivers/merchants. */
const MIN_VA_EXPIRY_MS = 15 * 60 * 1000;
/** Legacy fallback when ETA is unknown (still capped for UX). */
const DEFAULT_VA_EXPIRY_MS = 30 * 60 * 1000;

function nowMs() {
  return Date.now();
}

function makeVaTxRef(segment) {
  const safe = String(segment || "x")
    .replace(/[^a-zA-Z0-9_]/g, "")
    .slice(0, 24);
  const suffix = crypto.randomBytes(5).toString("hex");
  return `nexride_va_${safe}_${Date.now().toString(36)}_${suffix}`;
}

function extractFlutterwaveProviderMessage(provider) {
  if (!provider || typeof provider !== "object") {
    return null;
  }
  return String(provider.message || provider.status || "").trim() || null;
}

/**
 * Rider-facing VA TTL: max(15 minutes, trip ETA / 2). Ignores long provider defaults (~119m).
 * @param {{ etaMinutes?: number|null|undefined }} opts
 */
function computeVaExpiryMs({ etaMinutes } = {}) {
  const now = nowMs();
  const etaMin = Number(etaMinutes);
  const etaHalfMs =
    Number.isFinite(etaMin) && etaMin > 0 ? (etaMin / 2) * 60 * 1000 : 0;
  const ttlMs = Math.max(MIN_VA_EXPIRY_MS, etaHalfMs);
  return now + ttlMs;
}

function parseExpiryMsFromVaPayload(normalized, payload) {
  const d = payload?.data && typeof payload.data === "object" ? payload.data : {};
  const raw =
    normalized?.expires_at ||
    d.expiry_date ||
    d.expires_at ||
    d.expiry_duration ||
    "";
  const s = String(raw || "").trim();
  if (!s) return 0;
  const asNum = Number(s);
  if (Number.isFinite(asNum) && asNum > 1e12) return asNum;
  const t = Date.parse(s.replace(" ", "T"));
  if (!Number.isFinite(t)) return 0;
  return t;
}

async function appendIntentAudit(fs, txRef, evt) {
  const r = String(txRef || "").trim();
  if (!r) return;
  await fs.collection(INTENT_COLLECTION).doc(r).collection("audit_events").add({
    ...evt,
    created_at: FieldValue.serverTimestamp(),
  });
}

/**
 * @param {FirebaseFirestore.Firestore} fs
 */
async function upsertIntentDoc(fs, fields) {
  const txRef = String(fields.tx_ref || "").trim();
  if (!txRef) throw new Error("missing_tx_ref");
  const ref = fs.collection(INTENT_COLLECTION).doc(txRef);
  await ref.set(
    {
      ...fields,
      updated_at: FieldValue.serverTimestamp(),
    },
    { merge: true },
  );
}

/**
 * Persist a failed attempt so admin / ops can inspect without RTDB rows.
 */
async function recordFailedPaymentIntent(fs, fields) {
  const txRef = String(fields.tx_ref || "").trim();
  if (!txRef) return;
  try {
    await fs.collection(INTENT_COLLECTION).doc(txRef).set(
      {
        ...fields,
        tx_ref: txRef,
        status: fields.status ?? "failed",
        settlement_state: fields.settlement_state ?? "failed",
        provider: fields.provider ?? "flutterwave_va",
        created_at: fields.created_at ?? FieldValue.serverTimestamp(),
        updated_at: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
  } catch (e) {
    logger.warn("recordFailedPaymentIntent_failed", { tx_ref: txRef, err: String(e) });
  }
}

/**
 * Rider ride or dispatch row: create VA + Firestore intent + RTDB payment_transactions.
 */
async function createRiderBankVaIntent({
  db,
  fs,
  riderId,
  rideId,
  deliveryId,
  totalNgn,
  currency,
  feeBreakdown,
  email,
  phone,
  firstName,
  lastName,
  narration,
  etaMinutes,
}) {
  const rid = normUid(riderId);
  const flow = rideId ? "ride_payment" : "dispatch_payment";
  const tx_ref = makeVaTxRef(rideId ? "ride" : "del");
  const expFallback = computeVaExpiryMs({ etaMinutes });

  const fwBody = {
    email: email || `${rid}@nexride.local`,
    amount: Math.round(Number(totalNgn) * 100) / 100,
    tx_ref,
    phonenumber: String(phone || "08000000000").replace(/\D/g, "").slice(0, 11) || "08000000000",
    firstname: String(firstName || "NexRide").slice(0, 80),
    lastname: String(lastName || "Customer").slice(0, 80),
    narration: String(narration || "NexRide trip").slice(0, 120),
  };

  const va = await createDynamicNgnVirtualAccount(fwBody);
  if (!va.ok || !va.normalized?.account_number) {
    const reason = va.reason || "flutterwave_va_failed";
    const reason_code =
      reason === "flutterwave_secret_missing"
        ? "flutterwave_secret_not_in_runtime"
        : va.reason_code ||
          (reason === "network_error" ? "flutterwave_network_error" : "flutterwave_va_create_failed");
    const clientReason =
      reason === "flutterwave_secret_missing" || reason === "network_error"
        ? "payment_provider_unavailable"
        : "flutterwave_va_failed";
    const user_message =
      reason === "flutterwave_secret_missing" || reason === "network_error"
        ? "Automated bank transfer is temporarily unavailable. Please use a card or try again in a moment."
        : "Bank transfer could not be set up. Please try again or pick another payment method.";
    logger.warn("RIDER_VA_CREATE_FAIL", {
      tx_ref,
      reason,
      reason_code,
      http: va.http_status,
      flutterwave_message: extractFlutterwaveProviderMessage(va.payload),
      provider_payload_snippet: JSON.stringify(va.payload ?? {}).slice(0, 5000),
    });
    payDiag.recordVaCreateFailure({
      flow,
      rider_id: rid,
      tx_ref,
      reason,
      reason_code,
      provider_http_status: va.http_status ?? null,
      flutterwave_message: extractFlutterwaveProviderMessage(va.payload),
    });
    await recordFailedPaymentIntent(fs, {
      tx_ref,
      owner_uid: rid,
      rider_id: rid,
      app_context: "rider",
      flow,
      ride_id: rideId ? normUid(rideId) : null,
      delivery_id: deliveryId ? normUid(deliveryId) : null,
      provider: "flutterwave_va",
      reason_code,
      payment_failure_reason: reason,
      flutterwave_http_status: va.http_status ?? null,
    });
    const flutterwave_message = extractFlutterwaveProviderMessage(va.payload);
    return {
      success: false,
      reason: clientReason,
      reason_code,
      message: user_message,
      user_message,
      flutterwave_message,
      provider_http_status: va.http_status ?? null,
      flutterwave_http_status: va.http_status ?? null,
    };
  }

  const n = va.normalized;
  const ts = nowMs();
  const providerExp = parseExpiryMsFromVaPayload(n, va.payload);
  let expMs = computeVaExpiryMs({ etaMinutes });
  if (providerExp > ts && providerExp < expMs) {
    expMs = providerExp;
  }

  const rtdbRow = {
    tx_ref,
    app_context: "rider",
    flow,
    rider_id: rid,
    ride_id: rideId ? normUid(rideId) : null,
    delivery_id: deliveryId ? normUid(deliveryId) : null,
    amount: totalNgn,
    total_ngn: totalNgn,
    amount_ngn: totalNgn,
    currency: String(currency || "NGN")
      .trim()
      .toUpperCase() || "NGN",
    fee_breakdown: feeBreakdown ?? null,
    status: "pending_transfer",
    verified: false,
    provider: "flutterwave_va",
    va_intent: true,
    bank_name: n.bank_name || null,
    account_name: n.account_name || null,
    account_number: n.account_number || null,
    flutterwave_order_ref: n.order_ref || null,
    va_expires_at_ms: expMs,
    expires_at_ms: expMs,
    flutterwave_va_create_response: va.payload?.data || null,
    created_at: ts,
    updated_at: ts,
  };

  await db.ref(`payment_transactions/${tx_ref}`).set(rtdbRow);
  await upsertIntentDoc(fs, {
    tx_ref,
    owner_uid: rid,
    app_context: "rider",
    flow,
    ride_id: rideId || null,
    delivery_id: deliveryId || null,
    amount_ngn: totalNgn,
    total_ngn: totalNgn,
    currency: rtdbRow.currency,
    status: "pending_transfer",
    expires_at_ms: expMs,
    settlement_state: "awaiting_transfer",
    account_number: n.account_number,
    bank_name: n.bank_name,
    account_name: n.account_name,
    flutterwave_order_ref: n.order_ref || null,
    legacy_manual_bank: false,
    webhook_status: null,
    created_at: FieldValue.serverTimestamp(),
  });
  await appendIntentAudit(fs, tx_ref, { type: "va_issued", source: "createRiderBankVaIntent" });

  return {
    success: true,
    tx_ref,
    amount: totalNgn,
    total_ngn: totalNgn,
    currency: rtdbRow.currency,
    expires_at_ms: expMs,
    bank_name: n.bank_name,
    account_name: n.account_name,
    account_number: n.account_number,
    flutterwave_order_ref: n.order_ref || null,
    instructions: "Transfer exactly the shown amount into the virtual account. Payment confirms automatically.",
  };
}

/**
 * Merchant wallet top-up via VA — reuses RTDB purpose `merchant_wallet_topup` so existing
 * `charge.completed` webhook + finalize path credits the wallet Idempotently.
 */
async function createMerchantBankVaTopUpIntent({
  db,
  fs,
  merchantId,
  ownerUid,
  amount,
  email,
  phone,
  firstName,
  lastName,
}) {
  const mid = normUid(merchantId);
  const oid = normUid(ownerUid);
  const tx_ref = makeVaTxRef("mwtop");
  const expFallback = computeVaExpiryMs({});

  const fwBody = {
    email: email || `${oid}@nexride.local`,
    amount: Math.round(Number(amount) * 100) / 100,
    tx_ref,
    phonenumber: String(phone || "08000000000").replace(/\D/g, "").slice(0, 11) || "08000000000",
    firstname: String(firstName || "NexRide").slice(0, 80),
    lastname: String(lastName || "Merchant").slice(0, 80),
    narration: `Merchant wallet ${mid.slice(0, 8)}`,
  };

  const va = await createDynamicNgnVirtualAccount(fwBody);
  if (!va.ok || !va.normalized?.account_number) {
    const rawReason = va.reason || "flutterwave_va_failed";
    const reason_code =
      rawReason === "flutterwave_secret_missing"
        ? "flutterwave_secret_not_in_runtime"
        : va.reason_code ||
          (rawReason === "network_error" ? "flutterwave_network_error" : "flutterwave_va_create_failed");
    const user_message =
      rawReason === "flutterwave_secret_missing" || rawReason === "network_error"
        ? "Automated bank transfer is temporarily unavailable. Use card top-up or try again in a moment."
        : "Bank transfer top-up could not be created. Try again or use card.";
    logger.warn("MERCHANT_VA_CREATE_FAIL", {
      tx_ref,
      merchant_id: mid,
      owner_uid: oid,
      reason: rawReason,
      reason_code,
      provider_http_status: va.http_status ?? null,
      flutterwave_message: extractFlutterwaveProviderMessage(va.payload),
      provider_payload_snippet: JSON.stringify(va.payload ?? {}).slice(0, 5000),
    });
    payDiag.recordVaCreateFailure({
      flow: "merchant_wallet_topup",
      merchant_id: mid,
      owner_uid: oid,
      tx_ref,
      reason: rawReason,
      reason_code,
      provider_http_status: va.http_status ?? null,
      flutterwave_message: extractFlutterwaveProviderMessage(va.payload),
    });
    await recordFailedPaymentIntent(fs, {
      tx_ref,
      owner_uid: oid,
      merchant_id: mid,
      app_context: "merchant",
      flow: "merchant_wallet_topup",
      provider: "flutterwave_va",
      reason_code,
      payment_failure_reason: rawReason,
      flutterwave_http_status: va.http_status ?? null,
    });
    return {
      success: false,
      reason:
        rawReason === "flutterwave_secret_missing" || rawReason === "network_error"
          ? "payment_provider_unavailable"
          : "flutterwave_va_failed",
      message: user_message,
      user_message,
      reason_code,
      flutterwave_message: extractFlutterwaveProviderMessage(va.payload),
      provider_http_status: va.http_status ?? null,
      flutterwave_http_status: va.http_status ?? null,
    };
  }
  const n = va.normalized;
  const providerExpLegacy = parseExpiryMsFromVaPayload(n, va.payload);
  let expMs = expFallback;
  if (providerExpLegacy > nowMs() && providerExpLegacy < expMs) {
    expMs = providerExpLegacy;
  }
  const ts = nowMs();
  const col = fs.collection("merchant_bank_topups");
  const docRef = col.doc();
  const requestId = docRef.id;

  await docRef.set({
    merchant_id: mid,
    owner_uid: oid,
    app_context: "merchant",
    amount_ngn: amount,
    currency: "NGN",
    status: "pending_transfer",
    tx_ref,
    reference: tx_ref,
    va_account_number: n.account_number,
    va_bank_name: n.bank_name,
    va_account_name: n.account_name,
    flutterwave_order_ref: n.order_ref || null,
    expires_at_ms: expMs,
    proof_storage_path: null,
    proof_uploaded_at: null,
    automated_va: true,
    created_at: FieldValue.serverTimestamp(),
    updated_at: FieldValue.serverTimestamp(),
  });

  await db.ref(`payment_transactions/${tx_ref}`).set({
    tx_ref,
    app_context: "merchant",
    purpose: "merchant_wallet_topup",
    flow: "merchant_topup",
    provider: "flutterwave_va",
    va_intent: true,
    merchant_id: mid,
    owner_uid: oid,
    merchant_bank_topup_id: requestId,
    ride_id: null,
    delivery_id: null,
    rider_id: null,
    amount,
    amount_ngn: amount,
    total_ngn: amount,
    currency: "NGN",
    status: "pending_transfer",
    verified: false,
    va_expires_at_ms: expMs,
    expires_at_ms: expMs,
    flutterwave_va_create_response: va.payload?.data || null,
    created_at: ts,
    updated_at: ts,
  });

  await upsertIntentDoc(fs, {
    tx_ref,
    owner_uid: oid,
    app_context: "merchant",
    flow: "merchant_wallet_topup",
    merchant_id: mid,
    merchant_bank_topup_id: requestId,
    amount_ngn: amount,
    total_ngn: amount,
    currency: "NGN",
    status: "pending_transfer",
    expires_at_ms: expMs,
    settlement_state: "awaiting_transfer",
    account_number: n.account_number,
    bank_name: n.bank_name,
    account_name: n.account_name,
    flutterwave_order_ref: n.order_ref || null,
    legacy_manual_bank: false,
    created_at: FieldValue.serverTimestamp(),
  });
  await appendIntentAudit(fs, tx_ref, { type: "va_issued", source: "createMerchantBankVaTopUpIntent" });

  return {
    success: true,
    request_id: requestId,
    amount_ngn: amount,
    currency: "NGN",
    expires_at_ms: expMs,
    tx_ref,
    reference: tx_ref,
    bank: {
      bank_name: n.bank_name,
      account_name: n.account_name,
      account_number: n.account_number,
    },
    status: "pending_transfer",
    instructions: "Transfer exactly the shown amount. Your wallet credits automatically when Flutterwave confirms.",
  };
}

/**
 * Driver subscription or driver wallet top-up via dynamic VA.
 * @param {object} opts
 * @param {string} opts.purpose `driver_subscription_payment` | `driver_wallet_topup`
 * @param {string} opts.flow `driver_subscription` | `driver_wallet_topup`
 * @param {string|null} [opts.subscriptionPlanType] weekly | monthly when purpose is subscription
 */
async function createDriverBankVaIntent({
  db,
  fs,
  driverId,
  ownerUid,
  amount,
  purpose,
  flow,
  subscriptionPlanType,
  email,
  phone,
  firstName,
  lastName,
  narration,
}) {
  const did = normUid(driverId);
  const oid = normUid(ownerUid);
  const purposeStr = String(purpose || "").trim();
  const flowStr = String(flow || "").trim();
  if (!did || !oid) {
    return { success: false, reason: "invalid_driver" };
  }
  if (
    (purposeStr === "driver_subscription_payment" && flowStr !== "driver_subscription") ||
    (purposeStr === "driver_wallet_topup" && flowStr !== "driver_wallet_topup")
  ) {
    return { success: false, reason: "flow_purpose_mismatch" };
  }
  const tx_ref = makeVaTxRef(flowStr === "driver_wallet_topup" ? "dwtop" : "dsub");
  const expFallback = computeVaExpiryMs({});

  const fwBody = {
    email: email || `${oid}@nexride.local`,
    amount: Math.round(Number(amount) * 100) / 100,
    tx_ref,
    phonenumber: String(phone || "08000000000").replace(/\D/g, "").slice(0, 11) || "08000000000",
    firstname: String(firstName || "NexRide").slice(0, 80),
    lastname: String(lastName || "Driver").slice(0, 80),
    narration: String(narration || "NexRide driver").slice(0, 120),
  };

  const va = await createDynamicNgnVirtualAccount(fwBody);
  if (!va.ok || !va.normalized?.account_number) {
    const rawReason = va.reason || "flutterwave_va_failed";
    const reason_code =
      rawReason === "flutterwave_secret_missing"
        ? "flutterwave_secret_not_in_runtime"
        : va.reason_code ||
          (rawReason === "network_error" ? "flutterwave_network_error" : "flutterwave_va_create_failed");
    const user_message =
      rawReason === "flutterwave_secret_missing" || rawReason === "network_error"
        ? "Automated bank transfer is temporarily unavailable. Try again in a moment or use card payment."
        : "Bank transfer could not be created. Please try again.";
    logger.warn("DRIVER_VA_CREATE_FAIL", {
      tx_ref,
      driver_id: did,
      reason: rawReason,
      reason_code,
      purpose: purposeStr,
      provider_http_status: va.http_status ?? null,
      flutterwave_message: extractFlutterwaveProviderMessage(va.payload),
      provider_payload_snippet: JSON.stringify(va.payload ?? {}).slice(0, 5000),
    });
    payDiag.recordVaCreateFailure({
      flow: flowStr,
      driver_id: did,
      owner_uid: oid,
      purpose: purposeStr,
      tx_ref,
      reason: rawReason,
      reason_code,
      provider_http_status: va.http_status ?? null,
      flutterwave_message: extractFlutterwaveProviderMessage(va.payload),
    });
    await recordFailedPaymentIntent(fs, {
      tx_ref,
      owner_uid: oid,
      driver_id: did,
      app_context: "driver",
      flow: flowStr,
      purpose: purposeStr,
      provider: "flutterwave_va",
      reason_code,
      payment_failure_reason: rawReason,
      flutterwave_http_status: va.http_status ?? null,
    });
    return {
      success: false,
      reason:
        rawReason === "flutterwave_secret_missing" || rawReason === "network_error"
          ? "payment_provider_unavailable"
          : "flutterwave_va_failed",
      message: user_message,
      user_message,
      reason_code,
      flutterwave_message: extractFlutterwaveProviderMessage(va.payload),
      provider_http_status: va.http_status ?? null,
      flutterwave_http_status: va.http_status ?? null,
    };
  }
  const n = va.normalized;
  const providerExpLegacy = parseExpiryMsFromVaPayload(n, va.payload);
  let expMs = expFallback;
  if (providerExpLegacy > nowMs() && providerExpLegacy < expMs) {
    expMs = providerExpLegacy;
  }
  const ts = nowMs();

  const planType =
    String(subscriptionPlanType ?? "")
      .trim()
      .toLowerCase() === "weekly"
      ? "weekly"
      : purposeStr === "driver_subscription_payment"
        ? "monthly"
        : null;

  const rtdbRow = {
    tx_ref,
    app_context: "driver",
    flow: flowStr,
    purpose: purposeStr,
    provider: "flutterwave_va",
    va_intent: true,
    driver_id: did,
    owner_uid: oid,
    amount,
    amount_ngn: amount,
    total_ngn: amount,
    currency: "NGN",
    status: "pending_transfer",
    verified: false,
    bank_name: n.bank_name || null,
    account_name: n.account_name || null,
    account_number: n.account_number || null,
    flutterwave_order_ref: n.order_ref || null,
    va_expires_at_ms: expMs,
    expires_at_ms: expMs,
    flutterwave_va_create_response: va.payload?.data || null,
    created_at: ts,
    updated_at: ts,
  };
  if (planType) {
    rtdbRow.subscription_plan_type = planType;
  }

  await db.ref(`payment_transactions/${tx_ref}`).set(rtdbRow);

  const intentFields = {
    tx_ref,
    owner_uid: oid,
    app_context: "driver",
    flow: flowStr,
    driver_id: did,
    amount_ngn: amount,
    total_ngn: amount,
    currency: "NGN",
    status: "pending_transfer",
    expires_at_ms: expMs,
    settlement_state: "awaiting_transfer",
    account_number: n.account_number,
    bank_name: n.bank_name,
    account_name: n.account_name,
    flutterwave_order_ref: n.order_ref || null,
    legacy_manual_bank: false,
    provider: "flutterwave_va",
    purpose: purposeStr,
    created_at: FieldValue.serverTimestamp(),
  };
  if (planType) {
    intentFields.subscription_plan_type = planType;
  }
  await upsertIntentDoc(fs, intentFields);
  await appendIntentAudit(fs, tx_ref, { type: "va_issued", source: "createDriverBankVaIntent", purpose: purposeStr });

  return {
    success: true,
    amount_ngn: amount,
    currency: "NGN",
    expires_at_ms: expMs,
    tx_ref,
    reference: tx_ref,
    bank: {
      bank_name: n.bank_name,
      account_name: n.account_name,
      account_number: n.account_number,
    },
    status: "pending_transfer",
    instructions: "Transfer exactly the shown amount. Payment confirms automatically when Flutterwave verifies.",
  };
}

/**
 * After strict API verify: if intent expired, mark pending_review instead of auto-settling.
 * @returns {{ mode: "ok" } | { mode: "pending_review", reason: string }}
 */
async function evaluateVaIntentExpiryForSettlement({
  fs,
  txRef,
  webhookLabel,
}) {
  const ref = String(txRef || "").trim();
  if (!ref) return { mode: "ok" };
  const docRef = fs.collection(INTENT_COLLECTION).doc(ref);
  const snap = await docRef.get();
  if (!snap.exists) return { mode: "ok" };
  const row = snap.data() || {};
  if (row.legacy_manual_bank === true) return { mode: "ok" };
  const exp = Number(row.expires_at_ms ?? 0) || 0;
  if (exp > 0 && nowMs() > exp) {
    await docRef.set(
      {
        status: "pending_review",
        settlement_state: "late_transfer_after_expiry",
        updated_at: FieldValue.serverTimestamp(),
        last_webhook_event: webhookLabel || "charge.completed",
      },
      { merge: true },
    );
    await appendIntentAudit(fs, ref, {
      type: "late_transfer_flagged",
      reason: "after_expiry",
      expires_at_ms: exp,
    });
    return { mode: "pending_review", reason: "late_transfer_after_expiry" };
  }
  return { mode: "ok" };
}

/**
 * Entity updates when a VA transfer arrives after intent expiry (wallet must not auto-credit).
 */
async function applyVaLateTransferPendingReview(db, fs, { pt, payTid, rideId, deliveryId, webhookBody }) {
  const now = nowMs();
  const tid = String(payTid || "").trim();
  const purpose = pt && typeof pt === "object" ? String(pt.purpose || "").trim() : "";

  if (purpose === "merchant_wallet_topup" && pt.merchant_bank_topup_id) {
    await fs
      .collection("merchant_bank_topups")
      .doc(String(pt.merchant_bank_topup_id))
      .set(
        {
          status: "pending_review",
          settlement_note: "late_transfer_after_va_expiry",
          late_flutterwave_transaction_id: tid,
          last_webhook_event: String(webhookBody?.event || ""),
          updated_at: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
    return;
  }

  const driverLateId = normUid(pt?.driver_id);
  if (purpose === "driver_subscription_payment" && driverLateId) {
    await db.ref(`drivers/${driverLateId}/businessModel/subscription`).update({
      paymentStatus: "late_transfer_review",
      late_flutterwave_transaction_id: tid || null,
      last_webhook_event: String(webhookBody?.event || ""),
      updatedAt: now,
    });
    return;
  }
  if (purpose === "driver_wallet_topup" && driverLateId) {
    await db.ref(`drivers/${driverLateId}`).update({
      wallet_flutterwave_late_review: true,
      wallet_flutterwave_late_tx_id: tid || null,
      updated_at: now,
    });
    return;
  }

  if (rideId) {
    await db.ref(`ride_requests/${rideId}`).update({
      payment_status: "pending_review",
      payment_review_reason: "late_va_transfer_after_expiry",
      flutterwave_transaction_id_seen: tid || null,
      updated_at: now,
    });
    const activeSnap = await db.ref(`active_trips/${rideId}`).get();
    if (activeSnap.exists()) {
      await db.ref(`active_trips/${rideId}`).update({
        payment_status: "pending_review",
        updated_at: now,
      });
    }
    return;
  }

  if (deliveryId) {
    await db.ref(`delivery_requests/${deliveryId}`).update({
      payment_status: "pending_review",
      payment_review_reason: "late_va_transfer_after_expiry",
      flutterwave_transaction_id_seen: tid || null,
      updated_at: now,
    });
  }
}

/**
 * Mark intent paid after successful settlement (idempotent patch).
 */
async function markIntentSettledOk(fs, txRef, fields) {
  const ref = String(txRef || "").trim();
  if (!ref) return;
  const now = Date.now();
  await fs.collection(INTENT_COLLECTION).doc(ref).set(
    {
      status: "paid",
      settlement_state: "settled",
      webhook_result: "settled",
      webhook_applied_at_ms: now,
      ...fields,
      updated_at: FieldValue.serverTimestamp(),
    },
    { merge: true },
  );
  await appendIntentAudit(fs, ref, { type: "settled", ...fields });
}

/**
 * Periodic sweeper — marks unpaid Flutterwave VA intents expired and mirrors
 * `bank_transfer_expired` / Firestore merchant top-ups so riders are not stuck
 * in pending_transfer indefinitely.
 *
 * Legacy manual intents (`legacy_manual_bank`) are untouched.
 *
 * @param {FirebaseFirestore.Firestore} fs
 * @param {import('firebase-admin/database').Database} db
 */
async function expireStaleBankTransferVaIntents(
  fs,
  db,
  { graceMs = 30 * 1000, scanLimit = 300 } = {},
) {
  const now = nowMs();
  const cutoff = now - Number(graceMs || 0);
  const snap = await fs
    .collection(INTENT_COLLECTION)
    .where("status", "==", "pending_transfer")
    .limit(Math.min(Math.max(1, Number(scanLimit) || 250), 500))
    .get();

  let expired = 0;
  const { normUid: normUidLocal } = require("./admin_auth");

  for (const d of snap.docs) {
    const x = d.data() || {};
    if (x.legacy_manual_bank === true) {
      continue;
    }
    const exp = Number(x.expires_at_ms ?? 0) || 0;
    if (!exp || exp > cutoff) {
      continue;
    }
    const txRef = d.id.trim();
    if (!txRef) {
      continue;
    }

    const ptSnap = await db.ref(`payment_transactions/${txRef}`).get();
    const pt = ptSnap.val() && typeof ptSnap.val() === "object" ? ptSnap.val() : null;

    await d.ref.set(
      {
        status: "expired",
        settlement_state: "intent_expired_unpaid",
        expired_at_ms: now,
        updated_at: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
    await appendIntentAudit(fs, txRef, {
      type: "intent_expired_sweeper",
      expires_at_ms: exp,
    });
    expired += 1;

    if (pt && pt.verified === true) {
      continue;
    }

    if (pt) {
      await db.ref(`payment_transactions/${txRef}`).update({
        status: "expired",
        intent_expired_at_ms: now,
        updated_at: now,
      });
    }

    const flowStr = String(x.flow ?? pt?.flow ?? "").toLowerCase();
    const rideId = normUidLocal(x.ride_id ?? pt?.ride_id);
    const deliveryId = normUidLocal(x.delivery_id ?? pt?.delivery_id);
    const topupId =
      String(pt?.merchant_bank_topup_id ?? x.merchant_bank_topup_id ?? "").trim();
    const appContext = String(x.app_context ?? pt?.app_context ?? "").trim();

    if (flowStr === "ride_payment" && rideId) {
      const rSnap = await db.ref(`ride_requests/${rideId}`).get();
      const ride = rSnap.val() && typeof rSnap.val() === "object" ? rSnap.val() : null;
      const pref = String(ride?.payment_reference ?? "").trim();
      const pref2 = String(ride?.customer_transaction_reference ?? "").trim();
      if (
        ride &&
        (pref === txRef || pref2 === txRef) &&
        String(ride.payment_status ?? "").trim().toLowerCase() === "pending_transfer"
      ) {
        const { releaseOpenRideForBankTransferFailure } = require("./ride_callables");
        await releaseOpenRideForBankTransferFailure(db, rideId, {
          cancelReason: "bank_transfer_expired",
          paymentStatus: "bank_transfer_expired",
        });
      }
    } else if (flowStr === "dispatch_payment" && deliveryId) {
      const delId = deliveryId;
      if (delId) {
        const dSnap = await db.ref(`delivery_requests/${delId}`).get();
        const del = dSnap.val() && typeof dSnap.val() === "object" ? dSnap.val() : null;
        const pref = String(del?.payment_reference ?? "").trim();
        const pref2 = String(del?.customer_transaction_reference ?? "").trim();
        if (
          del &&
          (pref === txRef || pref2 === txRef) &&
          String(del.payment_status ?? "").trim().toLowerCase() === "pending_transfer"
        ) {
          await db.ref(`delivery_requests/${delId}`).update({
            payment_status: "bank_transfer_expired",
            bank_transfer_va_expired_at: now,
            updated_at: now,
          });
        }
      }
    }

    if (appContext === "merchant" || String(pt?.purpose ?? "") === "merchant_wallet_topup") {
      if (topupId) {
        await fs
          .collection("merchant_bank_topups")
          .doc(topupId)
          .set(
            {
              status: "expired",
              settlement_note: "va_intent_timed_out",
              updated_at: FieldValue.serverTimestamp(),
            },
            { merge: true },
          );
      }
    }

    const driverIdForExpire = normUidLocal(pt?.driver_id ?? x.driver_id);
    if (
      driverIdForExpire &&
      (flowStr === "driver_subscription" || flowStr === "driver_wallet_topup")
    ) {
      if (flowStr === "driver_subscription") {
        await db.ref(`drivers/${driverIdForExpire}/businessModel/subscription`).update({
          paymentStatus: "gateway_va_expired",
          pendingTxRef: null,
          pendingExpiresAtMs: null,
          updatedAt: now,
        });
      } else {
        await db.ref(`drivers/${driverIdForExpire}`).update({
          wallet_flutterwave_pending_tx_ref: null,
          wallet_flutterwave_pending_amount_ngn: null,
          wallet_flutterwave_pending_expires_at_ms: null,
          wallet_flutterwave_pending_mode: null,
          updated_at: now,
        });
      }
    }
  }

  if (expired > 0) {
    logger.info("VA_INTENT_EXPIRE_SWEEP", { expired, cutoff, graceMs });
  }
  return { success: true, expired };
}

module.exports = {
  INTENT_COLLECTION,
  MIN_VA_EXPIRY_MS,
  computeVaExpiryMs,
  makeVaTxRef,
  upsertIntentDoc,
  createRiderBankVaIntent,
  createMerchantBankVaTopUpIntent,
  createDriverBankVaIntent,
  evaluateVaIntentExpiryForSettlement,
  applyVaLateTransferPendingReview,
  markIntentSettledOk,
  appendIntentAudit,
  recordFailedPaymentIntent,
  expireStaleBankTransferVaIntents,
};

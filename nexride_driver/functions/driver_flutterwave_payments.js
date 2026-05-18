/**
 * Driver subscription (Flutterwave) and driver wallet top-up (Flutterwave card + dynamic VA).
 * Server is source of truth for activation and wallet credits (webhook + strict verify).
 */

"use strict";

const admin = require("firebase-admin");
const { FieldValue } = require("firebase-admin/firestore");
const { logger } = require("firebase-functions");
const { normUid } = require("./admin_auth");
const {
  createHostedPaymentLink,
  verifyFlutterwavePaymentStrict,
} = require("./flutterwave_api");
const {
  flutterwavePublicKey,
  flutterwaveSecretBindingDebug,
  flutterwaveSecretForVerify,
} = require("./params");
const { buildFlutterwaveRedirectUrl } = require("./payment_redirect");
const { assertPaymentOwnership } = require("./payment_ownership");
const { createWalletTransactionInternal } = require("./wallet_core");
const { sendPushToUser } = require("./push_notifications");
const bankTransferVa = require("./bank_transfer_va");
const payDiag = require("./payment_diagnostics_store");

const MIN_WALLET_TOPUP_NGN = 100;
const MAX_WALLET_TOPUP_NGN = 5_000_000;

/** Production defaults when `app_config/pricing` is missing or invalid — must match driver app `DriverBusinessConfig`. */
const DEFAULT_WEEKLY_SUBSCRIPTION_NGN = 7000;
const DEFAULT_MONTHLY_SUBSCRIPTION_NGN = 25000;

const PURPOSE_SUBSCRIPTION = "driver_subscription_payment";
const PURPOSE_WALLET = "driver_wallet_topup";

function nowMs() {
  return Date.now();
}

function trimStr(v, max = 500) {
  return String(v ?? "")
    .trim()
    .slice(0, max);
}

function blockIfFlutterwaveSecretMissing(callableName) {
  const secret = String(flutterwaveSecretForVerify() || "").trim();
  if (secret.length > 0) {
    return null;
  }
  const secretBinding = flutterwaveSecretBindingDebug();
  logger.error(`${callableName}_blocked`, {
    callable: callableName,
    reason_code: "flutterwave_secret_not_in_runtime",
    secret_binding: secretBinding,
  });
  return {
    success: false,
    reason: "payment_provider_unavailable",
    reason_code: "flutterwave_secret_not_in_runtime",
    message:
      "Automated bank transfer is temporarily unavailable. Try again in a moment or use card payment.",
    user_message:
      "Automated bank transfer is temporarily unavailable. Try again in a moment or use card payment.",
  };
}

async function readPricingSnapshot(db) {
  const snap = await db.ref("app_config/pricing").get();
  const p = snap.val() && typeof snap.val() === "object" ? snap.val() : {};
  const weekly = Number(p.weeklySubscriptionNgn ?? p.weekly_subscription_ngn ?? 0);
  const monthly = Number(p.monthlySubscriptionNgn ?? p.monthly_subscription_ngn ?? 0);
  return {
    weekly: Number.isFinite(weekly) && weekly > 0 ? weekly : 0,
    monthly: Number.isFinite(monthly) && monthly > 0 ? monthly : 0,
  };
}

/**
 * Single source for subscription amounts (RTDB `app_config/pricing` or production defaults).
 * @param {import("firebase-admin/database").Database} db
 */
async function getResolvedDriverSubscriptionPricesNgn(db) {
  const pricing = await readPricingSnapshot(db);
  const weekly =
    pricing.weekly > 0 ? pricing.weekly : DEFAULT_WEEKLY_SUBSCRIPTION_NGN;
  const monthly =
    pricing.monthly > 0 ? pricing.monthly : DEFAULT_MONTHLY_SUBSCRIPTION_NGN;
  return {
    weekly_subscription_ngn: weekly,
    monthly_subscription_ngn: monthly,
    weekly_from_rtdb: pricing.weekly > 0,
    monthly_from_rtdb: pricing.monthly > 0,
  };
}

async function resolveSubscriptionAmountNgn(db, planTypeRaw) {
  const pt = String(planTypeRaw ?? "")
    .trim()
    .toLowerCase();
  const planType = pt === "weekly" ? "weekly" : "monthly";
  const resolved = await getResolvedDriverSubscriptionPricesNgn(db);
  const amount =
    planType === "weekly"
      ? resolved.weekly_subscription_ngn
      : resolved.monthly_subscription_ngn;
  if (
    planType === "weekly"
      ? !resolved.weekly_from_rtdb
      : !resolved.monthly_from_rtdb
  ) {
    logger.info("SUBSCRIPTION_PRICING_FALLBACK_DEFAULT", { planType, amount });
  }
  return { ok: true, planType, amount_ngn: amount };
}

/**
 * Authenticated driver: canonical weekly/monthly subscription amounts (same logic as payment callables).
 * @param {import("firebase-admin/database").Database} db
 */
async function getDriverSubscriptionPricing(_data, context, db) {
  if (!context.auth) {
    return { success: false, reason: "unauthorized" };
  }
  const ownerUid = normUid(context.auth.uid);
  const driverId = normUid(_data?.driverId ?? _data?.driver_id ?? ownerUid);
  if (driverId !== ownerUid) {
    return { success: false, reason: "unauthorized" };
  }
  const p = await getResolvedDriverSubscriptionPricesNgn(db);
  return {
    success: true,
    currency: "NGN",
    weekly_subscription_ngn: p.weekly_subscription_ngn,
    monthly_subscription_ngn: p.monthly_subscription_ngn,
    weekly_from_app_config: p.weekly_from_rtdb,
    monthly_from_app_config: p.monthly_from_rtdb,
  };
}

async function upsertDriverPaymentIntent(fs, fields) {
  await bankTransferVa.upsertIntentDoc(fs, {
    ...fields,
    currency: String(fields.currency ?? "NGN")
      .trim()
      .toUpperCase() || "NGN",
  });
}

async function writeSubscriptionGatewayPending(db, driverId, planType, amountNgn, txRef, expiresAtMs, mode) {
  const now = nowMs();
  const did = normUid(driverId);
  await db.ref().update({
    [`drivers/${did}/businessModel/selectedModel`]: "subscription",
    [`drivers/${did}/businessModel/subscription/planType`]: planType,
    [`drivers/${did}/businessModel/subscription/status`]: "pending_payment",
    [`drivers/${did}/businessModel/subscription/paymentStatus`]: "pending_gateway",
    [`drivers/${did}/businessModel/subscription/pendingTxRef`]: txRef,
    [`drivers/${did}/businessModel/subscription/pendingExpiresAtMs`]: expiresAtMs > 0 ? expiresAtMs : null,
    [`drivers/${did}/businessModel/subscription/pendingAmountNgn`]: amountNgn,
    [`drivers/${did}/businessModel/subscription/pendingPlanType`]: planType,
    [`drivers/${did}/businessModel/subscription/pendingMode`]: mode,
    [`drivers/${did}/businessModel/subscription/updatedAt`]: now,
    [`drivers/${did}/businessModel/updatedAt`]: now,
    [`drivers/${did}/updated_at`]: now,
  });
}

async function writeWalletTopUpPending(db, driverId, amountNgn, txRef, expiresAtMs, mode) {
  const did = normUid(driverId);
  const now = nowMs();
  await db.ref(`drivers/${did}`).update({
    wallet_flutterwave_pending_tx_ref: txRef,
    wallet_flutterwave_pending_amount_ngn: amountNgn,
    wallet_flutterwave_pending_expires_at_ms: expiresAtMs > 0 ? expiresAtMs : null,
    wallet_flutterwave_pending_mode: mode,
    updated_at: now,
  });
}

async function clearWalletTopUpPending(db, driverId) {
  const did = normUid(driverId);
  const now = nowMs();
  await db.ref(`drivers/${did}`).update({
    wallet_flutterwave_pending_tx_ref: null,
    wallet_flutterwave_pending_amount_ngn: null,
    wallet_flutterwave_pending_expires_at_ms: null,
    wallet_flutterwave_pending_mode: null,
    updated_at: now,
  });
}

function subscriptionActivationUpdates(driverId, planType, expiresAt) {
  const did = normUid(driverId);
  const now = nowMs();
  const expiryDateLabel = new Date(expiresAt).toLocaleDateString("en-NG", {
    day: "2-digit",
    month: "short",
    year: "numeric",
  });
  return {
    payload: {
      notification: {
        title: "Subscription active",
        body: `You now keep 100% of your trip earnings. Your plan is active until ${expiryDateLabel}.`,
      },
      data: {
        type: "subscription_status",
        status: "active",
        expires_at: String(expiresAt),
      },
    },
    updates: {
      [`drivers/${did}/subscription_pending`]: false,
      [`drivers/${did}/subscription_status`]: "active",
      [`drivers/${did}/subscription_type`]: planType,
      [`drivers/${did}/commission_exempt`]: true,
      [`drivers/${did}/subscription_renewal_reminder_sent`]: false,
      [`drivers/${did}/subscription_expires_at`]: expiresAt,
      [`drivers/${did}/subscription_proof_url`]: null,
      [`drivers/${did}/businessModel/selectedModel`]: "subscription",
      [`drivers/${did}/businessModel/subscription/planType`]: planType,
      [`drivers/${did}/businessModel/subscription/status`]: "active",
      [`drivers/${did}/businessModel/subscription/paymentStatus`]: "paid",
      [`drivers/${did}/businessModel/subscription/validUntil`]: expiresAt,
      [`drivers/${did}/businessModel/subscription/updatedAt`]: now,
      [`drivers/${did}/businessModel/commissionExempt`]: true,
      [`drivers/${did}/businessModel/commission_exempt`]: true,
      [`drivers/${did}/businessModel/updatedAt`]: now,
      [`drivers/${did}/updated_at`]: now,
      [`drivers/${did}/businessModel/subscription/pendingTxRef`]: null,
      [`drivers/${did}/businessModel/subscription/pendingExpiresAtMs`]: null,
      [`drivers/${did}/businessModel/subscription/pendingAmountNgn`]: null,
      [`drivers/${did}/businessModel/subscription/pendingPlanType`]: null,
      [`drivers/${did}/businessModel/subscription/pendingMode`]: null,
    },
  };
}

/**
 * Apply RTDB subscription activation + verified payment row + Firestore intent settled + push.
 * Call only after amount/currency/ownership checks for the payment channel.
 *
 * @param {import("firebase-admin/database").Database} db
 * @param {import("firebase-admin/firestore").Firestore} fs
 */
async function applyDriverSubscriptionSettlement(db, fs, {
  driverId,
  ownerUid,
  planType,
  expectedAmount,
  txRef,
  payTid,
  verifiedAmount,
  webhookBody,
}) {
  const refFinal = String(txRef || "").trim();
  const paid = Number(verifiedAmount ?? 0);
  const payKey = String(payTid || "").trim();
  const now = nowMs();
  const durationDays = planType === "weekly" ? 7 : 30;
  const expiresAt = nowMs() + durationDays * 24 * 60 * 60 * 1000;
  const { updates, payload } = subscriptionActivationUpdates(driverId, planType, expiresAt);
  const ptRef = db.ref(`payment_transactions/${refFinal}`);

  await db.ref().update(updates);
  await ptRef.update({
    verified: true,
    status: "verified",
    flutterwave_transaction_id: payKey,
    verified_at: now,
    updated_at: now,
    provider_status: "successful",
    verified_amount: paid,
    webhook_applied: true,
    provider_payload:
      webhookBody && typeof webhookBody === "object" ? webhookBody : { event: "driver_subscription" },
  });

  if (payKey) {
    await db.ref(`payments/${payKey}`).update({
      driver_id: driverId,
      owner_uid: ownerUid,
      purpose: PURPOSE_SUBSCRIPTION,
      verified: true,
      amount: expectedAmount,
      currency: "NGN",
      updated_at: now,
    });
  }

  if (refFinal) {
    await bankTransferVa.markIntentSettledOk(fs, refFinal, {
      flutterwave_transaction_id: payKey,
      webhook_status: "successful",
      driver_id: driverId,
      subscription_plan_type: planType,
    });
  }

  try {
    await sendPushToUser(db, driverId, payload);
  } catch (e) {
    logger.warn("DRIVER_SUBSCRIPTION_PUSH_FAIL", { driverId, err: String(e?.message || e) });
  }

  logger.info("DRIVER_SUBSCRIPTION_SETTLED", {
    driverId,
    txRef: refFinal,
    payTid: payKey,
    amount: expectedAmount,
  });
  return { success: true, reason: "activated", driver_id: driverId, amount_ngn: expectedAmount };
}

/**
 * @param {import("firebase-admin/database").Database} db
 * @param {import("firebase-admin/firestore").Firestore} fs
 */
async function finalizeDriverSubscriptionPaymentVerified(db, fs, {
  payTid,
  txRef,
  verifiedAmount,
  currency,
  webhookBody,
}) {
  const refFinal = String(txRef || "").trim();
  const ptRef = db.ref(`payment_transactions/${refFinal}`);
  const ptSnap = await ptRef.get();
  const pt = ptSnap.val() && typeof ptSnap.val() === "object" ? ptSnap.val() : {};
  if (String(pt.purpose || "").trim() !== PURPOSE_SUBSCRIPTION) {
    return { success: false, reason: "not_driver_subscription" };
  }
  if (String(pt.provider || "").trim() === "driver_wallet") {
    return { success: false, reason: "subscription_settled_via_wallet" };
  }
  if (pt.verified === true) {
    return { success: true, reason: "already_verified", idempotent: true };
  }
  const driverId = normUid(pt.driver_id ?? pt.driverId);
  const ownerUid = normUid(pt.owner_uid ?? pt.ownerUid);
  const planType = String(pt.subscription_plan_type ?? pt.plan_type ?? "monthly")
    .trim()
    .toLowerCase() === "weekly"
    ? "weekly"
    : "monthly";
  const expectedAmount = Number(pt.amount ?? 0);
  if (!driverId || !ownerUid || !Number.isFinite(expectedAmount) || expectedAmount <= 0) {
    return { success: false, reason: "invalid_payment_transaction" };
  }
  const paid = Number(verifiedAmount ?? 0);
  if (!Number.isFinite(paid) || paid + 0.01 < expectedAmount) {
    return { success: false, reason: "amount_mismatch" };
  }
  const expectCur = String(pt.currency ?? "NGN").trim().toUpperCase() || "NGN";
  const gotCur = String(currency ?? "").trim().toUpperCase() || "NGN";
  if (gotCur !== "NGN" || expectCur !== "NGN") {
    return { success: false, reason: "currency_mismatch" };
  }

  return applyDriverSubscriptionSettlement(db, fs, {
    driverId,
    ownerUid,
    planType,
    expectedAmount,
    txRef: refFinal,
    payTid,
    verifiedAmount: paid,
    webhookBody,
  });
}

/**
 * Complete subscription after an atomic driver-wallet debit (no Flutterwave).
 * Idempotent when payment_transactions row is already verified.
 *
 * @param {import("firebase-admin/database").Database} db
 * @param {import("firebase-admin/firestore").Firestore} fs
 */
async function settleDriverSubscriptionFromWalletDebit(db, fs, {
  driverId,
  ownerUid,
  planType,
  amount,
  tx_ref: txRefRaw,
}) {
  const tx_ref = String(txRefRaw || "").trim();
  const ptRef = db.ref(`payment_transactions/${tx_ref}`);
  const ptSnap = await ptRef.get();
  const pt = ptSnap.val() && typeof ptSnap.val() === "object" ? ptSnap.val() : {};
  if (pt.verified === true) {
    await db.ref(`drivers/${normUid(driverId)}/pending_wallet_subscription_tx_ref`).remove();
    return { success: true, reason: "already_verified", idempotent: true };
  }
  if (String(pt.purpose || "").trim() !== PURPOSE_SUBSCRIPTION) {
    return { success: false, reason: "not_driver_subscription" };
  }
  if (normUid(pt.driver_id ?? pt.driverId) !== normUid(driverId)) {
    return { success: false, reason: "driver_mismatch" };
  }
  if (normUid(pt.owner_uid ?? pt.ownerUid) !== normUid(ownerUid)) {
    return { success: false, reason: "owner_mismatch" };
  }
  const expectedAmount = Number(pt.amount ?? 0);
  if (!Number.isFinite(expectedAmount) || expectedAmount <= 0 || expectedAmount !== Number(amount)) {
    return { success: false, reason: "amount_mismatch" };
  }
  const idemDebit = `sub_wallet_${tx_ref}`;
  const wk = await db.ref(`wallets/${normUid(driverId)}/transactions/${idemDebit}`).get();
  if (!wk.exists()) {
    return { success: false, reason: "wallet_debit_missing" };
  }

  const now = nowMs();
  const ledgerId = `wallet_sub_${tx_ref}`;
  const ledgerRef = db.ref(`driver_wallet_ledger/${normUid(driverId)}/${ledgerId}`);
  await ledgerRef.transaction((cur) => {
    if (cur && typeof cur === "object" && cur.completed === true) {
      return cur;
    }
    return {
      type: "driver_wallet_subscription_debit",
      direction: "debit",
      amount_ngn: expectedAmount,
      currency: "NGN",
      tx_ref,
      completed: true,
      created_at: now,
      owner_uid: normUid(ownerUid),
    };
  });

  const payTid = `wallet_sub:${tx_ref}`;
  const r = await applyDriverSubscriptionSettlement(db, fs, {
    driverId: normUid(driverId),
    ownerUid: normUid(ownerUid),
    planType,
    expectedAmount,
    txRef: tx_ref,
    payTid,
    verifiedAmount: expectedAmount,
    webhookBody: { event: "driver_subscription_wallet_debit" },
  });

  await db.ref(`drivers/${normUid(driverId)}/pending_wallet_subscription_tx_ref`).remove();
  return { ...r, plan_type: planType };
}

async function tryResumeDriverWalletSubscription(db, fs, driverId, ownerUid) {
  const did = normUid(driverId);
  const ou = normUid(ownerUid);
  const pendRef = db.ref(`drivers/${did}/pending_wallet_subscription_tx_ref`);
  const tr = String((await pendRef.get()).val() || "").trim();
  if (!tr) {
    return null;
  }
  const ptRef = db.ref(`payment_transactions/${tr}`);
  const pt = (await ptRef.get()).val();
  const row = pt && typeof pt === "object" ? pt : {};
  if (String(row.purpose || "").trim() !== PURPOSE_SUBSCRIPTION || String(row.provider || "").trim() !== "driver_wallet") {
    await pendRef.remove();
    return null;
  }
  if (row.verified === true) {
    await pendRef.remove();
    const ptPlan =
      String(row.subscription_plan_type ?? row.plan_type ?? "monthly").trim().toLowerCase() === "weekly"
        ? "weekly"
        : "monthly";
    return { success: true, idempotent: true, tx_ref: tr, plan_type: ptPlan, reason: "already_paid" };
  }
  const planType = String(row.subscription_plan_type ?? row.plan_type ?? "monthly")
    .trim()
    .toLowerCase() === "weekly"
    ? "weekly"
    : "monthly";
  const amt = Number(row.amount ?? 0);
  const rowOwner = normUid(row.owner_uid ?? row.ownerUid);
  if (rowOwner !== ou) {
    return { success: false, reason: "unauthorized" };
  }
  const idemDebit = `sub_wallet_${tr}`;
  const wk = await db.ref(`wallets/${did}/transactions/${idemDebit}`).get();
  if (!wk.exists()) {
    await pendRef.remove();
    await ptRef.update({ status: "cancelled_stale", updated_at: nowMs() });
    return null;
  }
  return settleDriverSubscriptionFromWalletDebit(db, fs, {
    driverId: did,
    ownerUid: ou,
    planType,
    amount: amt,
    tx_ref: tr,
  });
}

/**
 * Debit driver wallet atomically (wallet_core) then activate subscription + ledger + payment_intent.
 *
 * @param {import("firebase-admin/database").Database} db
 */
async function driverPaySubscriptionFromWallet(data, context, db) {
  if (!context.auth) {
    return { success: false, reason: "unauthorized" };
  }
  const ownerUid = normUid(context.auth.uid);
  const driverId = normUid(data?.driverId ?? data?.driver_id ?? ownerUid);
  if (driverId !== ownerUid) {
    return { success: false, reason: "unauthorized" };
  }
  const fs = admin.firestore();
  const resumed = await tryResumeDriverWalletSubscription(db, fs, driverId, ownerUid);
  if (resumed !== null) {
    return resumed;
  }

  const resolved = await resolveSubscriptionAmountNgn(db, data?.planType ?? data?.plan_type);
  if (!resolved.ok) {
    return { success: false, reason: resolved.reason || "invalid_plan" };
  }
  const { planType, amount_ngn: amount } = resolved;

  const busyRef = db.ref(`drivers/${driverId}/subscription_wallet_pay_busy`);
  const busyTx = await busyRef.transaction((c) => (c === true ? undefined : true));
  if (!busyTx.committed) {
    return { success: false, reason: "payment_in_progress" };
  }

  const pendRef = db.ref(`drivers/${driverId}/pending_wallet_subscription_tx_ref`);

  try {
    const txRefKey = db.ref("payment_transactions").push().key;
    const tx_ref = txRefKey ? `nexride_dsub_wallet_${nowMs()}_${txRefKey}` : `nexride_dsub_wallet_${nowMs()}`;
    const ptRef = db.ref(`payment_transactions/${tx_ref}`);
    const idemDebit = `sub_wallet_${tx_ref}`;
    const now0 = nowMs();

    const existingPt = await ptRef.get();
    if (!existingPt.exists()) {
      await ptRef.set({
        tx_ref,
        app_context: "driver",
        flow: "driver_subscription",
        purpose: PURPOSE_SUBSCRIPTION,
        driver_id: driverId,
        owner_uid: ownerUid,
        subscription_plan_type: planType,
        amount,
        amount_ngn: amount,
        currency: "NGN",
        status: "pending_wallet_debit",
        provider: "driver_wallet",
        verified: false,
        created_at: now0,
        updated_at: now0,
      });
      await upsertDriverPaymentIntent(fs, {
        tx_ref,
        owner_uid: ownerUid,
        app_context: "driver",
        flow: "driver_subscription",
        driver_id: driverId,
        amount_ngn: amount,
        total_ngn: amount,
        currency: "NGN",
        status: "pending_gateway",
        expires_at_ms: null,
        provider: "driver_wallet",
        subscription_plan_type: planType,
        settlement_state: "awaiting_wallet_debit",
        legacy_manual_bank: false,
        created_at: FieldValue.serverTimestamp(),
      });
    }

    await pendRef.set(tx_ref);

    const wt = await createWalletTransactionInternal(db, {
      userId: driverId,
      amount,
      type: "driver_wallet_subscription_debit",
      idempotencyKey: idemDebit,
    });

    const failNow = nowMs();
    if (!wt.success) {
      await pendRef.remove();
      if (wt.reason === "insufficient_balance") {
        await ptRef.update({
          status: "failed_insufficient_balance",
          updated_at: failNow,
        });
        await upsertDriverPaymentIntent(fs, {
          tx_ref,
          owner_uid: ownerUid,
          app_context: "driver",
          flow: "driver_subscription",
          driver_id: driverId,
          amount_ngn: amount,
          total_ngn: amount,
          currency: "NGN",
          status: "failed",
          provider: "driver_wallet",
          subscription_plan_type: planType,
          settlement_state: "insufficient_wallet",
          legacy_manual_bank: false,
          created_at: FieldValue.serverTimestamp(),
        });
        return { success: false, reason: "insufficient_balance", amount_ngn: amount, plan_type: planType };
      }
      await ptRef.update({
        status: "failed_wallet_debit",
        wallet_error: wt.reason || null,
        updated_at: failNow,
      });
      return { success: false, reason: wt.reason || "wallet_debit_failed", tx_ref };
    }

    const settled = await settleDriverSubscriptionFromWalletDebit(db, fs, {
      driverId,
      ownerUid,
      planType,
      amount,
      tx_ref,
    });
    return { ...settled, tx_ref, amount_ngn: amount, plan_type: planType };
  } finally {
    await busyRef.remove().catch(() => {});
  }
}

/**
 * @param {import("firebase-admin/database").Database} db
 */
async function finalizeDriverWalletTopUpVerified(db, fs, {
  payTid,
  txRef,
  verifiedAmount,
  currency,
  webhookBody,
}) {
  const refFinal = String(txRef || "").trim();
  const ptRef = db.ref(`payment_transactions/${refFinal}`);
  const ptSnap = await ptRef.get();
  const pt = ptSnap.val() && typeof ptSnap.val() === "object" ? ptSnap.val() : {};
  if (String(pt.purpose || "").trim() !== PURPOSE_WALLET) {
    return { success: false, reason: "not_driver_wallet_topup" };
  }
  if (pt.verified === true) {
    return { success: true, reason: "already_verified", idempotent: true };
  }
  const driverId = normUid(pt.driver_id ?? pt.driverId);
  const ownerUid = normUid(pt.owner_uid ?? pt.ownerUid);
  const expectedAmount = Number(pt.amount ?? 0);
  if (!driverId || !ownerUid || !Number.isFinite(expectedAmount) || expectedAmount <= 0) {
    return { success: false, reason: "invalid_payment_transaction" };
  }
  const paid = Number(verifiedAmount ?? 0);
  if (!Number.isFinite(paid) || paid + 0.01 < expectedAmount) {
    return { success: false, reason: "amount_mismatch" };
  }
  const expectCur = String(pt.currency ?? "NGN").trim().toUpperCase() || "NGN";
  const gotCur = String(currency ?? "").trim().toUpperCase() || "NGN";
  if (gotCur !== "NGN" || expectCur !== "NGN") {
    return { success: false, reason: "currency_mismatch" };
  }

  const idemKey = `fw_wallet_topup_${String(payTid || "").trim()}`;
  const wt = await createWalletTransactionInternal(db, {
    userId: driverId,
    amount: expectedAmount,
    type: "driver_flutterwave_wallet_topup",
    idempotencyKey: idemKey,
  });
  if (!wt.success && wt.reason !== "already_applied") {
    return { success: false, reason: wt.reason || "wallet_credit_failed" };
  }

  const now = nowMs();
  const ledgerId = `flutterwave_wallet_topup_${String(payTid || "").trim()}`;
  const ledgerRef = db.ref(`driver_wallet_ledger/${driverId}/${ledgerId}`);
  const lex = await ledgerRef.transaction((cur) => {
    if (cur && typeof cur === "object" && cur.completed === true) {
      return undefined;
    }
    return {
      type: "flutterwave_wallet_topup",
      direction: "credit",
      amount_ngn: expectedAmount,
      currency: "NGN",
      tx_ref: refFinal,
      flutterwave_transaction_id: String(payTid || "").trim(),
      completed: true,
      created_at: now,
      owner_uid: ownerUid,
    };
  });
  if (!lex.committed) {
    logger.warn("DRIVER_WALLET_LEDGER_TX_FAIL", { driverId, ledgerId });
  }

  await ptRef.update({
    verified: true,
    status: "verified",
    flutterwave_transaction_id: payTid,
    verified_at: now,
    updated_at: now,
    provider_status: "successful",
    verified_amount: paid,
    webhook_applied: true,
    provider_payload:
      webhookBody && typeof webhookBody === "object" ? webhookBody : { event: "driver_wallet_topup" },
  });

  const payKey = String(payTid || "").trim();
  if (payKey) {
    await db.ref(`payments/${payKey}`).update({
      driver_id: driverId,
      owner_uid: ownerUid,
      purpose: PURPOSE_WALLET,
      verified: true,
      amount: expectedAmount,
      currency: "NGN",
      updated_at: now,
    });
  }

  await clearWalletTopUpPending(db, driverId);

  if (refFinal) {
    await bankTransferVa.markIntentSettledOk(fs, refFinal, {
      flutterwave_transaction_id: payTid,
      webhook_status: "successful",
      driver_id: driverId,
    });
  }

  try {
    await sendPushToUser(db, driverId, {
      notification: {
        title: "Wallet topped up",
        body: `₦${expectedAmount.toLocaleString("en-NG")} has been added to your driver wallet.`,
      },
      data: {
        type: "driver_wallet_topup",
        amount_ngn: String(expectedAmount),
        tx_ref: refFinal,
      },
    });
  } catch (e) {
    logger.warn("DRIVER_WALLET_TOPUP_PUSH_FAIL", { driverId, err: String(e?.message || e) });
  }

  logger.info("DRIVER_WALLET_FW_CREDITED", { driverId, txRef: refFinal, payTid: payKey, amount: expectedAmount });
  return { success: true, reason: "credited", driver_id: driverId, amount_ngn: expectedAmount };
}

async function verifyAndFinalizeDriverPurposeForReference(db, fs, txRef, purpose, { callerUid } = {}) {
  const ref = String(txRef || "").trim();
  if (!ref) {
    return { success: false, reason: "invalid_reference" };
  }
  const ptSnap = await db.ref(`payment_transactions/${ref}`).get();
  const pt = ptSnap.val() && typeof ptSnap.val() === "object" ? ptSnap.val() : {};
  const p = String(pt.purpose || "").trim();
  if (p !== purpose) {
    return { success: false, reason: "purpose_mismatch" };
  }
  if (pt.verified === true) {
    return {
      success: true,
      reason: "already_verified",
      idempotent: true,
      amount: Number(pt.amount || 0),
    };
  }
  const ownership = assertPaymentOwnership(pt, {
    callerUid,
    expectedAppContext: "driver",
    expectedDriverId: pt.driver_id,
  });
  if (!ownership.ok) {
    return { success: false, reason: ownership.reason, reason_code: ownership.reason_code };
  }
  const expectCur = String(pt.currency ?? "NGN").trim().toUpperCase() || "NGN";
  const minAmt = Number(pt.amount ?? 0);
  const v = await verifyFlutterwavePaymentStrict({
    transactionId: /^\d+$/.test(ref) ? ref : "",
    txRef: ref,
    expect: {
      expectedTxRef: ref,
      expectedCurrency: expectCur,
      minAmount: Number.isFinite(minAmt) && minAmt > 0 ? minAmt : undefined,
    },
  });
  if (!v.ok) {
    const failReason = String(v.reason || "verification_failed").trim();
    const cancelled =
      failReason === "cancelled" ||
      failReason === "canceled" ||
      failReason === "payment_cancelled";
    return {
      success: false,
      reason: cancelled ? "payment_cancelled" : failReason,
      reason_code: cancelled ? "payment_cancelled" : failReason,
    };
  }
  const payTid = String(v.flwTransactionId || "").trim();
  if (!payTid) {
    return { success: false, reason: "missing_transaction_id" };
  }
  if (purpose === PURPOSE_SUBSCRIPTION) {
    return finalizeDriverSubscriptionPaymentVerified(db, fs, {
      payTid,
      txRef: ref,
      verifiedAmount: v.amount,
      currency: v.currency || expectCur,
      webhookBody: { event: "callable_verify_payment", data: v.payload?.data },
    });
  }
  if (purpose === PURPOSE_WALLET) {
    return finalizeDriverWalletTopUpVerified(db, fs, {
      payTid,
      txRef: ref,
      verifiedAmount: v.amount,
      currency: v.currency || expectCur,
      webhookBody: { event: "callable_verify_payment", data: v.payload?.data },
    });
  }
  return { success: false, reason: "unsupported_purpose" };
}

async function driverStartSubscriptionFlutterwaveCard(data, context, db) {
  if (!context.auth) {
    return { success: false, reason: "unauthorized" };
  }
  const ownerUid = normUid(context.auth.uid);
  const driverId = normUid(data?.driverId ?? data?.driver_id ?? ownerUid);
  if (driverId !== ownerUid) {
    return { success: false, reason: "unauthorized" };
  }
  const resolved = await resolveSubscriptionAmountNgn(db, data?.planType ?? data?.plan_type);
  if (!resolved.ok) {
    return { success: false, reason: resolved.reason || "invalid_plan" };
  }
  const { planType, amount_ngn: amount } = resolved;
  const fs = admin.firestore();
  const txRefKey = db.ref("payment_transactions").push().key;
  const tx_ref = txRefKey ? `nexride_dsub_card_${nowMs()}_${txRefKey}` : `nexride_dsub_card_${nowMs()}`;
  const email = String(
    data?.email ?? context.auth.token?.email ?? `${ownerUid}@nexride.local`,
  ).trim();
  const redirectUrl = String(
    data?.redirect_url ??
      data?.redirectUrl ??
      buildFlutterwaveRedirectUrl({
        appContext: "driver",
        flow: "driver_subscription",
        txRef: tx_ref,
        uid: ownerUid,
      }),
  ).trim();
  const body = {
    tx_ref,
    amount,
    currency: "NGN",
    redirect_url: redirectUrl,
    payment_options: "card",
    customer: {
      email: email || `${ownerUid}@nexride.local`,
      name: String(data?.customer_name ?? data?.customerName ?? "NexRide driver").trim(),
    },
    meta: {
      purpose: PURPOSE_SUBSCRIPTION,
      driver_id: driverId,
      owner_uid: ownerUid,
      plan_type: planType,
    },
    customizations: { title: "NexRide driver subscription", description: "Support: support@nexride.africa" },
  };
  const r = await createHostedPaymentLink(body);
  if (!r.ok) {
    const reasonCode =
      r.reason_code ||
      (r.reason === "flutterwave_secret_missing"
        ? "flutterwave_secret_not_in_runtime"
        : r.reason === "network_error"
          ? "flutterwave_network_error"
          : "flutterwave_card_init_failed");
    const user_message =
      r.reason === "flutterwave_secret_missing"
        ? "Payment provider is temporarily unavailable. Try again later or use bank transfer."
        : r.reason === "network_error"
          ? "Could not reach the payment provider. Check your connection and try again."
          : "Card checkout could not be started. Try again or contact support.";
    await bankTransferVa.recordFailedPaymentIntent(fs, {
      tx_ref,
      owner_uid: ownerUid,
      driver_id: driverId,
      app_context: "driver",
      flow: "driver_subscription",
      provider: "flutterwave",
      reason_code: reasonCode,
      payment_failure_reason: r.reason || "initiate_failed",
      flutterwave_http_status: r.http_status ?? null,
    });
    logger.warn("DRIVER_SUB_CARD_INIT_FAIL", {
      reason: r.reason,
      reason_code: reasonCode,
      tx_ref,
      checkout_url: r.link || null,
      flutterwave_http_status: r.http_status ?? null,
      flutterwave_message: r.flutterwave_message ?? null,
      provider_payload_snippet: JSON.stringify(r.payload ?? {}).slice(0, 5000),
    });
    payDiag.recordCardInitFailure({
      flow: "driver_subscription",
      tx_ref,
      reason: r.reason || "initiate_failed",
      reason_code: reasonCode,
      checkout_url: r.link || null,
      flutterwave_http_status: r.http_status ?? null,
      flutterwave_message: r.flutterwave_message ?? null,
    });
    return {
      success: false,
      reason: "payment_init_failed",
      message: user_message,
      user_message,
      reason_code: reasonCode,
      flutterwave_http_status: r.http_status ?? null,
      flutterwave_message: r.flutterwave_message ?? null,
      provider: r.payload,
      tx_ref,
    };
  }
  const now = nowMs();
  await db.ref(`payment_transactions/${tx_ref}`).set({
    tx_ref,
    app_context: "driver",
    flow: "driver_subscription",
    purpose: PURPOSE_SUBSCRIPTION,
    driver_id: driverId,
    owner_uid: ownerUid,
    subscription_plan_type: planType,
    amount,
    amount_ngn: amount,
    currency: "NGN",
    status: "pending",
    provider: "flutterwave",
    provider_link: r.link,
    verified: false,
    created_at: now,
    updated_at: now,
  });
  await upsertDriverPaymentIntent(fs, {
    tx_ref,
    owner_uid: ownerUid,
    app_context: "driver",
    flow: "driver_subscription",
    driver_id: driverId,
    amount_ngn: amount,
    total_ngn: amount,
    currency: "NGN",
    status: "pending",
    expires_at_ms: null,
    provider: "flutterwave",
    subscription_plan_type: planType,
    settlement_state: "awaiting_card",
    legacy_manual_bank: false,
    created_at: FieldValue.serverTimestamp(),
  });
  await writeSubscriptionGatewayPending(db, driverId, planType, amount, tx_ref, 0, "card");
  await bankTransferVa.appendIntentAudit(fs, tx_ref, { type: "card_link_issued", source: "driver_subscription" });
  logger.info("DRIVER_SUB_CARD_INIT_OK", {
    tx_ref,
    checkout_url_present: Boolean(String(r.link || "").trim()),
    checkout_url_len: String(r.link || "").length,
    plan_type: planType,
  });
  return {
    success: true,
    tx_ref,
    amount,
    currency: "NGN",
    authorization_url: r.link,
    payment_link: r.link,
    public_key: String(flutterwavePublicKey.value() || "").trim(),
    plan_type: planType,
    reason: "initiated",
  };
}

async function driverCreateSubscriptionFlutterwaveVa(data, context, db) {
  if (!context.auth) {
    return { success: false, reason: "unauthorized" };
  }
  const secretBlock = blockIfFlutterwaveSecretMissing("driverCreateSubscriptionFlutterwaveVa");
  if (secretBlock) {
    return secretBlock;
  }
  const ownerUid = normUid(context.auth.uid);
  const driverId = normUid(data?.driverId ?? data?.driver_id ?? ownerUid);
  if (driverId !== ownerUid) {
    return { success: false, reason: "unauthorized" };
  }
  const resolved = await resolveSubscriptionAmountNgn(db, data?.planType ?? data?.plan_type);
  if (!resolved.ok) {
    return { success: false, reason: resolved.reason || "invalid_plan" };
  }
  const { planType, amount_ngn: amount } = resolved;
  const fs = admin.firestore();
  const email = String(
    data?.email ?? context.auth.token?.email ?? `${ownerUid}@nexride.local`,
  ).trim();
  const phone = String(context.auth?.token?.phone_number ?? "").trim();
  const name = String(context.auth?.token?.name ?? "").trim();
  const firstName = (name.split(/\s+/)[0] || email.split("@")[0] || "NexRide").slice(0, 80);
  const lastName = name.split(/\s+/).slice(1).join(" ").trim().slice(0, 80) || "Driver";

  const va = await bankTransferVa.createDriverBankVaIntent({
    db,
    fs,
    driverId,
    ownerUid,
    amount,
    purpose: PURPOSE_SUBSCRIPTION,
    flow: "driver_subscription",
    subscriptionPlanType: planType,
    email,
    phone,
    firstName,
    lastName,
    narration: `NexRide sub ${driverId.slice(0, 8)}`,
  });
  if (!va.success) {
    return va;
  }
  await writeSubscriptionGatewayPending(
    db,
    driverId,
    planType,
    amount,
    va.tx_ref,
    Number(va.expires_at_ms ?? 0) || 0,
    "va",
  );
  return { ...va, plan_type: planType, reason: "va_issued" };
}

async function driverStartWalletTopUpFlutterwaveCard(data, context, db) {
  if (!context.auth) {
    return { success: false, reason: "unauthorized" };
  }
  const ownerUid = normUid(context.auth.uid);
  const driverId = normUid(data?.driverId ?? data?.driver_id ?? ownerUid);
  if (driverId !== ownerUid) {
    return { success: false, reason: "unauthorized" };
  }
  const amount = Number(data?.amount_ngn ?? data?.amount ?? 0);
  const currency = String(data?.currency ?? "NGN").trim().toUpperCase() || "NGN";
  if (currency !== "NGN") {
    return { success: false, reason: "invalid_currency" };
  }
  if (!Number.isFinite(amount) || amount < MIN_WALLET_TOPUP_NGN || amount > MAX_WALLET_TOPUP_NGN) {
    return { success: false, reason: "invalid_amount" };
  }
  const fs = admin.firestore();
  const txRefKey = db.ref("payment_transactions").push().key;
  const tx_ref = txRefKey ? `nexride_dwtop_card_${nowMs()}_${txRefKey}` : `nexride_dwtop_card_${nowMs()}`;
  const email = String(
    data?.email ?? context.auth.token?.email ?? `${ownerUid}@nexride.local`,
  ).trim();
  const redirectUrl = String(
    data?.redirect_url ??
      data?.redirectUrl ??
      buildFlutterwaveRedirectUrl({
        appContext: "driver",
        flow: "driver_wallet_topup",
        txRef: tx_ref,
        uid: ownerUid,
      }),
  ).trim();
  const body = {
    tx_ref,
    amount,
    currency: "NGN",
    redirect_url: redirectUrl,
    payment_options: "card",
    customer: {
      email: email || `${ownerUid}@nexride.local`,
      name: String(data?.customer_name ?? data?.customerName ?? "NexRide driver").trim(),
    },
    meta: {
      purpose: PURPOSE_WALLET,
      driver_id: driverId,
      owner_uid: ownerUid,
    },
    customizations: { title: "NexRide driver wallet top-up", description: "Support: support@nexride.africa" },
  };
  const r = await createHostedPaymentLink(body);
  if (!r.ok) {
    const reasonCode =
      r.reason_code ||
      (r.reason === "flutterwave_secret_missing"
        ? "flutterwave_secret_not_in_runtime"
        : r.reason === "network_error"
          ? "flutterwave_network_error"
          : "flutterwave_card_init_failed");
    const user_message =
      r.reason === "flutterwave_secret_missing"
        ? "Payment provider is temporarily unavailable. Try again later or use bank transfer."
        : r.reason === "network_error"
          ? "Could not reach the payment provider. Check your connection and try again."
          : "Card checkout could not be started. Try again or contact support.";
    await bankTransferVa.recordFailedPaymentIntent(fs, {
      tx_ref,
      owner_uid: ownerUid,
      driver_id: driverId,
      app_context: "driver",
      flow: "driver_wallet_topup",
      provider: "flutterwave",
      reason_code: reasonCode,
      payment_failure_reason: r.reason || "initiate_failed",
      flutterwave_http_status: r.http_status ?? null,
    });
    logger.warn("DRIVER_WALLET_CARD_INIT_FAIL", {
      reason: r.reason,
      reason_code: reasonCode,
      tx_ref,
      checkout_url: r.link || null,
      flutterwave_http_status: r.http_status ?? null,
      flutterwave_message: r.flutterwave_message ?? null,
      provider_payload_snippet: JSON.stringify(r.payload ?? {}).slice(0, 5000),
    });
    payDiag.recordCardInitFailure({
      flow: "driver_wallet_topup",
      tx_ref,
      reason: r.reason || "initiate_failed",
      reason_code: reasonCode,
      checkout_url: r.link || null,
      flutterwave_http_status: r.http_status ?? null,
      flutterwave_message: r.flutterwave_message ?? null,
    });
    return {
      success: false,
      reason: "payment_init_failed",
      message: user_message,
      user_message,
      reason_code: reasonCode,
      flutterwave_http_status: r.http_status ?? null,
      flutterwave_message: r.flutterwave_message ?? null,
      provider: r.payload,
      tx_ref,
    };
  }
  const now = nowMs();
  await db.ref(`payment_transactions/${tx_ref}`).set({
    tx_ref,
    app_context: "driver",
    flow: "driver_wallet_topup",
    purpose: PURPOSE_WALLET,
    driver_id: driverId,
    owner_uid: ownerUid,
    amount,
    amount_ngn: amount,
    currency: "NGN",
    status: "pending",
    provider: "flutterwave",
    provider_link: r.link,
    verified: false,
    created_at: now,
    updated_at: now,
  });
  await upsertDriverPaymentIntent(fs, {
    tx_ref,
    owner_uid: ownerUid,
    app_context: "driver",
    flow: "driver_wallet_topup",
    driver_id: driverId,
    amount_ngn: amount,
    total_ngn: amount,
    currency: "NGN",
    status: "pending",
    expires_at_ms: null,
    provider: "flutterwave",
    settlement_state: "awaiting_card",
    legacy_manual_bank: false,
    created_at: FieldValue.serverTimestamp(),
  });
  await writeWalletTopUpPending(db, driverId, amount, tx_ref, 0, "card");
  await bankTransferVa.appendIntentAudit(fs, tx_ref, { type: "card_link_issued", source: "driver_wallet_topup" });
  logger.info("DRIVER_WALLET_CARD_INIT_OK", {
    tx_ref,
    checkout_url_present: Boolean(String(r.link || "").trim()),
    checkout_url_len: String(r.link || "").length,
  });
  return {
    success: true,
    tx_ref,
    amount,
    currency: "NGN",
    authorization_url: r.link,
    payment_link: r.link,
    public_key: String(flutterwavePublicKey.value() || "").trim(),
    reason: "initiated",
  };
}

async function driverCreateWalletTopUpFlutterwaveVa(data, context, db) {
  if (!context.auth) {
    return { success: false, reason: "unauthorized" };
  }
  const secretBlock = blockIfFlutterwaveSecretMissing("driverCreateWalletTopUpFlutterwaveVa");
  if (secretBlock) {
    return secretBlock;
  }
  const ownerUid = normUid(context.auth.uid);
  const driverId = normUid(data?.driverId ?? data?.driver_id ?? ownerUid);
  if (driverId !== ownerUid) {
    return { success: false, reason: "unauthorized" };
  }
  const amount = Number(data?.amount_ngn ?? data?.amount ?? 0);
  if (!Number.isFinite(amount) || amount < MIN_WALLET_TOPUP_NGN || amount > MAX_WALLET_TOPUP_NGN) {
    return { success: false, reason: "invalid_amount" };
  }
  const fs = admin.firestore();
  const email = String(
    data?.email ?? context.auth.token?.email ?? `${ownerUid}@nexride.local`,
  ).trim();
  const phone = String(context.auth?.token?.phone_number ?? "").trim();
  const name = String(context.auth?.token?.name ?? "").trim();
  const firstName = (name.split(/\s+/)[0] || email.split("@")[0] || "NexRide").slice(0, 80);
  const lastName = name.split(/\s+/).slice(1).join(" ").trim().slice(0, 80) || "Driver";

  const va = await bankTransferVa.createDriverBankVaIntent({
    db,
    fs,
    driverId,
    ownerUid,
    amount,
    purpose: PURPOSE_WALLET,
    flow: "driver_wallet_topup",
    subscriptionPlanType: null,
    email,
    phone,
    firstName,
    lastName,
    narration: `NexRide wallet ${driverId.slice(0, 8)}`,
  });
  if (!va.success) {
    return va;
  }
  await writeWalletTopUpPending(
    db,
    driverId,
    amount,
    va.tx_ref,
    Number(va.expires_at_ms ?? 0) || 0,
    "va",
  );
  return { ...va, reason: "va_issued" };
}

module.exports = {
  PURPOSE_SUBSCRIPTION,
  PURPOSE_WALLET,
  getResolvedDriverSubscriptionPricesNgn,
  getDriverSubscriptionPricing,
  finalizeDriverSubscriptionPaymentVerified,
  finalizeDriverWalletTopUpVerified,
  verifyAndFinalizeDriverPurposeForReference,
  driverPaySubscriptionFromWallet,
  settleDriverSubscriptionFromWalletDebit,
  driverStartSubscriptionFlutterwaveCard,
  driverCreateSubscriptionFlutterwaveVa,
  driverStartWalletTopUpFlutterwaveCard,
  driverCreateWalletTopUpFlutterwaveVa,
};

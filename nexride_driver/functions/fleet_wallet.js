const admin = require("firebase-admin");
const { FieldValue } = require("firebase-admin/firestore");
const { logger } = require("firebase-functions");
const { createHostedPaymentLink, createDynamicNgnVirtualAccount, verifyFlutterwavePaymentStrict } = require("./flutterwave_api");
const businessFleet = require("./business_fleet_callables");
const { buildFlutterwaveRedirectUrl } = require("./payment_redirect");
const { flutterwavePublicKey } = require("./params");
const { assertPaymentOwnership } = require("./payment_ownership");
const bankTransferVa = require("./bank_transfer_va");
const { flutterwaveSecretBindingDebug } = require("./params");
const {
  buildWithdrawalFeeFieldsForRequest,
  userConfirmedWithdrawalRequest,
} = require("./withdrawal_fee_config");

const MIN_TOPUP_NGN = 100;
const MAX_TOPUP_NGN = 5_000_000;
const FLEET_INTENT_COLLECTION = "fleet_bank_topups";

function nowMs() {
  return Date.now();
}

function normUid(uid) {
  return String(uid ?? "").trim();
}

function trimStr(v, max = 500) {
  return String(v ?? "").trim().slice(0, max);
}

function flutterwaveCheckoutCustomizations(title) {
  return { title, description: "Support: support@nexride.africa" };
}

function fleetTopUpRequestPayload(data, context) {
  const authUid = context?.auth?.uid ? normUid(context.auth.uid) : null;
  return {
    amount_ngn: data?.amount_ngn ?? data?.amount ?? null,
    email: data?.email ?? null,
    redirect_url: data?.redirect_url ?? data?.redirectUrl ?? null,
    customer_name: data?.customer_name ?? data?.customerName ?? null,
    phone: data?.phone ?? null,
    first_name: data?.first_name ?? null,
    last_name: data?.last_name ?? null,
    caller_uid: authUid,
  };
}

function fleetTopUpLog(callable, stage, fields) {
  logger.info(`${callable}_${stage}`, fields);
}

function fleetTopUpReturn(callable, response, extra = {}) {
  fleetTopUpLog(callable, "response", { ...extra, response });
  return response;
}

function fleetWalletAvailableNgn(fleet) {
  const wallet = Number(fleet?.fleet_wallet_balance_ngn ?? 0) || 0;
  return Math.max(0, wallet);
}

async function resolveFleetOwner(fs, db, context) {
  if (!context.auth) return { ok: false, reason: "unauthorized" };
  const uid = normUid(context.auth.uid);
  const resolved = await businessFleet.resolveFleetForOwnerAuth(db, fs, uid);
  if (!resolved.ok) return resolved;
  const fleet = resolved.data || {};
  const status = String(fleet.merchant_status ?? fleet.status ?? "").trim().toLowerCase();
  if (status !== "approved") return { ok: false, reason: "fleet_not_approved" };
  return { ok: true, ownerUid: uid, fleetId: resolved.id, fleet, ref: resolved.ref };
}

async function applyFleetWalletCreditOnce(fs, fleetId, amountNgn, ledgerDocId, ledgerBase) {
  const fid = normUid(fleetId);
  const amt = Number(amountNgn);
  if (!fid || !Number.isFinite(amt) || amt <= 0) return { success: false, reason: "invalid_input" };
  const fleetRef = fs.collection("merchants").doc(fid);
  const ledgerRef = fleetRef.collection("fleet_wallet_ledger").doc(ledgerDocId);
  try {
    await fs.runTransaction(async (tx) => {
      const l0 = await tx.get(ledgerRef);
      if (l0.exists) return;
      const f0 = await tx.get(fleetRef);
      if (!f0.exists) throw new Error("fleet_not_found");
      const fleet = f0.data() || {};
      const cur = Number(fleet.fleet_wallet_balance_ngn ?? 0) || 0;
      const totalFunded = Number(fleet.fleet_wallet_total_funded_ngn ?? 0) || 0;
      const next = cur + amt;
      tx.set(
        ledgerRef,
        {
          ...ledgerBase,
          direction: "credit",
          amount_ngn: amt,
          balance_after_ngn: next,
          created_at: FieldValue.serverTimestamp(),
        },
        { merge: false },
      );
      tx.set(
        fleetRef,
        {
          fleet_wallet_balance_ngn: next,
          fleet_wallet_total_funded_ngn: totalFunded + amt,
          updated_at: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
    });
  } catch (e) {
    const msg = String(e?.message || e);
    if (msg === "fleet_not_found") return { success: false, reason: "fleet_not_found" };
    logger.error("FLEET_WALLET_CREDIT_FAIL", { fleetId: fid, ledgerDocId, err: msg });
    return { success: false, reason: "transaction_failed" };
  }
  return { success: true, reason: "credited" };
}

/**
 * Authoritative fleet spendable balance (Firestore only; no RTDB fleet wallet).
 */
async function readFleetWalletBalanceNgn(fs, fleetId) {
  const fid = normUid(fleetId);
  if (!fid) return 0;
  const snap = await fs.collection("merchants").doc(fid).get();
  if (!snap.exists) return 0;
  const fleet = snap.data() || {};
  return Math.max(0, Math.round(Number(fleet.fleet_wallet_balance_ngn ?? 0) || 0));
}

async function applyFleetWithdrawalPaidDebit(fs, { fleetId, withdrawalId, amount }) {
  const fid = normUid(fleetId);
  const wid = trimStr(withdrawalId, 128);
  const amt = Math.round(Math.max(0, Number(amount) || 0));
  const ledgerId = `withdrawal_paid_${wid}`;
  if (!fid || !wid || amt <= 0) return { success: false, reason: "invalid_input" };
  const fleetRef = fs.collection("merchants").doc(fid);
  const ledgerRef = fleetRef.collection("fleet_wallet_ledger").doc(ledgerId);

  const preFleetSnap = await fleetRef.get();
  const preBalance = preFleetSnap.exists
    ? Math.max(0, Math.round(Number(preFleetSnap.data()?.fleet_wallet_balance_ngn ?? 0) || 0))
    : 0;
  const preLedgerSnap = await ledgerRef.get();
  if (preLedgerSnap.exists) {
    console.log(
      "FLEET_WITHDRAWAL_DEBIT_START",
      `withdrawalId=${wid}`,
      `fleetId=${fid}`,
      `currentBalance=${preBalance}`,
      `requestedAmount=${amt}`,
      "note=already_applied_precheck",
    );
    return {
      success: true,
      reason: "already_applied",
      idempotent: true,
      ledgerId,
    };
  }

  console.log(
    "FLEET_WITHDRAWAL_DEBIT_START",
    `withdrawalId=${wid}`,
    `fleetId=${fid}`,
    `currentBalance=${preBalance}`,
    `requestedAmount=${amt}`,
  );

  let failureReason = "unknown";
  let beforeBalance = preBalance;
  let afterBalance = preBalance;

  try {
    await fs.runTransaction(async (tx) => {
      const l0 = await tx.get(ledgerRef);
      const f0 = await tx.get(fleetRef);
      if (!f0.exists) throw new Error("fleet_not_found");
      if (l0.exists) {
        return f0.data();
      }
      const fleet = f0.data() || {};
      const balance = Math.max(0, Math.round(Number(fleet.fleet_wallet_balance_ngn ?? 0) || 0));
      beforeBalance = balance;
      const withdrawn = Number(fleet.fleet_wallet_total_withdrawn_ngn ?? 0) || 0;
      if (amt > balance) {
        failureReason = "insufficient_balance";
        console.log(
          "FLEET_WITHDRAWAL_DEBIT_ABORT",
          `withdrawalId=${wid}`,
          `reason=${failureReason}`,
          `currentBalance=${balance}`,
          `requestedAmount=${amt}`,
        );
        throw new Error("insufficient_balance");
      }
      afterBalance = balance - amt;
      tx.set(
        ledgerRef,
        {
          type: "withdrawal_paid",
          direction: "debit",
          amount_ngn: amt,
          balance_after_ngn: afterBalance,
          withdrawal_id: wid,
          created_at: FieldValue.serverTimestamp(),
        },
        { merge: false },
      );
      tx.set(
        fleetRef,
        {
          fleet_wallet_balance_ngn: afterBalance,
          fleet_wallet_total_withdrawn_ngn: withdrawn + amt,
          updated_at: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
    });
  } catch (e) {
    const msg = String(e?.message || e);
    if (msg === "insufficient_balance") {
      return { success: false, reason: "insufficient_balance" };
    }
    if (msg === "fleet_not_found") return { success: false, reason: "fleet_not_found" };
    if (failureReason === "insufficient_balance") {
      return { success: false, reason: "insufficient_balance" };
    }
    logger.error("FLEET_WALLET_DEBIT_FAIL", { fleetId: fid, withdrawalId: wid, err: msg });
    return { success: false, reason: "transaction_failed" };
  }

  const postLedger = await ledgerRef.get();
  if (!postLedger.exists) {
    return { success: false, reason: "transaction_failed" };
  }

  console.log(
    "FLEET_WITHDRAWAL_DEBIT_COMMIT",
    `withdrawalId=${wid}`,
    `beforeBalance=${beforeBalance}`,
    `afterBalance=${afterBalance}`,
    `requestedAmount=${amt}`,
  );

  return {
    success: true,
    reason: "debited",
    idempotent: false,
    ledgerId,
    balance_after_ngn: afterBalance,
  };
}

async function finalizeFleetFlutterwaveTopUpVerified(db, fs, { payTid, txRef, verifiedAmount, currency, webhookBody }) {
  const ptRef = db.ref(`payment_transactions/${txRef}`);
  const ptSnap = await ptRef.get();
  const pt = ptSnap.val() && typeof ptSnap.val() === "object" ? ptSnap.val() : {};
  if (String(pt.purpose || "").trim() !== "fleet_wallet_topup") return { success: false, reason: "not_fleet_wallet_topup" };
  if (pt.verified === true) return { success: true, reason: "already_verified", idempotent: true };
  const fleetId = normUid(pt.fleet_business_id ?? pt.fleet_id);
  const expectedAmount = Number(pt.amount ?? 0);
  if (!fleetId || !Number.isFinite(expectedAmount) || expectedAmount <= 0) {
    return { success: false, reason: "invalid_payment_transaction" };
  }
  const paid = Number(verifiedAmount ?? 0);
  if (!Number.isFinite(paid) || paid + 0.01 < expectedAmount) return { success: false, reason: "amount_mismatch" };
  const cr = await applyFleetWalletCreditOnce(fs, fleetId, expectedAmount, `flutterwave_topup_${payTid}`, {
    type: "flutterwave_wallet_topup",
    provider: "flutterwave",
    flutterwave_transaction_id: payTid,
    tx_ref: txRef,
    currency: String(currency || pt.currency || "NGN").trim().toUpperCase() || "NGN",
  });
  if (!cr.success) return cr;
  const now = nowMs();
  await ptRef.update({
    verified: true,
    status: "verified",
    flutterwave_transaction_id: payTid,
    verified_at: now,
    updated_at: now,
    provider_status: "successful",
    verified_amount: paid,
    webhook_applied: true,
    provider_payload: webhookBody && typeof webhookBody === "object" ? webhookBody : { event: "fleet_topup" },
  });
  return { success: true, reason: "credited", fleet_id: fleetId, amount_ngn: expectedAmount };
}

async function verifyAndFinalizeFleetWalletTopUpForReference(db, fs, txRef, { callerUid } = {}) {
  const ref = String(txRef || "").trim();
  if (!ref) return { success: false, reason: "invalid_reference" };
  const ptSnap = await db.ref(`payment_transactions/${ref}`).get();
  const pt = ptSnap.val() && typeof ptSnap.val() === "object" ? ptSnap.val() : {};
  if (String(pt.purpose || "").trim() !== "fleet_wallet_topup") return { success: false, reason: "not_fleet_wallet_topup" };
  if (pt.verified === true) return { success: true, reason: "already_verified", idempotent: true, amount: Number(pt.amount || 0) };
  const ownership = assertPaymentOwnership(pt, {
    callerUid,
    expectedAppContext: "fleet",
    expectedMerchantId: pt.fleet_business_id,
  });
  if (!ownership.ok) return { success: false, reason: ownership.reason, reason_code: ownership.reason_code };
  const expectCur = String(pt.currency ?? "NGN").trim().toUpperCase() || "NGN";
  const minAmt = Number(pt.amount ?? 0);
  const v = await verifyFlutterwavePaymentStrict({
    transactionId: /^\d+$/.test(ref) ? ref : "",
    txRef: ref,
    expect: { expectedTxRef: ref, expectedCurrency: expectCur, minAmount: Number.isFinite(minAmt) && minAmt > 0 ? minAmt : undefined },
  });
  if (!v.ok) return { success: false, reason: String(v.reason || "verification_failed").trim() };
  const payTid = String(v.flwTransactionId || "").trim();
  if (!payTid) return { success: false, reason: "missing_transaction_id" };
  return finalizeFleetFlutterwaveTopUpVerified(db, fs, {
    payTid,
    txRef: ref,
    verifiedAmount: v.amount,
    currency: v.currency || expectCur,
    webhookBody: { event: "callable_verify_payment", data: v.payload?.data },
  });
}

async function fleetGetWallet(data, context, db) {
  const fs = admin.firestore();
  const resolved = await resolveFleetOwner(fs, db, context);
  if (!resolved.ok) return { success: false, reason: resolved.reason || "not_found" };
  const fleet = resolved.fleet || {};
  const pendingWithdrawalsSnap = await db.ref("withdraw_requests").get();
  const wr = pendingWithdrawalsSnap.val() && typeof pendingWithdrawalsSnap.val() === "object" ? pendingWithdrawalsSnap.val() : {};
  let pending = 0;
  for (const row of Object.values(wr)) {
    if (!row || typeof row !== "object") continue;
    const entity = String(row.entity_type ?? row.entityType ?? "").trim().toLowerCase();
    const rowFleetId = normUid(row.fleet_business_id ?? row.fleet_id ?? row.merchant_id);
    const st = String(row.status ?? "").trim().toLowerCase();
    if (entity === "fleet" && rowFleetId === resolved.fleetId && (st === "pending" || st === "processing" || st === "reviewing")) {
      pending += Number(row.amount ?? 0) || 0;
    }
  }
  return {
    success: true,
    fleet_business_id: resolved.fleetId,
    balance_ngn: Number(fleet.fleet_wallet_balance_ngn ?? 0) || 0,
    total_funded_ngn: Number(fleet.fleet_wallet_total_funded_ngn ?? 0) || 0,
    total_withdrawn_ngn: Number(fleet.fleet_wallet_total_withdrawn_ngn ?? 0) || 0,
    pending_withdrawals_ngn: pending,
  };
}

async function fleetListWalletTransactions(data, context, db) {
  const fs = admin.firestore();
  const resolved = await resolveFleetOwner(fs, db, context);
  if (!resolved.ok) return { success: false, reason: resolved.reason || "not_found" };
  const limit = Math.min(100, Math.max(1, Number(data?.limit ?? 25) || 25));
  const snap = await fs
    .collection("merchants")
    .doc(resolved.fleetId)
    .collection("fleet_wallet_ledger")
    .orderBy("created_at", "desc")
    .limit(limit)
    .get();
  const transactions = snap.docs.map((d) => ({ id: d.id, ...d.data() }));
  return { success: true, transactions };
}

async function fleetCreateCardTopUp(data, context, db) {
  const callable = "fleetCreateCardTopUp";
  const requestPayload = fleetTopUpRequestPayload(data, context);
  fleetTopUpLog(callable, "request", { request: requestPayload });
  fleetTopUpLog(callable, "flutterwave_config", flutterwaveSecretBindingDebug());

  const fs = admin.firestore();
  const resolved = await resolveFleetOwner(fs, db, context);
  if (!resolved.ok) {
    fleetTopUpLog(callable, "fleet_resolved", {
      fleet_business_id: null,
      ok: false,
      reason: resolved.reason || "not_found",
    });
    return fleetTopUpReturn(callable, { success: false, reason: resolved.reason || "not_found" });
  }
  fleetTopUpLog(callable, "fleet_resolved", {
    fleet_business_id: resolved.fleetId,
    owner_uid: resolved.ownerUid,
    ok: true,
  });

  const amount = Number(data?.amount_ngn ?? data?.amount ?? 0);
  if (!Number.isFinite(amount) || amount < MIN_TOPUP_NGN || amount > MAX_TOPUP_NGN) {
    return fleetTopUpReturn(
      callable,
      { success: false, reason: "invalid_amount" },
      { fleet_business_id: resolved.fleetId },
    );
  }
  const txRefKey = db.ref("payment_transactions").push().key;
  const tx_ref = txRefKey ? `nexride_fwtop_${nowMs()}_${txRefKey}` : `nexride_fwtop_${nowMs()}`;
  const redirectUrl = String(
    data?.redirect_url ??
      data?.redirectUrl ??
      buildFlutterwaveRedirectUrl({ appContext: "fleet", flow: "fleet_topup", txRef: tx_ref, merchantId: resolved.fleetId, uid: resolved.ownerUid }),
  ).trim();
  const body = {
    tx_ref,
    amount,
    currency: "NGN",
    redirect_url: redirectUrl,
    payment_options: "card",
    customer: {
      email: String(data?.email ?? context.auth.token?.email ?? `${resolved.ownerUid}@nexride.local`).trim(),
      name: String(data?.customer_name ?? data?.customerName ?? "NexRide fleet").trim(),
    },
    meta: {
      purpose: "fleet_wallet_topup",
      fleet_business_id: resolved.fleetId,
      owner_uid: resolved.ownerUid,
    },
    customizations: flutterwaveCheckoutCustomizations("NexRide fleet wallet top-up"),
  };
  fleetTopUpLog(callable, "flutterwave_request", {
    fleet_business_id: resolved.fleetId,
    tx_ref,
    payload: body,
  });
  const r = await createHostedPaymentLink(body);
  fleetTopUpLog(callable, "flutterwave_response", {
    fleet_business_id: resolved.fleetId,
    tx_ref,
    ok: r.ok,
    reason: r.reason ?? null,
    reason_code: r.reason_code ?? null,
    http_status: r.http_status ?? null,
    checkout_url_present: Boolean(r.link),
    raw: r.payload ?? null,
  });
  if (!r.ok) {
    return fleetTopUpReturn(
      callable,
      { success: false, reason: r.reason || "payment_init_failed", provider: r.payload },
      { fleet_business_id: resolved.fleetId, tx_ref },
    );
  }
  const now = nowMs();
  await db.ref(`payment_transactions/${tx_ref}`).set({
    tx_ref,
    app_context: "fleet",
    purpose: "fleet_wallet_topup",
    flow: "fleet_topup",
    provider: "flutterwave",
    fleet_business_id: resolved.fleetId,
    owner_uid: resolved.ownerUid,
    amount,
    amount_ngn: amount,
    currency: "NGN",
    status: "pending",
    provider_link: r.link,
    verified: false,
    created_at: now,
    updated_at: now,
  });
  return fleetTopUpReturn(
    callable,
    {
      success: true,
      tx_ref,
      amount,
      currency: "NGN",
      authorization_url: r.link,
      public_key: String(flutterwavePublicKey.value() || "").trim(),
      reason: "initiated",
    },
    { fleet_business_id: resolved.fleetId, tx_ref },
  );
}

async function fleetCreateBankTransferTopUp(data, context, db) {
  const callable = "fleetCreateBankTransferTopUp";
  const requestPayload = fleetTopUpRequestPayload(data, context);
  fleetTopUpLog(callable, "request", { request: requestPayload });
  fleetTopUpLog(callable, "flutterwave_config", flutterwaveSecretBindingDebug());

  const fs = admin.firestore();
  const resolved = await resolveFleetOwner(fs, db, context);
  if (!resolved.ok) {
    fleetTopUpLog(callable, "fleet_resolved", {
      fleet_business_id: null,
      ok: false,
      reason: resolved.reason || "not_found",
    });
    return fleetTopUpReturn(callable, { success: false, reason: resolved.reason || "not_found" });
  }
  fleetTopUpLog(callable, "fleet_resolved", {
    fleet_business_id: resolved.fleetId,
    owner_uid: resolved.ownerUid,
    ok: true,
  });

  const amount = Number(data?.amount_ngn ?? data?.amount ?? 0);
  if (!Number.isFinite(amount) || amount < MIN_TOPUP_NGN || amount > MAX_TOPUP_NGN) {
    return fleetTopUpReturn(
      callable,
      { success: false, reason: "invalid_amount" },
      { fleet_business_id: resolved.fleetId },
    );
  }
  const tx_ref = bankTransferVa.makeVaTxRef("fwfleet");
  const fwBody = {
    email: String(data?.email ?? context.auth.token?.email ?? `${resolved.ownerUid}@nexride.local`).trim(),
    amount: Math.round(Number(amount) * 100) / 100,
    tx_ref,
    phonenumber: String(data?.phone ?? "08000000000").replace(/\D/g, "").slice(0, 11) || "08000000000",
    firstname: String(data?.first_name ?? "NexRide").slice(0, 80),
    lastname: String(data?.last_name ?? "Fleet").slice(0, 80),
    narration: `Fleet wallet ${resolved.fleetId.slice(0, 8)}`,
  };
  fleetTopUpLog(callable, "flutterwave_request", {
    fleet_business_id: resolved.fleetId,
    tx_ref,
    payload: fwBody,
  });
  const va = await createDynamicNgnVirtualAccount(fwBody);
  fleetTopUpLog(callable, "flutterwave_response", {
    fleet_business_id: resolved.fleetId,
    tx_ref,
    ok: va.ok,
    reason: va.reason ?? null,
    reason_code: va.reason_code ?? null,
    http_status: va.http_status ?? null,
    normalized: va.normalized ?? null,
    raw: va.payload ?? null,
  });
  if (!va.ok || !va.normalized?.account_number) {
    const dataMsg = String(va.payload?.data?.response_message ?? "").trim();
    const topMsg = String(va.flutterwave_message ?? "").trim();
    return fleetTopUpReturn(
      callable,
      {
        success: false,
        reason: "flutterwave_va_failed",
        reason_code: va.reason_code ?? null,
        flutterwave_message: topMsg || dataMsg || null,
        flutterwave_response_message: dataMsg || null,
        message: topMsg || dataMsg || "Bank transfer virtual account could not be created.",
      },
      { fleet_business_id: resolved.fleetId, tx_ref },
    );
  }
  const n = va.normalized;
  const expMs = bankTransferVa.computeVaExpiryMs({});
  const now = nowMs();
  const docRef = fs.collection(FLEET_INTENT_COLLECTION).doc();
  await docRef.set({
    fleet_business_id: resolved.fleetId,
    owner_uid: resolved.ownerUid,
    app_context: "fleet",
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
    created_at: FieldValue.serverTimestamp(),
    updated_at: FieldValue.serverTimestamp(),
  });
  await db.ref(`payment_transactions/${tx_ref}`).set({
    tx_ref,
    app_context: "fleet",
    purpose: "fleet_wallet_topup",
    flow: "fleet_topup",
    provider: "flutterwave_va",
    va_intent: true,
    fleet_business_id: resolved.fleetId,
    owner_uid: resolved.ownerUid,
    fleet_bank_topup_id: docRef.id,
    amount,
    amount_ngn: amount,
    total_ngn: amount,
    currency: "NGN",
    status: "pending_transfer",
    verified: false,
    expires_at_ms: expMs,
    flutterwave_va_create_response: va.payload?.data || null,
    created_at: now,
    updated_at: now,
  });
  await bankTransferVa.upsertIntentDoc(fs, {
    tx_ref,
    owner_uid: resolved.ownerUid,
    app_context: "fleet",
    flow: "fleet_wallet_topup",
    merchant_id: resolved.fleetId,
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
    created_at: FieldValue.serverTimestamp(),
  });
  await bankTransferVa.appendIntentAudit(fs, tx_ref, { type: "va_issued", source: "fleetCreateBankTransferTopUp" });
  return fleetTopUpReturn(
    callable,
    {
      success: true,
      request_id: docRef.id,
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
      bank_name: n.bank_name,
      account_name: n.account_name,
      account_number: n.account_number,
      status: "pending_transfer",
    },
    { fleet_business_id: resolved.fleetId, tx_ref },
  );
}

async function fleetVerifyTopUp(data, context, db) {
  if (!context.auth) return { success: false, reason: "unauthorized" };
  const fs = admin.firestore();
  const ref = String(data?.tx_ref ?? data?.reference ?? "").trim();
  return verifyAndFinalizeFleetWalletTopUpForReference(db, fs, ref, { callerUid: normUid(context.auth.uid) });
}

async function fleetRequestWithdrawal(data, context, db) {
  const fs = admin.firestore();
  const resolved = await resolveFleetOwner(fs, db, context);
  if (!resolved.ok) return { success: false, reason: resolved.reason || "not_found" };
  const amount = Number(data?.amount ?? 0);
  const bankName = trimStr(data?.bankName ?? data?.bank_name ?? "", 120);
  const accountName = trimStr(data?.accountName ?? data?.account_name ?? "", 200);
  const accountNumber = trimStr(data?.accountNumber ?? data?.account_number ?? "", 20);
  if (!Number.isFinite(amount) || amount <= 0) return { success: false, reason: "invalid_amount" };
  if (!userConfirmedWithdrawalRequest(data)) {
    return { success: false, reason: "user_confirmation_required" };
  }
  if (!bankName || !accountName || !accountNumber) return { success: false, reason: "invalid_bank" };
  const feeFields = await buildWithdrawalFeeFieldsForRequest(db, "fleet", amount, resolved.ownerUid);
  if (!feeFields.ok) {
    return { success: false, reason: feeFields.reason, ...feeFields };
  }
  const { sumReservedFleetWithdrawalAmountCanonicalNgn } = require("./withdraw_flow");
  const reserved = await sumReservedFleetWithdrawalAmountCanonicalNgn(db, resolved.fleetId);
  const rawBalance = fleetWalletAvailableNgn(resolved.fleet);
  const available = Math.max(0, rawBalance - reserved);
  if (feeFields.requested_amount > available + 1e-6) {
    return {
      success: false,
      reason: "insufficient_balance",
      available_balance: available,
      reserved_withdrawals: reserved,
    };
  }
  const key = db.ref("withdraw_requests").push().key;
  const now = nowMs();
  const payload = {
    withdrawalId: key,
    entity_type: "fleet",
    fleet_business_id: resolved.fleetId,
    fleet_id: resolved.fleetId,
    owner_uid: resolved.ownerUid,
    requested_by_uid: resolved.ownerUid,
    amount: feeFields.requested_amount,
    amount_ngn: feeFields.requested_amount,
    requested_amount: feeFields.requested_amount,
    withdrawal_fee: feeFields.withdrawal_fee,
    payout_amount: feeFields.payout_amount,
    pre_discount_withdrawal_fee_ngn: feeFields.pre_discount_withdrawal_fee_ngn ?? feeFields.withdrawal_fee,
    discount_applied_ngn: feeFields.discount_applied_ngn ?? 0,
    discount_id: feeFields.discount_id ?? null,
    status: "pending",
    withdrawal_destination_snapshot: {
      bank_name: bankName,
      account_number: accountNumber,
      account_holder_name: accountName,
      updated_at: now,
      updated_by_uid: resolved.ownerUid,
      copied_at: now,
    },
    withdrawalAccount: { bankName, accountName, accountNumber },
    requestedAt: now,
    created_at: now,
    updated_at: now,
  };
  await db.ref(`withdraw_requests/${key}`).set(payload);
  try {
    const { maybeConsumeWithdrawalFeeDiscount } = require("./withdrawal_fee_config");
    await maybeConsumeWithdrawalFeeDiscount(db, resolved.ownerUid, feeFields, key);
  } catch (feeDiscountErr) {
    logger.warn("FLEET_WITHDRAWAL_FEE_DISCOUNT_CONSUME_FAIL", {
      withdrawalId: key,
      err: String(feeDiscountErr?.message || feeDiscountErr),
    });
  }
  logger.info("FLEET_WITHDRAWAL_REQUEST_CREATED", {
    withdrawal_id: key,
    fleet_business_id: resolved.fleetId,
    owner_uid: resolved.ownerUid,
    requested_by_uid: resolved.ownerUid,
    amount_ngn: feeFields.requested_amount,
    withdrawal_fee: feeFields.withdrawal_fee,
    payout_amount: feeFields.payout_amount,
    status: "pending",
  });
  return {
    success: true,
    reason: "requested",
    withdrawalId: key,
    requested_amount: feeFields.requested_amount,
    withdrawal_fee: feeFields.withdrawal_fee,
    payout_amount: feeFields.payout_amount,
  };
}

module.exports = {
  fleetGetWallet,
  fleetCreateCardTopUp,
  fleetCreateBankTransferTopUp,
  fleetVerifyTopUp,
  fleetRequestWithdrawal,
  fleetListWalletTransactions,
  verifyAndFinalizeFleetWalletTopUpForReference,
  finalizeFleetFlutterwaveTopUpVerified,
  readFleetWalletBalanceNgn,
  applyFleetWithdrawalPaidDebit,
  applyFleetWalletCreditOnce,
};

/**
 * Merchant wallet: Firestore-backed balances + ledger, bank top-ups, Flutterwave top-ups,
 * withdrawals (RTDB withdraw_requests with entity_type=merchant), payment-model change requests.
 */

const admin = require("firebase-admin");
const { FieldValue } = require("firebase-admin/firestore");
const { logger } = require("firebase-functions");
const { normUid } = require("../admin_auth");
const adminPerms = require("../admin_permissions");
const { createHostedPaymentLink, verifyFlutterwavePaymentStrict } = require("../flutterwave_api");
const { flutterwavePublicKey } = require("../params");
const merchantVerification = require("./merchant_verification");
const {
  normalizePaymentModel,
  computeCanonicalPaymentModelFields,
  computeInitialSubscriptionStatusForPaymentModel,
} = require("./merchant_callables");
const { buildFlutterwaveRedirectUrl } = require("../payment_redirect");
const { assertPaymentOwnership } = require("../payment_ownership");

const MIN_TOPUP_NGN = 100;
const MAX_TOPUP_NGN = 5_000_000;

function nowMs() {
  return Date.now();
}

function trimStr(v, max = 500) {
  return String(v ?? "")
    .trim()
    .slice(0, max);
}

/**
 * @returns {{ success: false; reason: string } | null}
 */
function requireMerchantRolesWallet(resolved, context, roles) {
  const uid = normUid(context?.auth?.uid);
  const m = resolved.data || {};
  const g = merchantVerification.assertMerchantPortalAllowed(m, uid, roles);
  if (!g.ok) {
    return { success: false, reason: g.reason };
  }
  return null;
}

function flutterwaveCheckoutCustomizations(title) {
  return {
    title,
    description: "Support: support@nexride.africa",
  };
}

function merchantWithdrawalAvailableNgn(m) {
  const wallet = Number(m?.wallet_balance_ngn ?? 0) || 0;
  const weRaw = m?.withdrawable_earnings_ngn;
  if (weRaw != null && Number.isFinite(Number(weRaw))) {
    return Math.max(0, Number(weRaw));
  }
  return Math.max(0, wallet);
}

/**
 * Credit merchant wallet once (idempotent by ledger document id).
 * @param {import("firebase-admin/firestore").Firestore} fs
 */
async function applyMerchantWalletCreditOnce(fs, merchantId, amountNgn, ledgerDocId, ledgerBase) {
  const mid = normUid(merchantId);
  const amt = Number(amountNgn);
  if (!mid || !Number.isFinite(amt) || amt <= 0) {
    return { success: false, reason: "invalid_input" };
  }
  const merchantRef = fs.collection("merchants").doc(mid);
  const ledgerRef = merchantRef.collection("wallet_ledger").doc(ledgerDocId);
  try {
    await fs.runTransaction(async (tx) => {
      const l0 = await tx.get(ledgerRef);
      if (l0.exists) {
        return;
      }
      const m0 = await tx.get(merchantRef);
      if (!m0.exists) {
        throw new Error("merchant_not_found");
      }
      const m = m0.data() || {};
      const cur = Number(m.wallet_balance_ngn ?? 0) || 0;
      const next = cur + amt;
      if (!Number.isFinite(next) || next < 0) {
        throw new Error("balance_invalid");
      }
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
        merchantRef,
        {
          wallet_balance_ngn: next,
          updated_at: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
    });
  } catch (e) {
    const msg = String(e?.message || e);
    if (msg === "merchant_not_found") {
      return { success: false, reason: "merchant_not_found" };
    }
    if (msg === "balance_invalid") {
      return { success: false, reason: "balance_invalid" };
    }
    logger.error("MERCHANT_WALLET_CREDIT_FAIL", { merchantId: mid, ledgerDocId, err: msg });
    return { success: false, reason: "transaction_failed" };
  }
  return { success: true, reason: "credited" };
}

/**
 * Debit merchant wallet for withdrawal payout (idempotent).
 * @param {import("firebase-admin/firestore").Firestore} fs
 */
async function applyMerchantWithdrawalPaidDebit(fs, { merchantId, withdrawalId, amount }) {
  const mid = normUid(merchantId);
  const wid = trimStr(withdrawalId, 128);
  const amt = Number(amount);
  if (!mid || !wid || !Number.isFinite(amt) || amt <= 0) {
    return { success: false, reason: "invalid_input" };
  }
  const ledgerDocId = `withdrawal_paid_${wid}`;
  const merchantRef = fs.collection("merchants").doc(mid);
  const ledgerRef = merchantRef.collection("wallet_ledger").doc(ledgerDocId);
  try {
    await fs.runTransaction(async (tx) => {
      const l0 = await tx.get(ledgerRef);
      if (l0.exists) {
        return;
      }
      const m0 = await tx.get(merchantRef);
      if (!m0.exists) {
        throw new Error("merchant_not_found");
      }
      const m = m0.data() || {};
      const wallet = Number(m.wallet_balance_ngn ?? 0) || 0;
      const weRaw = m.withdrawable_earnings_ngn;
      let we = weRaw != null && Number.isFinite(Number(weRaw)) ? Number(weRaw) : null;

      let fromWithdrawable = 0;
      let fromWallet = 0;
      if (we != null && we > 0) {
        fromWithdrawable = Math.min(amt, we);
        fromWallet = amt - fromWithdrawable;
      } else {
        fromWallet = amt;
      }
      if (fromWallet > wallet + 1e-6) {
        throw new Error("insufficient_wallet");
      }
      const nextWallet = wallet - fromWallet;
      const nextWe = we != null ? we - fromWithdrawable : we;
      if (nextWe != null && nextWe < -1e-6) {
        throw new Error("insufficient_withdrawable");
      }
      tx.set(
        ledgerRef,
        {
          type: "withdrawal_paid",
          direction: "debit",
          amount_ngn: amt,
          wallet_balance_after_ngn: nextWallet,
          withdrawable_earnings_after_ngn: nextWe,
          withdrawal_id: wid,
          created_at: FieldValue.serverTimestamp(),
        },
        { merge: false },
      );
      const patch = {
        wallet_balance_ngn: nextWallet,
        updated_at: FieldValue.serverTimestamp(),
      };
      if (nextWe != null) {
        patch.withdrawable_earnings_ngn = nextWe;
      }
      tx.set(merchantRef, patch, { merge: true });
    });
  } catch (e) {
    const msg = String(e?.message || e);
    if (msg === "insufficient_wallet" || msg === "insufficient_withdrawable") {
      return { success: false, reason: "insufficient_balance" };
    }
    if (msg === "merchant_not_found") {
      return { success: false, reason: "merchant_not_found" };
    }
    logger.error("MERCHANT_WITHDRAWAL_DEBIT_FAIL", { merchantId: mid, withdrawalId: wid, err: msg });
    return { success: false, reason: "transaction_failed" };
  }
  return { success: true, reason: "debited" };
}

/**
 * Shared finalize path after Flutterwave strict verification succeeds.
 * @param {import("firebase-admin/database").Database} db
 * @param {import("firebase-admin/firestore").Firestore} fs
 */
async function finalizeMerchantFlutterwaveTopUpVerified(db, fs, {
  payTid,
  txRef,
  verifiedAmount,
  currency,
  webhookBody,
}) {
  const ptRef = db.ref(`payment_transactions/${txRef}`);
  const ptSnap = await ptRef.get();
  const pt = ptSnap.val() && typeof ptSnap.val() === "object" ? ptSnap.val() : {};
  if (String(pt.purpose || "").trim() !== "merchant_wallet_topup") {
    return { success: false, reason: "not_merchant_wallet_topup" };
  }
  if (pt.verified === true) {
    return { success: true, reason: "already_verified", idempotent: true };
  }
  const merchantId = normUid(pt.merchant_id ?? pt.merchantId);
  const expectedAmount = Number(pt.amount ?? 0);
  if (!merchantId || !Number.isFinite(expectedAmount) || expectedAmount <= 0) {
    return { success: false, reason: "invalid_payment_transaction" };
  }
  const paid = Number(verifiedAmount ?? 0);
  if (!Number.isFinite(paid) || paid + 0.01 < expectedAmount) {
    return { success: false, reason: "amount_mismatch" };
  }

  const ledgerDocId = `flutterwave_topup_${payTid}`;
  const cr = await applyMerchantWalletCreditOnce(fs, merchantId, expectedAmount, ledgerDocId, {
    type: "flutterwave_wallet_topup",
    provider: "flutterwave",
    flutterwave_transaction_id: payTid,
    tx_ref: txRef,
    currency: String(currency || pt.currency || "NGN")
      .trim()
      .toUpperCase() || "NGN",
  });
  if (!cr.success) {
    return cr;
  }

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
    provider_payload:
      webhookBody && typeof webhookBody === "object" ? webhookBody : { event: "merchant_topup" },
  });

  const payKey = String(payTid || "").trim();
  if (payKey) {
    await db.ref(`payments/${payKey}`).update({
      merchant_id: merchantId,
      purpose: "merchant_wallet_topup",
      verified: true,
      amount: expectedAmount,
      currency: String(currency || "NGN").trim().toUpperCase() || "NGN",
      updated_at: now,
    });
  }
  logger.info("MERCHANT_FW_TOPUP_CREDITED", { merchantId, txRef, payTid: payKey, amount: expectedAmount });

  const topUpReqId = String(pt.merchant_bank_topup_id ?? "").trim();
  if (topUpReqId) {
    try {
      await fs
        .collection("merchant_bank_topups")
        .doc(topUpReqId)
        .set(
          {
            status: "completed",
            completed_at: FieldValue.serverTimestamp(),
            flutterwave_transaction_id: payTid,
            updated_at: FieldValue.serverTimestamp(),
          },
          { merge: true },
        );
    } catch (err) {
      logger.warn("MERCHANT_BANK_TOPUP_DOC_UPDATE_FAIL", {
        merchantId,
        txRef,
        topUpReqId,
        err: String(err?.message || err),
      });
    }
  }

  return { success: true, reason: "credited", merchant_id: merchantId, amount_ngn: expectedAmount };
}

async function verifyAndFinalizeMerchantWalletTopUpForReference(db, fs, txRef, { callerUid } = {}) {
  const ref = String(txRef || "").trim();
  if (!ref) {
    return { success: false, reason: "invalid_reference" };
  }
  const ptSnap = await db.ref(`payment_transactions/${ref}`).get();
  const pt = ptSnap.val() && typeof ptSnap.val() === "object" ? ptSnap.val() : {};
  if (String(pt.purpose || "").trim() !== "merchant_wallet_topup") {
    return { success: false, reason: "not_merchant_wallet_topup" };
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
    expectedAppContext: "merchant",
    expectedMerchantId: pt.merchant_id,
  });
  if (!ownership.ok) {
    logger.warn("MERCHANT_PAYMENT_VERIFY_DENIED", {
      txRef: ref,
      callerUid,
      reason: ownership.reason,
    });
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
  return finalizeMerchantFlutterwaveTopUpVerified(db, fs, {
    payTid,
    txRef: ref,
    verifiedAmount: v.amount,
    currency: v.currency || expectCur,
    webhookBody: { event: "callable_verify_payment", data: v.payload?.data },
  });
}

async function merchantStartWalletTopUpFlutterwave(data, context, db) {
  if (!context.auth) {
    return { success: false, reason: "unauthorized" };
  }
  const fs = admin.firestore();
  const resolved = await merchantVerification.resolveMerchantForMerchantAuth(fs, context);
  if (!resolved.ok) {
    return {
      success: false,
      reason:
        resolved.reason === "ambiguous_multiple_merchants"
          ? "ambiguous_multiple_merchants"
          : resolved.reason === "unauthorized"
            ? "unauthorized"
            : "not_found",
    };
  }
  const ownerGate = requireMerchantRolesWallet(resolved, context, ["owner"]);
  if (ownerGate) {
    return ownerGate;
  }
  const m = resolved.data || {};
  const merchantStatus = String(m.merchant_status ?? m.status ?? "")
    .trim()
    .toLowerCase();
  if (merchantStatus !== "approved") {
    return { success: false, reason: "merchant_not_approved" };
  }
  const merchantId = resolved.id;
  const ownerUid = normUid(context.auth.uid);
  const amount = Number(data?.amount_ngn ?? data?.amount ?? 0);
  const currency = String(data?.currency ?? "NGN").trim().toUpperCase() || "NGN";
  const email = String(
    data?.email ?? context.auth.token?.email ?? `${ownerUid}@nexride.local`,
  ).trim();
  if (!Number.isFinite(amount) || amount < MIN_TOPUP_NGN || amount > MAX_TOPUP_NGN) {
    return { success: false, reason: "invalid_amount" };
  }

  const txRefKey = db.ref("payment_transactions").push().key;
  const baseTxRef = `nexride_mwtop_${nowMs()}`;
  const tx_ref = txRefKey ? `${baseTxRef}_${txRefKey}` : baseTxRef;
  if (!tx_ref.trim()) {
    return { success: false, reason: "tx_ref_generation_failed" };
  }
  const redirectUrl = String(
    data?.redirect_url ??
      data?.redirectUrl ??
      buildFlutterwaveRedirectUrl({
        appContext: "merchant",
        flow: "merchant_topup",
        txRef: tx_ref,
        merchantId,
        uid: ownerUid,
      }),
  ).trim();
  const body = {
    tx_ref,
    amount,
    currency,
    redirect_url: redirectUrl,
    payment_options: "card",
    customer: {
      email: email || `${ownerUid}@nexride.local`,
      name: String(data?.customer_name ?? data?.customerName ?? "NexRide merchant").trim(),
    },
    meta: {
      purpose: "merchant_wallet_topup",
      merchant_id: merchantId,
      owner_uid: ownerUid,
    },
    customizations: flutterwaveCheckoutCustomizations("NexRide merchant wallet top-up"),
  };
  const r = await createHostedPaymentLink(body);
  if (!r.ok) {
    logger.warn("MERCHANT_FW_TOPUP_INIT_FAIL", { reason: r.reason, tx_ref });
    return { success: false, reason: r.reason || "payment_init_failed", provider: r.payload };
  }
  const now = nowMs();
  await db.ref(`payment_transactions/${tx_ref}`).set({
    tx_ref,
    app_context: "merchant",
    purpose: "merchant_wallet_topup",
    flow: "merchant_topup",
    merchant_id: merchantId,
    owner_uid: ownerUid,
    ride_id: null,
    delivery_id: null,
    rider_id: null,
    amount,
    amount_ngn: amount,
    currency,
    status: "pending",
    provider_link: r.link,
    verified: false,
    created_at: now,
    updated_at: now,
  });
  return {
    success: true,
    tx_ref,
    amount,
    currency,
    authorization_url: r.link,
    public_key: String(flutterwavePublicKey.value() || "").trim(),
    reason: "initiated",
  };
}

async function merchantCreateBankTransferTopUp(data, context, db) {
  if (!context.auth) {
    return { success: false, reason: "unauthorized" };
  }
  const fs = admin.firestore();
  const resolved = await merchantVerification.resolveMerchantForMerchantAuth(fs, context);
  if (!resolved.ok) {
    return {
      success: false,
      reason:
        resolved.reason === "ambiguous_multiple_merchants"
          ? "ambiguous_multiple_merchants"
          : resolved.reason === "unauthorized"
            ? "unauthorized"
            : "not_found",
    };
  }
  const ownerGate = requireMerchantRolesWallet(resolved, context, ["owner"]);
  if (ownerGate) {
    return ownerGate;
  }
  const m = resolved.data || {};
  const merchantStatus = String(m.merchant_status ?? m.status ?? "")
    .trim()
    .toLowerCase();
  if (merchantStatus !== "approved") {
    return { success: false, reason: "merchant_not_approved" };
  }
  const merchantId = resolved.id;
  const ownerUid = normUid(context.auth.uid);
  const amount = Number(data?.amount_ngn ?? data?.amount ?? 0);
  if (!Number.isFinite(amount) || amount < MIN_TOPUP_NGN || amount > MAX_TOPUP_NGN) {
    return { success: false, reason: "invalid_amount" };
  }

  const bankTransferVa = require("../bank_transfer_va");
  const email = String(
    data?.email ?? context.auth.token?.email ?? `${ownerUid}@nexride.local`,
  ).trim();
  const phone = String(context.auth?.token?.phone_number ?? "").trim();
  const name = String(context.auth?.token?.name ?? "").trim();
  const firstName = (name.split(/\s+/)[0] || email.split("@")[0] || "NexRide").slice(0, 80);
  const lastName =
    name.split(/\s+/).slice(1).join(" ").trim().slice(0, 80) || "Merchant";

  return bankTransferVa.createMerchantBankVaTopUpIntent({
    db,
    fs,
    merchantId,
    ownerUid,
    amount,
    email,
    phone,
    firstName,
    lastName,
  });
}

async function merchantAttachBankTransferTopUpProof(data, context, db) {
  if (!context.auth) {
    return { success: false, reason: "unauthorized" };
  }
  const fs = admin.firestore();
  const resolved = await merchantVerification.resolveMerchantForMerchantAuth(fs, context);
  if (!resolved.ok) {
    return {
      success: false,
      reason:
        resolved.reason === "ambiguous_multiple_merchants"
          ? "ambiguous_multiple_merchants"
          : resolved.reason === "unauthorized"
            ? "unauthorized"
            : "not_found",
    };
  }
  const ownerGate = requireMerchantRolesWallet(resolved, context, ["owner"]);
  if (ownerGate) {
    return ownerGate;
  }
  const merchantId = resolved.id;
  const requestId = trimStr(data?.request_id ?? data?.requestId, 128);
  const storagePath = trimStr(data?.storage_path ?? data?.storagePath, 1024);
  const contentType = trimStr(data?.content_type ?? data?.contentType, 128).toLowerCase();
  if (!requestId || !storagePath) {
    return { success: false, reason: "invalid_input" };
  }
  const prefix = `merchant_uploads/${merchantId}/wallet_topups/${requestId}/`;
  if (!storagePath.startsWith(prefix) || storagePath.includes("..")) {
    return { success: false, reason: "invalid_storage_path" };
  }
  const lastSeg = storagePath.slice(prefix.length);
  if (!lastSeg || lastSeg.includes("/")) {
    return { success: false, reason: "invalid_storage_path" };
  }
  if (
    !contentType ||
    (!contentType.startsWith("image/") && contentType !== "application/pdf")
  ) {
    return { success: false, reason: "invalid_content_type" };
  }

  const docRef = fs.collection("merchant_bank_topups").doc(requestId);
  const snap = await docRef.get();
  if (!snap.exists) {
    return { success: false, reason: "not_found" };
  }
  const row = snap.data() || {};
  if (normUid(row.merchant_id) !== merchantId) {
    return { success: false, reason: "forbidden" };
  }
  if (row.automated_va === true) {
    return { success: false, reason: "proof_not_required_for_automated_va" };
  }
  const pst = String(row.status || "").trim().toLowerCase();
  if (pst === "pending_transfer") {
    return { success: false, reason: "proof_not_required_for_automated_va" };
  }
  if (!["pending", "pending_admin_review"].includes(pst)) {
    return { success: false, reason: "not_pending" };
  }
  const exp = Number(row.expires_at_ms ?? 0) || 0;
  if (exp && nowMs() > exp) {
    await docRef.update({
      status: "expired",
      updated_at: FieldValue.serverTimestamp(),
    });
    return { success: false, reason: "expired" };
  }

  const bucket = admin.storage().bucket();
  const file = bucket.file(storagePath);
  const [exists] = await file.exists();
  if (!exists) {
    return { success: false, reason: "storage_object_missing" };
  }
  const [meta] = await file.getMetadata();
  const size = Number(meta.size || 0);
  if (size <= 0 || size > 12 * 1024 * 1024) {
    return { success: false, reason: "invalid_file_size" };
  }

  await docRef.update({
    proof_storage_path: storagePath,
    proof_content_type: contentType,
    proof_uploaded_at: FieldValue.serverTimestamp(),
    updated_at: FieldValue.serverTimestamp(),
  });
  return { success: true, request_id: requestId };
}

async function merchantListWalletLedger(_data, context, db) {
  if (!context.auth) {
    return { success: false, reason: "unauthorized" };
  }
  const fs = admin.firestore();
  const resolved = await merchantVerification.resolveMerchantForMerchantAuth(fs, context);
  if (!resolved.ok) {
    return {
      success: false,
      reason:
        resolved.reason === "ambiguous_multiple_merchants"
          ? "ambiguous_multiple_merchants"
          : resolved.reason === "unauthorized"
            ? "unauthorized"
            : "not_found",
    };
  }
  const ledgerGate = requireMerchantRolesWallet(resolved, context, ["owner", "manager"]);
  if (ledgerGate) {
    return ledgerGate;
  }
  const merchantId = resolved.id;
  const q = await fs
    .collection("merchants")
    .doc(merchantId)
    .collection("wallet_ledger")
    .orderBy("created_at", "desc")
    .limit(50)
    .get();

  const entries = [];
  for (const d of q.docs) {
    const x = d.data() || {};
    entries.push({
      id: d.id,
      type: x.type != null ? String(x.type) : null,
      direction: x.direction != null ? String(x.direction) : null,
      amount_ngn: x.amount_ngn != null ? Number(x.amount_ngn) : null,
      balance_after_ngn: x.balance_after_ngn != null ? Number(x.balance_after_ngn) : null,
      wallet_balance_after_ngn:
        x.wallet_balance_after_ngn != null ? Number(x.wallet_balance_after_ngn) : null,
      withdrawable_earnings_after_ngn:
        x.withdrawable_earnings_after_ngn != null ? Number(x.withdrawable_earnings_after_ngn) : null,
      currency: x.currency != null ? String(x.currency) : null,
      tx_ref: x.tx_ref != null ? String(x.tx_ref) : null,
      flutterwave_transaction_id:
        x.flutterwave_transaction_id != null ? String(x.flutterwave_transaction_id) : null,
      withdrawal_id: x.withdrawal_id != null ? String(x.withdrawal_id) : null,
      created_at: x.created_at?.toMillis?.() ?? null,
    });
  }

  const pend = await fs
    .collection("merchant_bank_topups")
    .where("merchant_id", "==", merchantId)
    .limit(25)
    .get();
  const pending_bank_topups = [];
  for (const d of pend.docs) {
    const x = d.data() || {};
    const st = String(x.status || "").trim().toLowerCase();
    if (!["pending", "pending_transfer", "pending_admin_review"].includes(st)) continue;
    const exp = Number(x.expires_at_ms ?? 0) || 0;
    if (exp && nowMs() > exp) continue;
    pending_bank_topups.push({
      request_id: d.id,
      amount_ngn: Number(x.amount_ngn ?? 0) || 0,
      expires_at_ms: exp || null,
      narration_reference: x.narration_reference != null ? String(x.narration_reference) : null,
      reference: x.reference != null ? String(x.reference) : null,
      tx_ref: x.tx_ref != null ? String(x.tx_ref) : null,
      automated_va: !!x.automated_va,
      bank: {
        bank_name:
          x.bank_name != null
            ? String(x.bank_name)
            : x.va_bank_name != null
              ? String(x.va_bank_name)
              : null,
        account_name:
          x.account_name != null
            ? String(x.account_name)
            : x.va_account_name != null
              ? String(x.va_account_name)
              : null,
        account_number:
          x.account_number != null
            ? String(x.account_number)
            : x.va_account_number != null
              ? String(x.va_account_number)
              : null,
      },
      proof_uploaded: !!(x.proof_storage_path ?? x.proofStoragePath),
    });
  }
  pending_bank_topups.sort((a, b) => (b.expires_at_ms || 0) - (a.expires_at_ms || 0));

  return { success: true, entries, pending_bank_topups };
}

async function merchantRequestWithdrawal(data, context, db) {
  if (!context.auth) {
    return { success: false, reason: "unauthorized" };
  }
  const fs = admin.firestore();
  const resolved = await merchantVerification.resolveMerchantForMerchantAuth(fs, context);
  if (!resolved.ok) {
    return {
      success: false,
      reason:
        resolved.reason === "ambiguous_multiple_merchants"
          ? "ambiguous_multiple_merchants"
          : resolved.reason === "unauthorized"
            ? "unauthorized"
            : "not_found",
    };
  }
  const ownerGate = requireMerchantRolesWallet(resolved, context, ["owner"]);
  if (ownerGate) {
    return ownerGate;
  }
  const m = resolved.data || {};
  const merchantStatus = String(m.merchant_status ?? m.status ?? "")
    .trim()
    .toLowerCase();
  if (merchantStatus !== "approved") {
    return { success: false, reason: "merchant_not_approved" };
  }
  const merchantId = resolved.id;
  const ownerUid = normUid(context.auth.uid);
  const amount = Number(data?.amount ?? 0);
  const bankName = trimStr(data?.bankName ?? data?.bank_name ?? "", 120);
  const accountName = trimStr(data?.accountName ?? data?.account_name ?? "", 200);
  const accountNumber = trimStr(data?.accountNumber ?? data?.account_number ?? "", 20);
  if (!Number.isFinite(amount) || amount <= 0) {
    return { success: false, reason: "invalid_amount" };
  }
  if (!bankName || !accountName || !accountNumber) {
    return { success: false, reason: "invalid_bank" };
  }

  const available = merchantWithdrawalAvailableNgn(m);
  if (amount > available + 1e-6) {
    return { success: false, reason: "insufficient_balance" };
  }

  const key = db.ref("withdraw_requests").push().key;
  const now = nowMs();
  await db.ref(`withdraw_requests/${key}`).set({
    withdrawalId: key,
    entity_type: "merchant",
    merchant_id: merchantId,
    merchantId,
    owner_uid: ownerUid,
    ownerUid,
    driver_id: null,
    driverId: null,
    amount,
    status: "pending",
    withdrawal_destination_snapshot: {
      bank_name: bankName,
      account_number: accountNumber,
      account_holder_name: accountName,
      bank_code: null,
      updated_at: now,
      updated_by_uid: ownerUid,
      copied_at: now,
    },
    withdrawalAccount: {
      bankName,
      accountName,
      accountNumber,
    },
    requestedAt: now,
    created_at: now,
    updated_at: now,
  });
  return { success: true, reason: "requested", withdrawalId: key };
}

async function merchantRequestPaymentModelChange(data, context, db) {
  if (!context.auth) {
    return { success: false, reason: "unauthorized" };
  }
  const fs = admin.firestore();
  const resolved = await merchantVerification.resolveMerchantForMerchantAuth(fs, context);
  if (!resolved.ok) {
    return {
      success: false,
      reason:
        resolved.reason === "ambiguous_multiple_merchants"
          ? "ambiguous_multiple_merchants"
          : resolved.reason === "unauthorized"
            ? "unauthorized"
            : "not_found",
    };
  }
  const ownerGate = requireMerchantRolesWallet(resolved, context, ["owner"]);
  if (ownerGate) {
    return ownerGate;
  }
  const m = resolved.data || {};
  const merchantStatus = String(m.merchant_status ?? m.status ?? "")
    .trim()
    .toLowerCase();
  if (merchantStatus !== "approved") {
    return { success: false, reason: "merchant_not_approved" };
  }
  const merchantId = resolved.id;
  const ownerUid = normUid(context.auth.uid);
  const requested = normalizePaymentModel(data?.payment_model ?? data?.paymentModel);
  if (!requested) {
    return { success: false, reason: "invalid_payment_model" };
  }
  const current =
    normalizePaymentModel(m.payment_model) ||
    (String(m.payment_model || "").trim() ? String(m.payment_model).trim().toLowerCase() : "") ||
    "subscription";
  if (requested === current) {
    return { success: false, reason: "no_change" };
  }

  const pend = await fs
    .collection("merchant_payment_model_requests")
    .where("merchant_id", "==", merchantId)
    .limit(25)
    .get();
  const hasPending = pend.docs.some(
    (d) => String((d.data() || {}).status || "").trim().toLowerCase() === "pending",
  );
  if (hasPending) {
    return { success: false, reason: "pending_request_exists" };
  }

  const note = trimStr(data?.note ?? data?.merchant_note ?? "", 2000);
  const docRef = fs.collection("merchant_payment_model_requests").doc();
  const now = FieldValue.serverTimestamp();
  await docRef.set({
    request_id: docRef.id,
    merchant_id: merchantId,
    owner_uid: ownerUid,
    from_payment_model: current,
    to_payment_model: requested,
    merchant_note: note || null,
    status: "pending",
    created_at: now,
    updated_at: now,
    reviewed_by: null,
    admin_note: null,
  });
  return { success: true, request_id: docRef.id, status: "pending" };
}

async function adminListMerchantBankTopUps(_data, context, db) {
  const denyLbt = await adminPerms.enforceCallable(db, context, "adminListMerchantBankTopUps");
  if (denyLbt) return denyLbt;
  const fs = admin.firestore();
  const snap = await fs
    .collection("merchant_bank_topups")
    .where("status", "in", ["pending", "pending_admin_review", "pending_transfer", "pending_review"])
    .limit(80)
    .get();
  const rows = snap.docs.map((d) => {
    const x = d.data() || {};
    return {
      id: d.id,
      merchant_id: x.merchant_id ?? null,
      owner_uid: x.owner_uid ?? null,
      amount_ngn: Number(x.amount_ngn ?? 0) || 0,
      status: x.status ?? null,
      expires_at_ms: Number(x.expires_at_ms ?? 0) || 0,
      narration_reference:
        x.narration_reference != null ? String(x.narration_reference) : null,
      tx_reference: x.tx_ref != null ? String(x.tx_ref) : null,
      automated_va: Boolean(x.automated_va === true || x.va_bank_name || x.va_account_number),
      bank_name: x.bank_name ?? null,
      account_name: x.account_name ?? null,
      account_number: x.account_number ?? null,
      proof_storage_path: x.proof_storage_path ?? null,
      proof_uploaded_at: x.proof_uploaded_at?.toMillis?.() ?? null,
      created_at: x.created_at?.toMillis?.() ?? 0,
    };
  });
  rows.sort((a, b) => (b.created_at || 0) - (a.created_at || 0));
  return { success: true, topups: rows };
}

async function adminReviewMerchantBankTopUp(data, context, db) {
  const denyRbt = await adminPerms.enforceCallable(db, context, "adminReviewMerchantBankTopUp");
  if (denyRbt) return denyRbt;
  const adminUid = normUid(context.auth.uid);
  const requestId = trimStr(data?.request_id ?? data?.requestId, 128);
  const action = trimStr(data?.action ?? "", 16).toLowerCase();
  const adminNote = trimStr(data?.admin_note ?? data?.adminNote ?? "", 2000);
  if (!requestId || !["approve", "reject"].includes(action)) {
    return { success: false, reason: "invalid_input" };
  }
  const fs = admin.firestore();
  const docRef = fs.collection("merchant_bank_topups").doc(requestId);
  const snap = await docRef.get();
  if (!snap.exists) {
    return { success: false, reason: "not_found" };
  }
  const row = snap.data() || {};
  const stBank = String(row.status || "").trim().toLowerCase();
  if (["pending_transfer"].includes(stBank)) {
    return { success: false, reason: "automated_va_settles_via_webhook" };
  }
  if (!["pending", "pending_admin_review"].includes(stBank)) {
    return { success: false, reason: "not_pending" };
  }
  const merchantId = normUid(row.merchant_id);
  const amount = Number(row.amount_ngn ?? 0);
  const exp = Number(row.expires_at_ms ?? 0) || 0;
  if (action === "approve") {
    if (exp && nowMs() > exp) {
      await docRef.update({
        status: "expired",
        admin_note: adminNote || "expired_before_review",
        reviewed_by: adminUid,
        updated_at: FieldValue.serverTimestamp(),
      });
      return { success: false, reason: "expired" };
    }
    const ledgerDocId = `bank_topup_${requestId}`;
    const cr = await applyMerchantWalletCreditOnce(fs, merchantId, amount, ledgerDocId, {
      type: "manual_bank_wallet_topup",
      bank_topup_request_id: requestId,
      currency: String(row.currency || "NGN").trim().toUpperCase() || "NGN",
    });
    if (!cr.success) {
      return cr;
    }
    await docRef.update({
      status: "completed",
      reviewed_by: adminUid,
      admin_note: adminNote || null,
      completed_at: FieldValue.serverTimestamp(),
      updated_at: FieldValue.serverTimestamp(),
    });
    logger.info("MERCHANT_BANK_TOPUP_APPROVED", { requestId, merchantId, amount });
    return { success: true, reason: "approved", request_id: requestId };
  }
  await docRef.update({
    status: "rejected",
    reviewed_by: adminUid,
    admin_note: adminNote || null,
    updated_at: FieldValue.serverTimestamp(),
  });
  return { success: true, reason: "rejected", request_id: requestId };
}

async function adminListMerchantPaymentModelRequests(_data, context, db) {
  const denyLmpr = await adminPerms.enforceCallable(db, context, "adminListMerchantPaymentModelRequests");
  if (denyLmpr) return denyLmpr;
  const fs = admin.firestore();
  const snap = await fs
    .collection("merchant_payment_model_requests")
    .where("status", "==", "pending")
    .limit(80)
    .get();
  const rows = snap.docs.map((d) => {
    const x = d.data() || {};
    return {
      id: d.id,
      merchant_id: x.merchant_id ?? null,
      owner_uid: x.owner_uid ?? null,
      from_payment_model: x.from_payment_model ?? null,
      to_payment_model: x.to_payment_model ?? null,
      merchant_note: x.merchant_note ?? null,
      created_at: x.created_at?.toMillis?.() ?? 0,
    };
  });
  rows.sort((a, b) => (b.created_at || 0) - (a.created_at || 0));
  return { success: true, requests: rows };
}

async function adminResolveMerchantPaymentModelRequest(data, context, db) {
  const denyRmpr = await adminPerms.enforceCallable(db, context, "adminResolveMerchantPaymentModelRequest");
  if (denyRmpr) return denyRmpr;
  const adminUid = normUid(context.auth.uid);
  const requestId = trimStr(data?.request_id ?? data?.requestId, 128);
  const action = trimStr(data?.action ?? "", 16).toLowerCase();
  const adminNote = trimStr(data?.admin_note ?? data?.adminNote ?? "", 2000);
  if (!requestId || !["approve", "reject"].includes(action)) {
    return { success: false, reason: "invalid_input" };
  }
  const fs = admin.firestore();
  const docRef = fs.collection("merchant_payment_model_requests").doc(requestId);
  const snap = await docRef.get();
  if (!snap.exists) {
    return { success: false, reason: "not_found" };
  }
  const row = snap.data() || {};
  if (String(row.status || "").trim().toLowerCase() !== "pending") {
    return { success: false, reason: "not_pending" };
  }
  const merchantId = normUid(row.merchant_id);
  const toModel = normalizePaymentModel(row.to_payment_model);
  if (!merchantId || !toModel) {
    return { success: false, reason: "invalid_record" };
  }

  if (action === "reject") {
    await docRef.update({
      status: "rejected",
      reviewed_by: adminUid,
      admin_note: adminNote || null,
      updated_at: FieldValue.serverTimestamp(),
    });
    await db.ref("admin_audit_logs").push().set({
      type: "merchant_payment_model_request_rejected",
      merchant_id: merchantId,
      request_id: requestId,
      admin_uid: adminUid,
      created_at: Date.now(),
    });
    return { success: true, reason: "rejected", request_id: requestId };
  }

  const mref = fs.collection("merchants").doc(merchantId);
  const msnap = await mref.get();
  if (!msnap.exists) {
    return { success: false, reason: "merchant_not_found" };
  }
  const now = FieldValue.serverTimestamp();
  const canonical = computeCanonicalPaymentModelFields(toModel);
  const nextSubscriptionStatus =
    toModel === "subscription"
      ? computeInitialSubscriptionStatusForPaymentModel(toModel)
      : "inactive";

  await mref.update({
    payment_model: canonical.payment_model,
    commission_exempt: canonical.commission_exempt,
    commission_rate: canonical.commission_rate,
    withdrawal_percent: canonical.withdrawal_percent,
    subscription_amount: canonical.subscription_amount,
    subscription_currency: canonical.subscription_currency,
    subscription_status: nextSubscriptionStatus,
    updated_at: now,
  });
  await docRef.update({
    status: "approved",
    reviewed_by: adminUid,
    admin_note: adminNote || null,
    updated_at: FieldValue.serverTimestamp(),
  });
  await db.ref("admin_audit_logs").push().set({
    type: "merchant_payment_model_request_approved",
    merchant_id: merchantId,
    request_id: requestId,
    payment_model: toModel,
    admin_uid: adminUid,
    created_at: Date.now(),
  });
  return {
    success: true,
    reason: "approved",
    request_id: requestId,
    merchant_id: merchantId,
    payment_model: toModel,
    subscription_status: nextSubscriptionStatus,
  };
}

module.exports = {
  merchantStartWalletTopUpFlutterwave,
  merchantCreateBankTransferTopUp,
  merchantAttachBankTransferTopUpProof,
  merchantListWalletLedger,
  merchantRequestWithdrawal,
  merchantRequestPaymentModelChange,
  verifyAndFinalizeMerchantWalletTopUpForReference,
  finalizeMerchantFlutterwaveTopUpVerified,
  applyMerchantWithdrawalPaidDebit,
  adminListMerchantBankTopUps,
  adminReviewMerchantBankTopUp,
  adminListMerchantPaymentModelRequests,
  adminResolveMerchantPaymentModelRequest,
};

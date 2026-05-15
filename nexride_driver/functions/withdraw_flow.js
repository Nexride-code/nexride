/**
 * Driver withdrawal requests + admin approval (wallet debit on payout).
 * Driver payout destinations live at RTDB `drivers/{uid}/withdrawal_destination`.
 */

const admin = require("firebase-admin");
const { createWalletTransactionInternal } = require("./wallet_core");
const adminPerms = require("./admin_permissions");
const { applyMerchantWithdrawalPaidDebit } = require("./merchant/merchant_wallet");
const { writeAdminAuditLog } = require("./admin_audit_log");

function normUid(uid) {
  return String(uid ?? "").trim();
}

function nowMs() {
  return Date.now();
}

function digitsOnlyAccountNumber(v) {
  return String(v ?? "").replace(/\D/g, "");
}

/**
 * Validates payload for saving or copying a driver withdrawal destination.
 * @returns {{ ok: true, value: object } | { ok: false, reason: string }}
 */
function validateDriverWithdrawalDestinationInput(data) {
  const bank_name = String(data?.bank_name ?? data?.bankName ?? "").trim();
  const account_number = digitsOnlyAccountNumber(data?.account_number ?? data?.accountNumber);
  const account_holder_name = String(
    data?.account_holder_name ??
      data?.accountHolderName ??
      data?.accountName ??
      data?.account_name ??
      "",
  )
    .trim()
    .slice(0, 200);
  const bank_codeRaw = String(data?.bank_code ?? data?.bankCode ?? "").trim().slice(0, 32);
  const bank_code = bank_codeRaw.length > 0 ? bank_codeRaw : null;

  if (!bank_name || bank_name.length > 120) {
    return { ok: false, reason: "invalid_bank_name" };
  }
  if (!account_holder_name) {
    return { ok: false, reason: "invalid_account_holder" };
  }
  if (!account_number || account_number.length < 8 || account_number.length > 20) {
    return { ok: false, reason: "invalid_account_number" };
  }
  if (!/^\d+$/.test(account_number)) {
    return { ok: false, reason: "invalid_account_number" };
  }

  return {
    ok: true,
    value: {
      bank_name,
      account_number,
      account_holder_name,
      bank_code,
    },
  };
}

async function driverGetWithdrawalDestination(_data, context, db) {
  if (!context.auth) {
    return { success: false, reason: "unauthorized" };
  }
  const driverId = normUid(context.auth.uid);
  const snap = await db.ref(`drivers/${driverId}/withdrawal_destination`).get();
  const val = snap.val();
  if (!val || typeof val !== "object") {
    return { success: true, destination: null };
  }
  return { success: true, destination: { ...val } };
}

async function driverUpdateWithdrawalDestination(data, context, db) {
  if (!context.auth) {
    return { success: false, reason: "unauthorized" };
  }
  const driverId = normUid(context.auth.uid);
  const v = validateDriverWithdrawalDestinationInput(data);
  if (!v.ok) {
    return { success: false, reason: v.reason };
  }
  const now = nowMs();
  const uid = normUid(context.auth.uid);
  const payload = {
    ...v.value,
    updated_at: now,
    updated_by_uid: uid,
  };
  await db.ref(`drivers/${driverId}/withdrawal_destination`).set(payload);
  return { success: true, destination: payload };
}

function driverWithdrawalRecordHasPayoutDestination(w) {
  if (!w || typeof w !== "object") {
    return false;
  }
  const snap = w.withdrawal_destination_snapshot;
  if (snap && typeof snap === "object") {
    const bn = String(snap.bank_name ?? "").trim();
    const an = digitsOnlyAccountNumber(snap.account_number);
    const hn = String(snap.account_holder_name ?? "").trim();
    return !!(bn && an && hn);
  }
  const wa = w.withdrawalAccount ?? w.destination;
  if (wa && typeof wa === "object") {
    const bank = String(wa.bankName ?? wa.bank_name ?? "").trim();
    const num = digitsOnlyAccountNumber(wa.accountNumber ?? wa.account_number);
    const hold = String(
      wa.accountName ?? wa.account_holder_name ?? wa.account_name ?? wa.holderName ?? "",
    ).trim();
    return !!(bank && num && hold);
  }
  return false;
}

async function requestWithdrawal(data, context, db) {
  if (!context.auth) {
    return { success: false, reason: "unauthorized" };
  }
  const driverId = normUid(context.auth.uid);
  const amount = Number(data?.amount ?? 0);
  if (!Number.isFinite(amount) || amount <= 0) {
    return { success: false, reason: "invalid_amount" };
  }

  const destSnap = await db.ref(`drivers/${driverId}/withdrawal_destination`).get();
  const dest = destSnap.val();
  if (!dest || typeof dest !== "object") {
    return { success: false, reason: "withdrawal_destination_required" };
  }
  const v = validateDriverWithdrawalDestinationInput(dest);
  if (!v.ok) {
    return { success: false, reason: "withdrawal_destination_required" };
  }

  const walletSnap = await db.ref(`wallets/${driverId}`).get();
  const wallet = walletSnap.val();
  const balance = Number(wallet?.balance ?? 0);
  if (!Number.isFinite(balance) || balance < amount) {
    return { success: false, reason: "insufficient_balance" };
  }

  const now = nowMs();
  const snapshot = {
    bank_name: v.value.bank_name,
    account_number: v.value.account_number,
    account_holder_name: v.value.account_holder_name,
    bank_code: v.value.bank_code,
    updated_at: Number(dest.updated_at ?? now) || now,
    updated_by_uid: normUid(dest.updated_by_uid) || driverId,
    copied_at: now,
  };

  const key = db.ref("withdraw_requests").push().key;
  await db.ref(`withdraw_requests/${key}`).set({
    withdrawalId: key,
    entity_type: "driver",
    driver_id: driverId,
    driverId,
    merchant_id: null,
    merchantId: null,
    amount,
    status: "pending",
    withdrawal_destination_snapshot: snapshot,
    withdrawalAccount: {
      bankName: snapshot.bank_name,
      accountName: snapshot.account_holder_name,
      accountNumber: snapshot.account_number,
      bankCode: snapshot.bank_code || null,
    },
    destination: {
      bankName: snapshot.bank_name,
      accountName: snapshot.account_holder_name,
      accountNumber: snapshot.account_number,
      bankCode: snapshot.bank_code || null,
    },
    requestedAt: now,
    created_at: now,
    updated_at: now,
  });

  return { success: true, reason: "requested", withdrawalId: key };
}

async function approveWithdrawal(data, context, db) {
  const denyAw = await adminPerms.enforceCallable(db, context, "approveWithdrawal");
  if (denyAw) return denyAw;
  const withdrawalId = normUid(data?.withdrawalId ?? data?.withdrawal_id);
  const status = String(data?.status ?? "").trim().toLowerCase();
  if (!withdrawalId || !["approved", "paid", "rejected"].includes(status)) {
    return { success: false, reason: "invalid_input" };
  }

  const ref = db.ref(`withdraw_requests/${withdrawalId}`);
  const snap = await ref.get();
  const w = snap.val();
  if (!w || typeof w !== "object") {
    return { success: false, reason: "not_found" };
  }
  const currentStatus = String(w.status ?? "").trim().toLowerCase();
  if (currentStatus === "paid" || currentStatus === "rejected") {
    return { success: false, reason: "already_finalized" };
  }

  const entityType = String(w.entity_type ?? w.entityType ?? "driver")
    .trim()
    .toLowerCase();
  const driverId = normUid(w.driver_id ?? w.driverId);
  const merchantId = normUid(w.merchant_id ?? w.merchantId);
  const amount = Number(w.amount ?? 0);
  const now = nowMs();
  const adminUid = normUid(context.auth.uid);
  const adminNote = String(data?.admin_note ?? data?.adminNote ?? "").trim();

  if ((status === "paid" || status === "approved") && entityType !== "merchant") {
    if (!driverWithdrawalRecordHasPayoutDestination(w)) {
      return { success: false, reason: "withdrawal_destination_required" };
    }
  }

  if (status === "paid") {
    if (!Number.isFinite(amount) || amount <= 0) {
      return { success: false, reason: "invalid_record" };
    }
    if (entityType === "merchant") {
      if (!merchantId) {
        return { success: false, reason: "invalid_record" };
      }
      const fs = admin.firestore();
      const wt = await applyMerchantWithdrawalPaidDebit(fs, {
        merchantId,
        withdrawalId,
        amount,
      });
      if (!wt.success) {
        return wt;
      }
    } else {
      if (!driverId) {
        return { success: false, reason: "invalid_record" };
      }
      const wt = await createWalletTransactionInternal(db, {
        userId: driverId,
        amount,
        type: "withdrawal_paid",
        idempotencyKey: `withdraw_paid_${withdrawalId}`,
      });
      if (!wt.success) {
        return wt;
      }
    }
  }

  await ref.update({
    status,
    updated_at: now,
    processedAt: now,
    processed_at: now,
    reviewed_by: adminUid,
    admin_note: adminNote || null,
  });

  await writeAdminAuditLog(db, {
    actor_uid: adminUid,
    action: status === "rejected" ? "reject_withdrawal" : "approve_withdrawal",
    entity_type: "withdrawal",
    entity_id: withdrawalId,
    before: {
      status: currentStatus,
      amount,
      entity_type: entityType,
      driver_id: driverId || null,
      merchant_id: merchantId || null,
    },
    after: { status, admin_note: adminNote || null },
    reason: adminNote || (status === "rejected" ? "admin_reject" : "admin_approve"),
    source: "withdraw_flow.approveWithdrawal",
    type: status === "rejected" ? "admin_reject_withdrawal" : "admin_approve_withdrawal",
    created_at: now,
  });

  return { success: true, reason: "updated", reason_code: "withdrawal_updated", withdrawalId };
}

module.exports = {
  requestWithdrawal,
  approveWithdrawal,
  driverGetWithdrawalDestination,
  driverUpdateWithdrawalDestination,
  validateDriverWithdrawalDestinationInput,
  driverWithdrawalRecordHasPayoutDestination,
};

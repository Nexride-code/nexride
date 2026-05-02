/**
 * Driver withdrawal requests + admin approval (wallet debit on payout).
 */

const { createWalletTransactionInternal } = require("./wallet_core");
const { isNexRideAdmin } = require("./admin_auth");

function normUid(uid) {
  return String(uid ?? "").trim();
}

function nowMs() {
  return Date.now();
}

async function requestWithdrawal(data, context, db) {
  if (!context.auth) {
    return { success: false, reason: "unauthorized" };
  }
  const driverId = normUid(context.auth.uid);
  const amount = Number(data?.amount ?? 0);
  const bankName = String(data?.bankName ?? data?.bank_name ?? "").trim();
  const accountName = String(data?.accountName ?? data?.account_name ?? "").trim();
  const accountNumber = String(data?.accountNumber ?? data?.account_number ?? "").trim();
  if (!Number.isFinite(amount) || amount <= 0) {
    return { success: false, reason: "invalid_amount" };
  }
  if (!bankName || !accountName || !accountNumber) {
    return { success: false, reason: "invalid_bank" };
  }

  const walletSnap = await db.ref(`wallets/${driverId}`).get();
  const wallet = walletSnap.val();
  const balance = Number(wallet?.balance ?? 0);
  if (!Number.isFinite(balance) || balance < amount) {
    return { success: false, reason: "insufficient_balance" };
  }

  const key = db.ref("withdraw_requests").push().key;
  const now = nowMs();
  await db.ref(`withdraw_requests/${key}`).set({
    withdrawalId: key,
    driver_id: driverId,
    driverId,
    amount,
    status: "pending",
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

async function approveWithdrawal(data, context, db) {
  if (!context.auth || !(await isNexRideAdmin(db, context))) {
    return { success: false, reason: "unauthorized" };
  }
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

  const driverId = normUid(w.driver_id ?? w.driverId);
  const amount = Number(w.amount ?? 0);
  const now = nowMs();
  const adminUid = normUid(context.auth.uid);
  const adminNote = String(data?.admin_note ?? data?.adminNote ?? "").trim();

  if (status === "paid") {
    if (!driverId || !Number.isFinite(amount) || amount <= 0) {
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

  await ref.update({
    status,
    updated_at: now,
    processedAt: now,
    processed_at: now,
    reviewed_by: adminUid,
    admin_note: adminNote || null,
  });

  return { success: true, reason: "updated", withdrawalId };
}

module.exports = {
  requestWithdrawal,
  approveWithdrawal,
};

/**
 * Wallet ledger mutations (Admin SDK only from Cloud Functions).
 */

const MAX_IDEM_LEN = 200;

async function createWalletTransactionInternal(db, { userId, amount, type, idempotencyKey }) {
  const normalizedUserId = String(userId || "").trim();
  const numericAmount = Number(amount || 0);
  const normalizedType = String(type || "").trim();
  const idem = String(idempotencyKey || "").trim();
  if (!normalizedUserId || !normalizedType || !Number.isFinite(numericAmount) || numericAmount <= 0) {
    return { success: false, reason: "invalid_input" };
  }
  if (!idem || idem.length > MAX_IDEM_LEN) {
    return { success: false, reason: "idempotency_key_required" };
  }

  const walletRef = db.ref(`wallets/${normalizedUserId}`);
  const transactionId = idem;
  let failureReason = "unknown";

  const preSnap = await walletRef.get();
  const preWallet = preSnap.val() && typeof preSnap.val() === "object" ? preSnap.val() : {};
  const preTx =
    preWallet.transactions && typeof preWallet.transactions === "object"
      ? preWallet.transactions[transactionId]
      : null;
  if (preTx && typeof preTx === "object") {
    const sameType = String(preTx.type || "").trim() === normalizedType;
    const sameAmount = Number(preTx.amount || 0) === numericAmount;
    if (sameType && sameAmount) {
      return {
        success: true,
        reason: "already_applied",
        transactionId,
        idempotent: true,
      };
    }
    return { success: false, reason: "idempotency_key_conflict" };
  }

  const tx = await walletRef.transaction((current) => {
    const wallet = current && typeof current === "object" ? current : {};
    const balance = Number(wallet.balance || 0);
    const transactions =
      wallet.transactions && typeof wallet.transactions === "object"
        ? wallet.transactions
        : {};
    if (transactionId && transactions[transactionId]) {
      const prev = transactions[transactionId];
      if (
        prev &&
        typeof prev === "object" &&
        String(prev.type || "").trim() === normalizedType &&
        Number(prev.amount || 0) === numericAmount
      ) {
        return wallet;
      }
      failureReason = "idempotency_key_conflict";
      return;
    }

    const isDebit =
      normalizedType === "rider_payment_debit" ||
      normalizedType === "platform_fee_debit" ||
      normalizedType === "withdrawal_paid";
    const nextBalance = isDebit ? balance - numericAmount : balance + numericAmount;
    if (isDebit && nextBalance < 0) {
      failureReason = "insufficient_balance";
      return;
    }

    return {
      ...wallet,
      user_id: normalizedUserId,
      balance: nextBalance,
      updated_at: Date.now(),
      transactions: {
        ...transactions,
        [transactionId]: {
          transactionId,
          type: normalizedType,
          amount: numericAmount,
          direction: isDebit ? "debit" : "credit",
          created_at: Date.now(),
        },
      },
    };
  });

  if (!tx.committed) {
    return { success: false, reason: failureReason === "unknown" ? "wallet_update_failed" : failureReason };
  }
  return { success: true, reason: "wallet_updated", transactionId, idempotent: false };
}

module.exports = {
  createWalletTransactionInternal,
};

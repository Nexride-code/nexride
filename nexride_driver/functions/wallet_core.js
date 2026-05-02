/**
 * Wallet ledger mutations (Admin SDK only from Cloud Functions).
 */

async function createWalletTransactionInternal(db, { userId, amount, type, idempotencyKey }) {
  const normalizedUserId = String(userId || "").trim();
  const numericAmount = Number(amount || 0);
  const normalizedType = String(type || "").trim();
  const idem = String(idempotencyKey || "").trim();
  if (!normalizedUserId || !normalizedType || !Number.isFinite(numericAmount) || numericAmount <= 0) {
    return { success: false, reason: "invalid_input" };
  }

  const walletRef = db.ref(`wallets/${normalizedUserId}`);
  const transactionId = idem || db.ref("wallet_transactions").push().key;
  let failureReason = "unknown";

  const tx = await walletRef.transaction((current) => {
    const wallet = current && typeof current === "object" ? current : {};
    const balance = Number(wallet.balance || 0);
    const transactions =
      wallet.transactions && typeof wallet.transactions === "object"
        ? wallet.transactions
        : {};
    if (transactionId && transactions[transactionId]) {
      return wallet;
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
  return { success: true, reason: "wallet_updated", transactionId };
}

module.exports = {
  createWalletTransactionInternal,
};

/**
 * Server-side Flutterwave API helpers (never trust client payment success).
 */

const { flutterwaveSecretForVerify } = require("./params");

function flutterwaveVerifyUrl(refOrNumericId) {
  const s = String(refOrNumericId || "").trim();
  if (/^\d+$/.test(s)) {
    return `https://api.flutterwave.com/v3/transactions/${encodeURIComponent(s)}/verify`;
  }
  return `https://api.flutterwave.com/v3/transactions/verify_by_reference?tx_ref=${encodeURIComponent(s)}`;
}

/**
 * @param {string} reference tx_ref or Flutterwave numeric transaction id
 * @returns {Promise<{ ok: boolean, reason?: string, amount?: number, providerStatus?: string, payload?: object, flwTransactionId?: string }>}
 */
async function verifyTransactionByReference(reference) {
  const ref = String(reference || "").trim();
  if (!ref) {
    return { ok: false, reason: "invalid_reference" };
  }
  const secret = flutterwaveSecretForVerify();
  if (!secret) {
    return { ok: false, reason: "flutterwave_secret_missing" };
  }
  let response;
  try {
    response = await fetch(flutterwaveVerifyUrl(ref), {
      method: "GET",
      headers: {
        Authorization: `Bearer ${secret}`,
        "Content-Type": "application/json",
      },
    });
  } catch (error) {
    return { ok: false, reason: "network_error", payload: { error: String(error) } };
  }
  let payload = {};
  try {
    payload = await response.json();
  } catch (_) {
    payload = {};
  }
  const providerStatus = String(payload?.status || "").toLowerCase();
  const dataStatus = String(payload?.data?.status || "").toLowerCase();
  const amount = Number(payload?.data?.amount || 0);
  const ok = response.ok && providerStatus === "success" && dataStatus === "successful";
  const flwTransactionId = String(payload?.data?.id ?? "").trim() || null;
  return {
    ok,
    reason: ok ? undefined : "verification_failed",
    amount,
    providerStatus: dataStatus || providerStatus,
    payload,
    flwTransactionId,
  };
}

/**
 * GET /v3/transactions/{numericId}/verify — strict match against expected tx_ref, currency, min amount.
 * @param {string} transactionId Flutterwave numeric transaction id
 * @param {{ expectedTxRef?: string, expectedCurrency?: string, minAmount?: number }} expect
 */
async function verifyTransactionByIdStrict(transactionId, expect = {}) {
  const id = String(transactionId || "").trim();
  if (!/^\d+$/.test(id)) {
    return { ok: false, reason: "invalid_transaction_id" };
  }
  const secret = flutterwaveSecretForVerify();
  if (!secret) {
    return { ok: false, reason: "flutterwave_secret_missing" };
  }
  const url = `https://api.flutterwave.com/v3/transactions/${encodeURIComponent(id)}/verify`;
  let response;
  let payload = {};
  try {
    response = await fetch(url, {
      method: "GET",
      headers: {
        Authorization: `Bearer ${secret}`,
        "Content-Type": "application/json",
      },
    });
    payload = await response.json().catch(() => ({}));
  } catch (error) {
    return { ok: false, reason: "network_error", payload: { error: String(error) } };
  }
  const providerStatus = String(payload?.status || "").toLowerCase();
  const data = payload?.data && typeof payload.data === "object" ? payload.data : {};
  const dataStatus = String(data.status || "").toLowerCase();
  const baseOk = response.ok && providerStatus === "success" && dataStatus === "successful";
  if (!baseOk) {
    return { ok: false, reason: "verification_failed", payload };
  }
  const tx_ref = String(data.tx_ref || "").trim();
  const cur = String(data.currency || "").trim().toUpperCase();
  const amt = Number(data.amount || 0);
  const expRef = String(expect.expectedTxRef || "").trim();
  if (expRef && tx_ref !== expRef) {
    return { ok: false, reason: "tx_ref_mismatch", payload };
  }
  const expCur = String(expect.expectedCurrency || "").trim().toUpperCase();
  if (expCur && cur !== expCur) {
    return { ok: false, reason: "currency_mismatch", payload };
  }
  const minAmt = expect.minAmount;
  if (minAmt != null && Number.isFinite(Number(minAmt)) && amt + 1e-6 < Number(minAmt)) {
    return { ok: false, reason: "amount_below_expected", payload };
  }
  return {
    ok: true,
    amount: amt,
    currency: cur,
    tx_ref,
    providerStatus: dataStatus,
    payload,
    flwTransactionId: id,
  };
}

/**
 * Prefer numeric id verify; otherwise verify_by_reference + same strict checks on payload.data.
 */
async function verifyFlutterwavePaymentStrict({ transactionId, txRef, expect = {} }) {
  const id = String(transactionId || "").trim();
  if (/^\d+$/.test(id)) {
    return verifyTransactionByIdStrict(id, expect);
  }
  const ref = String(txRef || "").trim();
  if (!ref) {
    return { ok: false, reason: "missing_verify_key" };
  }
  const v = await verifyTransactionByReference(ref);
  if (!v.ok) {
    return { ok: false, reason: v.reason || "verification_failed", payload: v.payload };
  }
  const data = v.payload?.data && typeof v.payload.data === "object" ? v.payload.data : {};
  const tx_ref = String(data.tx_ref || ref).trim();
  const cur = String(data.currency || "").trim().toUpperCase();
  const amt = Number(data.amount ?? v.amount ?? 0);
  const expRef = String(expect.expectedTxRef || "").trim();
  if (expRef && tx_ref !== expRef) {
    return { ok: false, reason: "tx_ref_mismatch", payload: v.payload };
  }
  const expCur = String(expect.expectedCurrency || "").trim().toUpperCase();
  if (expCur && cur !== expCur) {
    return { ok: false, reason: "currency_mismatch", payload: v.payload };
  }
  const minAmt = expect.minAmount;
  if (minAmt != null && Number.isFinite(Number(minAmt)) && amt + 1e-6 < Number(minAmt)) {
    return { ok: false, reason: "amount_below_expected", payload: v.payload };
  }
  return {
    ok: true,
    amount: amt,
    currency: cur,
    tx_ref,
    providerStatus: String(data.status || v.providerStatus || ""),
    payload: v.payload,
    flwTransactionId: String(v.flwTransactionId || data.id || "").trim() || id,
  };
}

/**
 * @param {object} body Flutterwave /v3/payments payload
 */
async function createHostedPaymentLink(body) {
  const secret = flutterwaveSecretForVerify();
  if (!secret) {
    return { ok: false, reason: "flutterwave_secret_missing" };
  }
  let response;
  try {
    response = await fetch("https://api.flutterwave.com/v3/payments", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${secret}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(body),
    });
  } catch (error) {
    return { ok: false, reason: "network_error", error: String(error) };
  }
  let payload = {};
  try {
    payload = await response.json();
  } catch (_) {
    payload = {};
  }
  const link = String(payload?.data?.link || "").trim();
  const ok = response.ok && !!link;
  return { ok, reason: ok ? undefined : "initiate_failed", link, payload };
}

module.exports = {
  verifyTransactionByReference,
  verifyTransactionByIdStrict,
  verifyFlutterwavePaymentStrict,
  createHostedPaymentLink,
};

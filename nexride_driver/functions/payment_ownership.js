/**
 * Strict payment intent ownership checks for verify / finalize flows.
 */

function normUid(uid) {
  return String(uid ?? "").trim();
}

function inferAppContextFromPaymentRow(pt) {
  const explicit = String(pt?.app_context ?? "")
    .trim()
    .toLowerCase();
  if (explicit === "rider" || explicit === "merchant" || explicit === "driver") {
    return explicit;
  }
  const purpose = String(pt?.purpose ?? "")
    .trim()
    .toLowerCase();
  if (purpose === "merchant_wallet_topup") {
    return "merchant";
  }
  if (pt?.merchant_id) {
    return "merchant";
  }
  if (pt?.driver_id) {
    return "driver";
  }
  if (pt?.rider_id) {
    return "rider";
  }
  return "";
}

/**
 * @param {Record<string, unknown>} pt payment_transactions row
 * @param {object} opts
 * @param {string} opts.callerUid
 * @param {string} [opts.expectedAppContext]
 * @param {string} [opts.expectedMerchantId]
 * @param {string} [opts.expectedRiderId]
 * @param {string} [opts.expectedDriverId]
 * @returns {{ ok: true } | { ok: false, reason: string, reason_code: string }}
 */
function assertPaymentOwnership(pt, opts = {}) {
  if (!pt || typeof pt !== "object") {
    return { ok: false, reason: "payment_reference_not_found", reason_code: "payment_reference_not_found" };
  }
  const callerUid = normUid(opts.callerUid);
  if (!callerUid) {
    return { ok: false, reason: "unauthorized", reason_code: "unauthorized" };
  }
  const ownerUid = normUid(pt.owner_uid ?? pt.ownerUid ?? pt.rider_id);
  if (ownerUid && ownerUid !== callerUid) {
    return { ok: false, reason: "payment_owner_mismatch", reason_code: "payment_owner_mismatch" };
  }
  const expectedCtx = String(opts.expectedAppContext ?? "")
    .trim()
    .toLowerCase();
  const rowCtx = inferAppContextFromPaymentRow(pt);
  if (expectedCtx && rowCtx && expectedCtx !== rowCtx) {
    return { ok: false, reason: "payment_context_mismatch", reason_code: "payment_context_mismatch" };
  }
  const expectedMerchant = normUid(opts.expectedMerchantId);
  const rowMerchant = normUid(pt.merchant_id);
  if (expectedMerchant && rowMerchant && expectedMerchant !== rowMerchant) {
    return { ok: false, reason: "payment_owner_mismatch", reason_code: "payment_owner_mismatch" };
  }
  const expectedRider = normUid(opts.expectedRiderId);
  const rowRider = normUid(pt.rider_id);
  if (expectedRider && rowRider && expectedRider !== rowRider) {
    return { ok: false, reason: "payment_owner_mismatch", reason_code: "payment_owner_mismatch" };
  }
  const expectedDriver = normUid(opts.expectedDriverId);
  const rowDriver = normUid(pt.driver_id);
  if (expectedDriver && rowDriver && expectedDriver !== rowDriver) {
    return { ok: false, reason: "payment_owner_mismatch", reason_code: "payment_owner_mismatch" };
  }
  return { ok: true };
}

module.exports = {
  normUid,
  inferAppContextFromPaymentRow,
  assertPaymentOwnership,
};

/**
 * Frozen Flutterwave charge expectations for rides/deliveries.
 * Always prefer entity `total_ngn` set at quote/create time.
 */

const { platformFeeNgn } = require("./params");

function roundNgn(n) {
  return Math.round(Math.max(0, Number(n) || 0));
}

/**
 * Exact amount Flutterwave must charge / verify for this entity.
 * @param {object|null} row
 */
function expectedFlutterwaveChargeNgn(row) {
  if (!row || typeof row !== "object") return 0;
  const snapTotal = roundNgn(row.pricing_snapshot?.total_ngn ?? 0);
  if (snapTotal > 0) return snapTotal;
  const total = roundNgn(row.total_ngn ?? 0);
  if (total > 0) return total;
  const trip = roundNgn(row.fare ?? row.trip_fare_ngn ?? row.total_delivery_fee ?? 0);
  const booking = roundNgn(row.platform_fee_ngn ?? row.booking_fee_ngn ?? platformFeeNgn());
  const small = roundNgn(row.small_order_fee_ngn ?? 0);
  if (trip > 0) {
    return trip + booking + small;
  }
  return 0;
}

function entityPaymentMinAmountNgn(row) {
  return expectedFlutterwaveChargeNgn(row);
}

/**
 * Strict match: paid amount must equal frozen total (±1 NGN tolerance).
 */
function assertExactFlutterwaveAmount(paidAmount, entityRow) {
  const expected = expectedFlutterwaveChargeNgn(entityRow);
  const paid = roundNgn(paidAmount);
  if (expected <= 0) {
    return { ok: true, expected, paid };
  }
  if (Math.abs(paid - expected) <= 1) {
    return { ok: true, expected, paid };
  }
  return {
    ok: false,
    reason: "amount_mismatch",
    expected_total_ngn: expected,
    paid_amount_ngn: paid,
  };
}

module.exports = {
  expectedFlutterwaveChargeNgn,
  entityPaymentMinAmountNgn,
  assertExactFlutterwaveAmount,
  roundNgn,
};

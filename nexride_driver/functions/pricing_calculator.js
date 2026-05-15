/**
 * Authoritative rider-facing pricing (NGN). Used by ride, dispatch, and merchant order flows.
 * Riders pay by card/bank only — no rider wallets.
 */

const { platformFeeNgn, smallOrderFeeNgn, smallOrderThresholdNgn } = require("./params");

const COMMERCE_FLOWS = new Set([
  "merchant_order",
  "food_order",
  "mart_order",
  "store_order",
]);

const RIDE_FLOWS = new Set(["ride_booking", "ride", "dispatch_request", "dispatch_delivery"]);

/**
 * @param {object} input
 * @param {string} input.flow
 * @param {number} [input.subtotal_ngn]
 * @param {number} [input.delivery_fee_ngn]
 * @param {number} [input.trip_fare_ngn] - ride/dispatch trip component
 */
function computeRiderPricing(input = {}) {
  const flow = String(input.flow ?? "ride_booking").trim().toLowerCase();
  const platformFee = platformFeeNgn();
  let subtotal = Math.round(Math.max(0, Number(input.subtotal_ngn ?? 0) || 0));
  let deliveryFee = Math.round(Math.max(0, Number(input.delivery_fee_ngn ?? 0) || 0));
  const tripFare = Math.round(Math.max(0, Number(input.trip_fare_ngn ?? 0) || 0));

  if (RIDE_FLOWS.has(flow)) {
    if (flow === "dispatch_request" || flow === "dispatch_delivery") {
      deliveryFee = tripFare > 0 ? tripFare : deliveryFee;
      subtotal = 0;
    } else {
      subtotal = tripFare > 0 ? tripFare : subtotal;
      if (deliveryFee <= 0 && subtotal <= 0 && tripFare > 0) {
        subtotal = tripFare;
      }
    }
  }

  let smallOrderFee = 0;
  if (COMMERCE_FLOWS.has(flow) && subtotal > 0 && subtotal < smallOrderThresholdNgn()) {
    smallOrderFee = smallOrderFeeNgn();
  }

  const total = subtotal + deliveryFee + platformFee + smallOrderFee;

  return {
    flow,
    subtotal_ngn: subtotal,
    delivery_fee_ngn: deliveryFee,
    platform_fee_ngn: platformFee,
    small_order_fee_ngn: smallOrderFee,
    total_ngn: total,
    fee_breakdown: {
      subtotal_ngn: subtotal,
      delivery_fee_ngn: deliveryFee,
      platform_fee_ngn: platformFee,
      small_order_fee_ngn: smallOrderFee,
      total_ngn: total,
      small_order_threshold_ngn: smallOrderThresholdNgn(),
    },
  };
}

/**
 * Reject tampered client totals (±1 NGN tolerance).
 */
function assertClientTotalMatches(pricing, clientTotalRaw) {
  const clientTotal = Number(clientTotalRaw);
  if (!Number.isFinite(clientTotal) || clientTotal <= 0) {
    return { ok: true };
  }
  const diff = Math.abs(Math.round(clientTotal) - pricing.total_ngn);
  if (diff <= 1) {
    return { ok: true };
  }
  return {
    ok: false,
    reason: "total_mismatch",
    reason_code: "pricing_total_mismatch",
    message: "Order total does not match server pricing. Refresh and try again.",
    retryable: true,
    expected_total_ngn: pricing.total_ngn,
    client_total_ngn: Math.round(clientTotal),
    fee_breakdown: pricing.fee_breakdown,
  };
}

module.exports = {
  COMMERCE_FLOWS,
  RIDE_FLOWS,
  computeRiderPricing,
  assertClientTotalMatches,
};

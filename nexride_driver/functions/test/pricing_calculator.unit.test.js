const assert = require("node:assert/strict");
const { test } = require("node:test");
const {
  computeRiderPricing,
  assertClientTotalMatches,
} = require("../pricing_calculator");

test("ride booking always includes ₦30 platform fee", () => {
  const p = computeRiderPricing({ flow: "ride_booking", trip_fare_ngn: 2500 });
  assert.equal(p.platform_fee_ngn, 30);
  assert.equal(p.small_order_fee_ngn, 0);
  assert.equal(p.total_ngn, 2530);
});

test("dispatch request includes platform fee on delivery fare", () => {
  const p = computeRiderPricing({ flow: "dispatch_request", trip_fare_ngn: 1200 });
  assert.equal(p.delivery_fee_ngn, 1200);
  assert.equal(p.platform_fee_ngn, 30);
  assert.equal(p.total_ngn, 1230);
});

test("food order below threshold adds small-order fee", () => {
  const p = computeRiderPricing({
    flow: "food_order",
    subtotal_ngn: 2000,
    delivery_fee_ngn: 500,
  });
  assert.equal(p.platform_fee_ngn, 30);
  assert.equal(p.small_order_fee_ngn, 15);
  assert.equal(p.total_ngn, 2545);
});

test("food order at/above threshold has no small-order fee", () => {
  const p = computeRiderPricing({
    flow: "food_order",
    subtotal_ngn: 3000,
    delivery_fee_ngn: 500,
  });
  assert.equal(p.small_order_fee_ngn, 0);
  assert.equal(p.total_ngn, 3530);
});

test("assertClientTotalMatches rejects tampered total", () => {
  const p = computeRiderPricing({ flow: "ride_booking", trip_fare_ngn: 1000 });
  const r = assertClientTotalMatches(p, 1000);
  assert.equal(r.ok, false);
  assert.equal(r.reason_code, "pricing_total_mismatch");
});

test("assertClientTotalMatches accepts matching total", () => {
  const p = computeRiderPricing({ flow: "ride_booking", trip_fare_ngn: 1000 });
  const r = assertClientTotalMatches(p, p.total_ngn);
  assert.equal(r.ok, true);
});

test("pricing has no rider wallet fields", () => {
  const p = computeRiderPricing({ flow: "food_order", subtotal_ngn: 500, delivery_fee_ngn: 200 });
  assert.equal(p.rider_wallet_balance, undefined);
  assert.equal(p.rider_withdrawal_fee, undefined);
});

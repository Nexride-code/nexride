const assert = require("node:assert/strict");
const { test } = require("node:test");
const {
  normalizePricingConfig,
  computeBookingFeeNgn,
  pricingSnapshotFromConfig,
} = require("../app_config_pricing");
const { computeRiderPricing } = require("../pricing_calculator");
const { expectedFlutterwaveChargeNgn } = require("../payment_charge_expectations");
const rideFinance = require("../ride_finance_settlement");

const percentPolicy = normalizePricingConfig({
  bookingFeeMode: "max_fixed_or_percentage",
  bookingFeeNgn: 100,
  bookingFeePercent: 3,
  bookingFeeMinNgn: 100,
  bookingFeeMaxNgn: null,
  commissionRate: 0.1,
  cities: {},
});

test("₦10,000 fare with 3% max policy gives ₦300 booking fee", () => {
  assert.equal(computeBookingFeeNgn(percentPolicy, 10000), 300);
  const pricing = computeRiderPricing({ flow: "ride_booking", trip_fare_ngn: 10000 }, percentPolicy);
  assert.equal(pricing.platform_fee_ngn, 300);
  assert.equal(pricing.total_ngn, 10300);
});

test("₦2,000 fare with 3% and min ₦100 gives ₦100 booking fee", () => {
  const cfg = normalizePricingConfig({
    bookingFeeMode: "percentage",
    bookingFeePercent: 3,
    bookingFeeMinNgn: 100,
    bookingFeeNgn: 100,
    cities: {},
  });
  assert.equal(computeBookingFeeNgn(cfg, 2000), 100);
});

test("fixed mode still uses flat booking fee", () => {
  const cfg = normalizePricingConfig({
    bookingFeeMode: "fixed",
    bookingFeeNgn: 45,
    bookingFeePercent: 3,
    bookingFeeMinNgn: 100,
    cities: {},
  });
  assert.equal(computeBookingFeeNgn(cfg, 10000), 45);
  const pricing = computeRiderPricing({ flow: "ride_booking", trip_fare_ngn: 10000 }, cfg);
  assert.equal(pricing.platform_fee_ngn, 45);
});

test("max_fixed_or_percentage uses higher of fixed, percent, and minimum", () => {
  assert.equal(computeBookingFeeNgn(percentPolicy, 1000), 100);
  assert.equal(computeBookingFeeNgn(percentPolicy, 2581), 100);
  assert.equal(computeBookingFeeNgn(percentPolicy, 5000), 150);
  assert.equal(computeBookingFeeNgn(percentPolicy, 20000), 600);
});

test("optional max cap clamps booking fee", () => {
  const cfg = normalizePricingConfig({
    bookingFeeMode: "max_fixed_or_percentage",
    bookingFeeNgn: 100,
    bookingFeePercent: 3,
    bookingFeeMinNgn: 100,
    bookingFeeMaxNgn: 250,
    cities: {},
  });
  assert.equal(computeBookingFeeNgn(cfg, 10000), 250);
});

test("VA total equals trip fare plus frozen booking fee", () => {
  const pricing = computeRiderPricing({ flow: "ride_booking", trip_fare_ngn: 5000 }, percentPolicy);
  const ride = {
    fare: 5000,
    trip_fare_ngn: 5000,
    platform_fee_ngn: pricing.platform_fee_ngn,
    booking_fee_ngn: pricing.platform_fee_ngn,
    total_ngn: pricing.total_ngn,
    pricing_snapshot: pricingSnapshotFromConfig(
      percentPolicy,
      5000,
      pricing.total_ngn,
      "lagos",
      "ride",
    ),
  };
  assert.equal(expectedFlutterwaveChargeNgn(ride), 5150);
});

test("settlement platform booking fee uses frozen snapshot not latest config", () => {
  const ride = {
    fare: 10000,
    total_ngn: 10300,
    pricing_snapshot: {
      commission_rate: 0.1,
      booking_fee_ngn: 300,
      total_ngn: 10300,
      trip_fare_ngn: 10000,
      frozen: true,
    },
    platform_fee_ngn: 300,
  };
  const updatedConfig = normalizePricingConfig({
    ...percentPolicy,
    bookingFeePercent: 10,
    bookingFeeMinNgn: 500,
  });
  const breakdown = rideFinance.computeRideFinanceBreakdown(ride, {
    pricingConfig: updatedConfig,
  });
  assert.equal(breakdown.booking_fee_ngn, 300);
});

test("existing ride snapshot booking fee is unchanged after admin config update", () => {
  const oldSnapshot = pricingSnapshotFromConfig(percentPolicy, 2581, 2681, "lagos", "ride");
  const newConfig = normalizePricingConfig({
    bookingFeeMode: "fixed",
    bookingFeeNgn: 999,
    bookingFeePercent: 10,
    bookingFeeMinNgn: 999,
    cities: {},
  });
  const freshSnapshot = pricingSnapshotFromConfig(newConfig, 2581, 3580, "lagos", "ride");
  assert.equal(oldSnapshot.booking_fee_ngn, 100);
  assert.equal(freshSnapshot.booking_fee_ngn, 999);
  assert.notEqual(oldSnapshot.booking_fee_ngn, freshSnapshot.booking_fee_ngn);
});

test("dispatch delivery pricing uses dispatch policy not ride policy", () => {
  const cfg = normalizePricingConfig({
    rides: {
      bookingFeeMode: "max_fixed_or_percentage",
      bookingFeeNgn: 100,
      bookingFeePercent: 3,
      bookingFeeMinNgn: 100,
    },
    dispatch: {
      bookingFeeMode: "max_fixed_or_percentage",
      bookingFeeNgn: 150,
      bookingFeePercent: 5,
      bookingFeeMinNgn: 150,
    },
    cities: {},
  });
  const pricing = computeRiderPricing({ flow: "dispatch_request", trip_fare_ngn: 5000 }, cfg);
  assert.equal(pricing.platform_fee_ngn, 250);
  assert.equal(pricing.total_ngn, 5250);
});

test("dispatch default booking fee examples", () => {
  const cfg = normalizePricingConfig({ cities: {} });
  assert.equal(computeBookingFeeNgn(cfg, 1000, "dispatch_request"), 150);
  assert.equal(computeBookingFeeNgn(cfg, 5000, "dispatch_request"), 250);
  assert.equal(computeBookingFeeNgn(cfg, 10000, "dispatch_request"), 500);
  assert.equal(computeBookingFeeNgn(cfg, 20000, "dispatch_request"), 1000);
});

test("commerce flow keeps flat booking fee and ignores percentage base", () => {
  const pricing = computeRiderPricing(
    { flow: "food_order", subtotal_ngn: 10000, delivery_fee_ngn: 500 },
    percentPolicy,
  );
  assert.equal(pricing.platform_fee_ngn, 100);
  assert.equal(pricing.total_ngn, 10600);
});

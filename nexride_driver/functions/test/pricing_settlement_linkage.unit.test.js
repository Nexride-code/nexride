const assert = require("node:assert/strict");
const { test } = require("node:test");
const path = require("node:path");
const { normalizePricingConfig, pricingSnapshotFromConfig } = require("../app_config_pricing");
const { quoteTripFare, assertClientTripFareMatches } = require("../fare_quote_engine");
const { computeRiderPricing } = require("../pricing_calculator");
const { expectedFlutterwaveChargeNgn } = require("../payment_charge_expectations");
const rideFinance = require("../ride_finance_settlement");

const lagosConfig = normalizePricingConfig({
  cities: {
    lagos: {
      city: "Lagos",
      baseFareNgn: 800,
      perKmNgn: 100,
      perMinuteNgn: 10,
      minimumFareNgn: 1000,
      enabled: true,
    },
  },
  commissionRate: 0.15,
  bookingFeeNgn: 50,
  updatedAt: 1000,
});

test("changing booking fee changes new quote total", () => {
  const lowFee = computeRiderPricing({ flow: "ride_booking", trip_fare_ngn: 2000 }, lagosConfig);
  const highFeeConfig = normalizePricingConfig({
    ...lagosConfig,
    rides: {
      ...lagosConfig.rides,
      bookingFeeNgn: 80,
    },
  });
  const highFee = computeRiderPricing({ flow: "ride_booking", trip_fare_ngn: 2000 }, highFeeConfig);
  assert.equal(highFee.total_ngn - lowFee.total_ngn, 30);
  assert.equal(highFee.platform_fee_ngn, 80);
});

test("changing commission changes driver net and platform commission", () => {
  const ride = {
    fare: 2000,
    pricing_snapshot: { commission_rate: 0.2, booking_fee_ngn: 50 },
  };
  const breakdown = rideFinance.computeRideFinanceBreakdown(ride, { commissionExempt: false });
  assert.equal(breakdown.commission_ngn, 400);
  assert.equal(breakdown.driver_net_ngn, 1600);
  assert.equal(breakdown.commission_rate, 0.2);
});

test("server quote uses per-state fare rules from app_config/pricing", () => {
  const quote = quoteTripFare({
    config: lagosConfig,
    cityOrMarket: "lagos",
    distanceKm: 5,
    etaMin: 10,
    flow: "ride",
  });
  assert.equal(quote.trip_fare_ngn, 1400);
});

test("frozen total_ngn is used for Flutterwave charge expectation", () => {
  const ride = {
    fare: 1000,
    platform_fee_ngn: 30,
    total_ngn: 1030,
    pricing_snapshot: { total_ngn: 1080, trip_fare_ngn: 1000 },
  };
  assert.equal(expectedFlutterwaveChargeNgn(ride), 1080);
});

test("client fare mismatch is rejected when distance provided", () => {
  const quote = quoteTripFare({
    config: lagosConfig,
    cityOrMarket: "lagos",
    distanceKm: 2,
    etaMin: 5,
    flow: "ride",
  });
  const mismatch = assertClientTripFareMatches(quote.trip_fare_ngn, quote.trip_fare_ngn + 500);
  assert.equal(mismatch.ok, false);
  assert.equal(mismatch.reason_code, "fare_quote_mismatch");
});

test("verified payment settlement uses frozen commission on ride record", () => {
  const ride = {
    fare: 3000,
    total_ngn: 3050,
    pricing_snapshot: {
      commission_rate: 0.12,
      booking_fee_ngn: 50,
      total_ngn: 3050,
      trip_fare_ngn: 3000,
    },
    platform_fee_ngn: 50,
  };
  const breakdown = rideFinance.computeRideFinanceBreakdown(ride);
  assert.equal(breakdown.commission_ngn, 360);
  assert.equal(breakdown.booking_fee_ngn, 50);
  assert.equal(breakdown.driver_net_ngn, 2640);
});

test("pricing snapshot freezes admin booking fee at entity create", () => {
  const cfg = normalizePricingConfig({
    ...lagosConfig,
    rides: {
      ...lagosConfig.rides,
      bookingFeeNgn: 75,
    },
  });
  const pricing = computeRiderPricing({ flow: "ride_booking", trip_fare_ngn: 2000 }, cfg);
  const snap = pricingSnapshotFromConfig(cfg, 2000, pricing.total_ngn, "lagos", "ride");
  assert.equal(pricing.platform_fee_ngn, 75);
  assert.equal(snap.booking_fee_ngn, 75);
  assert.equal(snap.frozen, true);
});

test("ride create and payment fallbacks load app_config before pricing", () => {
  const rideSrc = require("fs").readFileSync(
    path.join(__dirname, "../ride_callables.js"),
    "utf8",
  );
  const paymentSrc = require("fs").readFileSync(
    path.join(__dirname, "../payment_flow.js"),
    "utf8",
  );
  assert.match(
    rideSrc,
    /validateAndFreezeEntityPricing\(db,\s*\{[\s\S]*flow:\s*"ride_booking"/,
  );
  assert.doesNotMatch(rideSrc, /await rideRef\.set\(payload\)[\s\S]{0,120}pricingValidation/);
  assert.match(paymentSrc, /loadAppPricingConfig\(db\)/);
  assert.match(paymentSrc, /computeRiderPricing\([\s\S]*pricingConfig/);
});

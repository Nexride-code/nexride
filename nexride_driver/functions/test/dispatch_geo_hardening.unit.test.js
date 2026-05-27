"use strict";

const { describe, it } = require("node:test");
const assert = require("node:assert/strict");
const {
  normalizeDispatchKey,
  rejectCanonicalMarketMutation,
  applyCanonicalDispatchGeoToRidePayload,
  applyCanonicalDispatchGeoToDriverUpdates,
  assertRideCanonicalFieldsAligned,
  assertDriverCanonicalFieldsAligned,
} = require("../dispatch_engine/dispatch_geo_normalizer");
const {
  driverRideMarketsAligned,
  driverDispatchMarketId,
  rideDispatchMarketId,
  evaluateDriverGeoAndMode,
} = require("../driver_dispatch_gates");
const {
  driverShouldBeInDispatchIndex,
} = require("../dispatch_engine/dispatch_index_engine");

describe("dispatch geo hardening matrix", () => {
  it("A: Driver Abuja + Rider Abuja => MATCH", () => {
    const ride = applyCanonicalDispatchGeoToRidePayload(
      { ride_id: "r1", pickup: { lat: 9.08, lng: 7.39 } },
      { canonical_market_id: "abuja_fct", city_id: "wuse" },
    );
    const driver = applyCanonicalDispatchGeoToDriverUpdates(
      { is_online: true, status: "online_available", dispatch_state: "online_available" },
      { canonical_market_id: "abuja_fct", city_id: "gwarinpa" },
    );
    assert.equal(rideDispatchMarketId(ride), "abuja_fct");
    assert.equal(driverDispatchMarketId(driver), "abuja_fct");
    assert.equal(driverRideMarketsAligned(driver, ride), true);
    assert.equal(assertRideCanonicalFieldsAligned(ride, "r1"), true);
  });

  it("B: Driver Lagos + Rider Abuja => market mismatch (geo may also reject)", () => {
    const ride = applyCanonicalDispatchGeoToRidePayload(
      { ride_id: "r2", pickup: { lat: 9.08, lng: 7.39 } },
      { canonical_market_id: "abuja_fct" },
    );
    const driver = applyCanonicalDispatchGeoToDriverUpdates(
      {
        is_online: true,
        status: "online_available",
        lat: 6.45,
        lng: 3.39,
        location_mode: "gps",
        driver_availability_mode: "current_location",
        last_location_updated_at: Date.now(),
      },
      { canonical_market_id: "lagos" },
    );
    assert.equal(driverRideMarketsAligned(driver, ride), false);
    const geo = evaluateDriverGeoAndMode(driver, ride, Date.now(), {
      rideId: "r2",
      driverId: "d1",
    });
    assert.equal(geo.ok, false);
  });

  it("C: legacy mixed-case Abuja FCT normalizes to abuja_fct", () => {
    assert.equal(normalizeDispatchKey("Abuja FCT"), "abuja_fct");
    const driver = {
      dispatch_market_id: "Abuja FCT",
      canonical_market_id: "abuja_fct",
      market_pool: "abuja",
      is_online: true,
      status: "online_available",
    };
    assert.equal(driverDispatchMarketId(driver), "abuja_fct");
    assert.equal(assertDriverCanonicalFieldsAligned(driver, "d-legacy"), true);
  });

  it("D: offline driver excluded from dispatch index", () => {
    const ok = driverShouldBeInDispatchIndex(
      { is_online: false, status: "offline", canonical_market_id: "abuja_fct" },
      null,
    );
    assert.equal(ok, false);
  });

  it("E: driver on active trip excluded from dispatch index", () => {
    const ok = driverShouldBeInDispatchIndex(
      {
        is_online: true,
        status: "online_available",
        canonical_market_id: "abuja_fct",
        active_ride_id: "ride-active",
      },
      { is_online: true },
    );
    assert.equal(ok, false);
  });

  it("F: retry retains canonical market (immutable fields rejected on patch)", () => {
    const ride = applyCanonicalDispatchGeoToRidePayload(
      { market: "abuja", market_pool: "abuja" },
      { canonical_market_id: "abuja_fct" },
    );
    const reject = rejectCanonicalMarketMutation(
      { market: "lagos", market_pool: "lagos" },
      { rideId: "r3", source: "retry_patch" },
    );
    assert.equal(reject.ok, false);
    assert.equal(ride.market, "abuja_fct");
    assert.equal(ride.market_pool, "abuja_fct");
  });
});

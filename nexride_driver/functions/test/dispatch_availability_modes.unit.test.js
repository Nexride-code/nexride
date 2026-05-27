"use strict";

const { describe, it } = require("node:test");
const assert = require("node:assert/strict");
const {
  evaluateDriverGeoAndMode,
  driverRideMarketsAligned,
} = require("../driver_dispatch_gates");

describe("dispatch availability modes", () => {
  const rideAbuja = {
    ride_id: "r1",
    canonical_market_id: "abuja_fct",
    dispatch_market_id: "abuja_fct",
    pickup: { lat: 9.05, lng: 7.49 },
  };

  it("service_area driver matches without GPS coords", () => {
    const driver = {
      canonical_market_id: "abuja_fct",
      dispatch_market_id: "abuja_fct",
      dispatch_availability_mode: "service_area",
      service_area_id: "wuse",
      location_permission_degraded: true,
    };
    assert.equal(driverRideMarketsAligned(driver, rideAbuja), true);
    const geo = evaluateDriverGeoAndMode(driver, rideAbuja, Date.now(), {
      rideId: "r1",
      driverId: "d1",
    });
    assert.equal(geo.ok, true);
    assert.equal(geo.detail, "service_area_market_match_no_gps_required");
  });

  it("service_area driver without service area id is rejected", () => {
    const driver = {
      canonical_market_id: "abuja_fct",
      dispatch_market_id: "abuja_fct",
      dispatch_availability_mode: "service_area",
    };
    const geo = evaluateDriverGeoAndMode(driver, rideAbuja, Date.now(), {
      rideId: "r1",
      driverId: "d2",
    });
    assert.equal(geo.ok, false);
    assert.equal(geo.detail, "service_area_mismatch");
  });

  it("gps driver without coords is rejected", () => {
    const driver = {
      canonical_market_id: "abuja_fct",
      dispatch_market_id: "abuja_fct",
      dispatch_availability_mode: "gps",
      last_dispatch_heartbeat: Date.now() - 60 * 60 * 1000,
    };
    const geo = evaluateDriverGeoAndMode(driver, rideAbuja, Date.now(), {
      rideId: "r1",
      driverId: "d3",
    });
    assert.equal(geo.ok, false);
    assert.equal(geo.detail, "gps_unavailable_for_gps_mode");
  });

  it("gps driver with online_start_location fallback can match in grace", () => {
    const now = Date.now();
    const driver = {
      canonical_market_id: "abuja_fct",
      dispatch_market_id: "abuja_fct",
      dispatch_availability_mode: "gps",
      last_dispatch_heartbeat: now - 30_000,
      online_start_location: { lat: 9.051, lng: 7.491 },
      online_start_location_at: now - 60_000,
    };
    const geo = evaluateDriverGeoAndMode(driver, rideAbuja, now, {
      rideId: "r1",
      driverId: "d4",
    });
    assert.equal(geo.ok, true);
  });

  it("gps driver too far is geo_radius_fail", () => {
    const now = Date.now();
    const driver = {
      canonical_market_id: "abuja_fct",
      dispatch_market_id: "abuja_fct",
      dispatch_availability_mode: "gps",
      last_dispatch_heartbeat: now,
      last_location: { lat: 6.45, lng: 3.39 },
      last_location_updated_at: now,
    };
    const geo = evaluateDriverGeoAndMode(driver, rideAbuja, now, {
      rideId: "r1",
      driverId: "d5",
    });
    assert.equal(geo.ok, false);
    assert.equal(geo.detail, "geo_radius_fail");
  });
});

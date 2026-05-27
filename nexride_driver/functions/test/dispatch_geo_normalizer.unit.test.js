"use strict";

const { describe, it } = require("node:test");
const assert = require("node:assert/strict");
const {
  normalizeDispatchKey,
  resolveCanonicalDispatchMarket,
  applyCanonicalDispatchGeoToRidePayload,
} = require("../dispatch_engine/dispatch_geo_normalizer");

describe("dispatch_geo_normalizer", () => {
  it("normalizes case, spaces, and hyphens", () => {
    assert.equal(normalizeDispatchKey("Lagos"), "lagos");
    assert.equal(normalizeDispatchKey(" Abuja FCT "), "abuja_fct");
    assert.equal(normalizeDispatchKey("abuja-fct"), "abuja_fct");
    assert.equal(normalizeDispatchKey(" Wuse 2 "), "wuse_2");
  });

  it("aliases abuja to abuja_fct", () => {
    assert.equal(normalizeDispatchKey("abuja"), "abuja_fct");
    assert.equal(normalizeDispatchKey("Abuja"), "abuja_fct");
  });

  it("prefers resolved_dispatch_market_id on rides", () => {
    assert.equal(
      resolveCanonicalDispatchMarket({
        market: "abuja",
        market_pool: "abuja",
        dispatch_market_id: "abuja",
        resolved_dispatch_market_id: "abuja_fct",
      }),
      "abuja_fct",
    );
  });

  it("rewrites ride payload markets consistently", () => {
    const payload = {
      market: "abuja",
      market_pool: "abuja",
      pickup: { market: "abuja", lat: 1, lng: 2 },
      match_debug: {},
    };
    applyCanonicalDispatchGeoToRidePayload(payload, {
      canonical_market_id: "abuja_fct",
      region_id: "abuja",
      city_id: "wuse",
    });
    assert.equal(payload.market, "abuja_fct");
    assert.equal(payload.market_pool, "abuja_fct");
    assert.equal(payload.dispatch_market_id, "abuja_fct");
    assert.equal(payload.pickup.market, "abuja_fct");
    assert.equal(payload.service_area.canonical_market_id, "abuja_fct");
  });
});

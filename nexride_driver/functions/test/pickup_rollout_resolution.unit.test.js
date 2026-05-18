"use strict";

const assert = require("node:assert/strict");
const {
  resolvePickupFromCatalogEntries,
  rolloutSeedCatalogEntries,
} = require("../ecosystem/delivery_regions");
const { evaluateDriverMatchCandidate } = require("../driver_match_ranking");

const catalog = rolloutSeedCatalogEntries();
const gates = { soft_verification: true, require_bvn: false };
const now = Date.now();

// Asaba pickup coords resolve to delta/asaba (not anambra/onitsha).
const asabaPickup = resolvePickupFromCatalogEntries(catalog, 6.1982, 6.7349, "rides");
assert.equal(asabaPickup.ok, true);
assert.equal(asabaPickup.region_id, "delta");
assert.equal(asabaPickup.city_id, "asaba");
assert.equal(asabaPickup.dispatch_market_id, "delta");

// Ndoma Egba–style coords still closer to Asaba than Onitsha.
const ndomaEgba = resolvePickupFromCatalogEntries(catalog, 6.195, 6.745, "rides");
assert.equal(ndomaEgba.ok, true);
assert.equal(ndomaEgba.city_id, "asaba");
assert.equal(ndomaEgba.dispatch_market_id, "delta");

// Onitsha center resolves to anambra/onitsha.
const onitshaPickup = resolvePickupFromCatalogEntries(catalog, 6.1667, 6.7833, "rides");
assert.equal(onitshaPickup.ok, true);
assert.equal(onitshaPickup.region_id, "anambra");
assert.equal(onitshaPickup.city_id, "onitsha");
assert.equal(onitshaPickup.dispatch_market_id, "anambra");

// Pickup outside Nigeria rollout bubbles is blocked.
const outside = resolvePickupFromCatalogEntries(catalog, 4.0, 4.0, "rides");
assert.equal(outside.ok, false);
assert.equal(outside.reason, "pickup_outside_enabled_city");

const asabaRide = {
  market_pool: "delta",
  dispatch_market_id: "delta",
  resolved_service_city_id: "asaba",
  pickup: { lat: 6.1982, lng: 6.7349 },
  service_type: "ride",
};

const asabaDriver = {
  is_online: true,
  location_mode: "area",
  dispatch_market_id: "delta",
  service_area_city_id: "asaba",
  lat: 6.21,
  lng: 6.74,
  nexride_verified: true,
};

const onitshaDriver = {
  is_online: true,
  location_mode: "area",
  dispatch_market_id: "anambra",
  service_area_city_id: "onitsha",
  lat: 6.1667,
  lng: 6.7833,
  nexride_verified: true,
};

const asabaOk = evaluateDriverMatchCandidate("d1", asabaDriver, asabaRide, gates, now, {
  useSoft: true,
});
assert.equal(asabaOk.allowed, true);

const onitshaReject = evaluateDriverMatchCandidate("d2", onitshaDriver, asabaRide, gates, now, {
  useSoft: true,
});
assert.equal(onitshaReject.allowed, false);
assert.match(String(onitshaReject.filtered_reason || ""), /market|mismatch/i);

console.log("pickup_rollout_resolution.unit.test.js OK");

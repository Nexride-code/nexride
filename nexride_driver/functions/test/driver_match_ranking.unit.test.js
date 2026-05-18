"use strict";

const assert = require("node:assert/strict");
const {
  evaluateDriverMatchCandidate,
  sortEligibleCandidates,
  compareMatchCandidates,
  computeDriverPriorityGroup,
  PRIORITY_GPS_CLOSEST,
  PRIORITY_AREA_SAME_CITY,
  PRIORITY_AREA_SAME_MARKET,
} = require("../driver_match_ranking");
const { evaluateDriverGeoAndMode } = require("../driver_dispatch_gates");

const now = Date.now();
const gates = { soft_verification: true, require_bvn: false };

const asabaRide = {
  market_pool: "delta",
  dispatch_market_id: "delta",
  resolved_service_city_id: "asaba",
  pickup: { lat: 6.1982, lng: 6.7349 },
  service_type: "ride",
};

const asabaAreaDriver = {
  is_online: true,
  location_mode: "area",
  dispatch_market_id: "delta",
  service_area_city_id: "asaba",
  selected_service_area_id: "asaba",
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

const lagosDriver = {
  is_online: true,
  location_mode: "area",
  dispatch_market_id: "lagos",
  service_area_city_id: "ikeja",
  lat: 6.52,
  lng: 3.38,
  nexride_verified: true,
};

const gwarinpaRide = {
  market_pool: "abuja_fct",
  resolved_service_city_id: "gwarinpa",
  pickup: { lat: 9.08, lng: 7.39 },
  service_type: "ride",
};

const asokoroDriver = {
  is_online: true,
  location_mode: "area",
  dispatch_market_id: "abuja_fct",
  service_area_city_id: "asokoro",
  selected_service_area_id: "asokoro",
  lat: 9.04,
  lng: 7.52,
  nexride_verified: true,
};

const gwarinpaDriver = {
  is_online: true,
  location_mode: "area",
  dispatch_market_id: "abuja_fct",
  service_area_city_id: "gwarinpa",
  selected_service_area_id: "gwarinpa",
  lat: 9.07,
  lng: 7.4,
  nexride_verified: true,
};

// Asaba rider + Asaba area driver = eligible
const asabaOk = evaluateDriverMatchCandidate("d1", asabaAreaDriver, asabaRide, gates, now, {
  useSoft: true,
});
assert.equal(asabaOk.allowed, true);
assert.equal(asabaOk.priority_group, PRIORITY_AREA_SAME_CITY);

// Asaba rider + Onitsha (Anambra) driver = rejected (different dispatch market)
const onitshaReject = evaluateDriverMatchCandidate("d2", onitshaDriver, asabaRide, gates, now, {
  useSoft: true,
});
assert.equal(onitshaReject.allowed, false);
assert.match(String(onitshaReject.filtered_reason || ""), /market|mismatch/i);

// Asaba rider + Lagos driver = rejected (market)
const lagosReject = evaluateDriverMatchCandidate("d5", lagosDriver, asabaRide, gates, now, {
  useSoft: true,
});
assert.equal(lagosReject.allowed, false);
assert.match(String(lagosReject.filtered_reason || ""), /market|mismatch/i);

// Gwarinpa rider + Asokoro driver = eligible, lower priority than Gwarinpa driver
const asokoroCand = evaluateDriverMatchCandidate("d3", asokoroDriver, gwarinpaRide, gates, now, {
  useSoft: true,
});
const gwarinpaCand = evaluateDriverMatchCandidate("d4", gwarinpaDriver, gwarinpaRide, gates, now, {
  useSoft: true,
});
assert.equal(asokoroCand.allowed, true);
assert.equal(gwarinpaCand.allowed, true);
assert.equal(asokoroCand.priority_group, PRIORITY_AREA_SAME_MARKET);
assert.equal(gwarinpaCand.priority_group, PRIORITY_AREA_SAME_CITY);
const sortedAbuja = sortEligibleCandidates([asokoroCand, gwarinpaCand]);
assert.equal(sortedAbuja[0].driver_id, "d4");

// GPS nearer ranks before area-mode driver
const nearGps = {
  is_online: true,
  driver_availability_mode: "current_location",
  dispatch_market_id: "abuja_fct",
  lat: 9.081,
  lng: 7.391,
  last_location_updated_at: now - 60000,
  nexride_verified: true,
};
const gpsCand = evaluateDriverMatchCandidate("gps1", nearGps, gwarinpaRide, gates, now, {
  useSoft: true,
});
const areaCand = evaluateDriverMatchCandidate("area1", asokoroDriver, gwarinpaRide, gates, now, {
  useSoft: true,
});
const sortedMix = sortEligibleCandidates([areaCand, gpsCand]);
assert.equal(sortedMix[0].driver_id, "gps1");
assert.equal(sortedMix[0].priority_group, PRIORITY_GPS_CLOSEST);

// stale GPS rejected
const staleGps = evaluateDriverGeoAndMode(
  {
    driver_availability_mode: "current_location",
    dispatch_market_id: "abuja_fct",
    lat: 9.08,
    lng: 7.39,
    last_location_updated_at: now - 20 * 60 * 1000,
  },
  gwarinpaRide,
  now,
);
assert.equal(staleGps.ok, false);

// active ride rejected
const busy = evaluateDriverMatchCandidate("busy1", asabaAreaDriver, asabaRide, gates, now, {
  useSoft: true,
  activeRideId: "ride_xyz",
});
assert.equal(busy.allowed, false);
assert.match(String(busy.filtered_reason || ""), /active_ride/i);

// sort order: priority then distance
assert.ok(
  compareMatchCandidates(
    { priority_group: 1, distance_to_pickup_km: 2, allowed: true },
    { priority_group: 2, distance_to_pickup_km: 0.5, allowed: true },
  ) < 0,
);

const pri = computeDriverPriorityGroup(gwarinpaDriver, gwarinpaRide);
assert.equal(pri.priority_group, PRIORITY_AREA_SAME_CITY);

console.log("driver_match_ranking.unit.test.js OK");

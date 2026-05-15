/**
 * Self-tests (run: node functions/test/driver_dispatch_gates.selftest.js)
 */
const assert = require("node:assert/strict");
const {
  evaluateDriverForOffer,
  evaluateDriverForOfferSoft,
  evaluateDriverGeoAndMode,
  summarizeDriverForFanout,
} = require("../driver_dispatch_gates");

const ride = { market_pool: "lagos", service_type: "ride" };
const rideSpaced = { market: "Lagos City", service_type: "ride" };

const suspended = {
  suspended: true,
  dispatch_market: "lagos",
  verification: {},
};
assert.equal(evaluateDriverForOffer(suspended, {}, ride).ok, false);

const unverifiedNoDocs = {
  dispatch_market: "lagos",
  nexride_verified: false,
  verification: {},
};
assert.equal(evaluateDriverForOffer(unverifiedNoDocs, {}, ride).ok, false);

const soft = evaluateDriverForOffer(unverifiedNoDocs, { soft_verification: true }, ride);
assert.equal(soft.ok, true);

const verifiedAdmin = {
  dispatch_market: "lagos",
  nexride_verified: true,
  verification: { restrictions: {} },
};
assert.equal(evaluateDriverForOffer(verifiedAdmin, {}, ride).ok, true);

const docOk = {
  dispatch_market: "lagos",
  nexride_verified: false,
  verification: {
    documents: {
      nin: { status: "approved" },
      drivers_license: { status: "verified" },
      vehicle_documents: { status: "approved" },
    },
  },
};
assert.equal(evaluateDriverForOffer(docOk, {}, ride).ok, true);

const bvnRequired = evaluateDriverForOffer(docOk, { require_bvn: true }, ride);
assert.equal(bvnRequired.ok, false);

const fanoutSnap = summarizeDriverForFanout("abc", {
  dispatch_market: "lagos",
  is_online: true,
  status: "available",
  dispatch_state: "available",
  nexride_verified: true,
});
assert.equal(fanoutSnap.uid, "abc");
assert.equal(fanoutSnap.online, true);
assert.equal(fanoutSnap.dispatch_market, "lagos");

const spacedDriver = {
  dispatch_market: "lagos_city",
  nexride_verified: true,
  verification: { restrictions: {} },
};
assert.equal(
  evaluateDriverForOffer(spacedDriver, { soft_verification: false }, rideSpaced).ok,
  true,
);

const onlineDocDriver = {
  ...docOk,
  is_online: true,
  status: "available",
  dispatch_state: "available",
  dispatch_market: "lagos",
};
const softWithVerify = evaluateDriverForOfferSoft(onlineDocDriver, ride, {
  require_bvn: false,
});
assert.equal(softWithVerify.ok, true);

const unverifiedOnline = {
  ...unverifiedNoDocs,
  is_online: true,
  status: "available",
  dispatch_state: "available",
  dispatch_market: "lagos",
};
const softBlocked = evaluateDriverForOfferSoft(unverifiedOnline, ride, {
  require_bvn: false,
});
assert.equal(softBlocked.ok, false);

const now = Date.now();
const rideLekki = {
  market_pool: "lagos",
  service_type: "ride",
  resolved_service_city_id: "lekki",
  pickup: { lat: 6.45, lng: 3.39 },
};
const saMismatch = evaluateDriverGeoAndMode(
  {
    driver_availability_mode: "service_area",
    selected_service_area_id: "yaba",
    dispatch_market: "lagos",
  },
  rideLekki,
  now,
);
assert.equal(saMismatch.ok, false);

const saOk = evaluateDriverGeoAndMode(
  {
    driver_availability_mode: "service_area",
    selected_service_area_id: "lekki",
    dispatch_market: "lagos",
  },
  rideLekki,
  now,
);
assert.equal(saOk.ok, true);

const gpsOk = evaluateDriverGeoAndMode(
  {
    driver_availability_mode: "current_location",
    lat: 6.451,
    lng: 3.391,
    last_location_updated_at: now - 60_000,
    dispatch_market: "lagos",
  },
  { market_pool: "lagos", pickup: { lat: 6.45, lng: 3.39 } },
  now,
);
assert.equal(gpsOk.ok, true);

console.log("driver_dispatch_gates.selftest: ok");

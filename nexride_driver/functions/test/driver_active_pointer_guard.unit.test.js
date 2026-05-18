const assert = require("node:assert/strict");
const { test } = require("node:test");
const {
  tripIdBlocksDriverOffers,
  classifyTripForDriverOffers,
  canonicalAssignedRideDriverId,
  evaluateActivePointerDecision,
  evaluateActiveTripFreshness,
  isSearchingRide,
  ASSIGNED_NOT_STARTED_STALE_MS,
  ENROUTE_IN_TRIP_STALE_MS,
} = require("../driver_active_pointer_guard");

const DRIVER = "Hx8Nr6wVU6PfcBDbDdooNhHLe7H2";
const OTHER = "other_driver";
const OLD_TRIP = "-Osq8iZFm_JgC7Lbr1C3";
const NEW_OFFER = "-OstanWC5tKMflrjpRU5";

test("searching ride with driver_id waiting must NOT block offers", () => {
  const ride = {
    rider_id: "r1",
    driver_id: "waiting",
    trip_state: "searching",
    status: "searching",
  };
  const verdict = evaluateActivePointerDecision({
    driverId: DRIVER,
    tripId: "ride1",
    ride,
  });
  assert.equal(verdict.blocks, false);
  assert.equal(verdict.decision, "clear");
});

test("ride missing must NOT block offers", () => {
  const verdict = evaluateActivePointerDecision({
    driverId: DRIVER,
    tripId: "missing",
    ride: null,
    delivery: null,
  });
  assert.equal(verdict.blocks, false);
  assert.equal(verdict.decision, "clear");
});

test("active_trips missing + searching state must NOT block offers", () => {
  const ride = {
    rider_id: "r1",
    matched_driver_id: DRIVER,
    trip_state: "searching",
    status: "accepted",
  };
  assert.equal(isSearchingRide(ride), true);
  const verdict = evaluateActivePointerDecision({
    driverId: DRIVER,
    tripId: "ride1",
    ride,
    activeTrip: null,
  });
  assert.equal(verdict.blocks, false);
});

test("old active_trips + incoming different offer clears (30+ min)", () => {
  const now = Date.now();
  const acceptedAt = now - 31 * 60 * 1000;
  const ride = {
    rider_id: "r1",
    matched_driver_id: DRIVER,
    trip_state: "driver_assigned",
    status: "accepted",
    accepted_at: acceptedAt,
  };
  const activeTrip = {
    driver_id: DRIVER,
    trip_state: "driver_assigned",
    updated_at: acceptedAt,
  };
  const verdict = evaluateActivePointerDecision({
    driverId: DRIVER,
    tripId: OLD_TRIP,
    ride,
    activeTrip,
    incomingOfferTripId: NEW_OFFER,
    nowMs: now,
  });
  assert.equal(verdict.blocks, false);
  assert.equal(verdict.decision, "clear");
  assert.equal(verdict.reason, "cross_offer_old_active_trip");
});

test("fresh accepted active trip blocks different offer", () => {
  const now = Date.now();
  const ride = {
    rider_id: "r1",
    matched_driver_id: DRIVER,
    trip_state: "driver_assigned",
    status: "accepted",
    accepted_at: now - 60_000,
  };
  const activeTrip = {
    driver_id: DRIVER,
    trip_state: "driver_assigned",
    updated_at: now - 30_000,
  };
  const verdict = evaluateActivePointerDecision({
    driverId: DRIVER,
    tripId: OLD_TRIP,
    ride,
    activeTrip,
    incomingOfferTripId: NEW_OFFER,
    nowMs: now,
  });
  assert.equal(verdict.blocks, true);
  assert.equal(verdict.reason, "active_trip_fresh");
  assert.equal(verdict.shouldRestoreActiveTrip, true);
});

test("in-trip active trip with recent updated_at blocks", () => {
  const now = Date.now();
  const ride = {
    rider_id: "r1",
    matched_driver_id: DRIVER,
    trip_state: "in_trip",
    status: "on_trip",
    started_at: now - 5 * 60 * 1000,
    updated_at: now - 60_000,
  };
  const activeTrip = {
    driver_id: DRIVER,
    trip_state: "in_trip",
    updated_at: now - 60_000,
  };
  const verdict = evaluateActivePointerDecision({
    driverId: DRIVER,
    tripId: "trip_live",
    ride,
    activeTrip,
    nowMs: now,
  });
  assert.equal(verdict.blocks, true);
  const freshness = evaluateActiveTripFreshness({
    ride,
    activeTrip,
    tripState: "in_trip",
    nowMs: now,
  });
  assert.equal(freshness.isFresh, true);
  assert.ok(freshness.ageMs <= ENROUTE_IN_TRIP_STALE_MS);
});

test("completed ride clears pointer", () => {
  const ride = {
    rider_id: "r1",
    matched_driver_id: DRIVER,
    trip_state: "completed",
    status: "completed",
  };
  const verdict = evaluateActivePointerDecision({
    driverId: DRIVER,
    tripId: "ride1",
    ride,
    activeTrip: { driver_id: DRIVER, trip_state: "completed" },
  });
  assert.equal(verdict.blocks, false);
  assert.equal(verdict.reason, "ride_terminal");
});

test("cancelled ride clears pointer", () => {
  const ride = {
    rider_id: "r1",
    matched_driver_id: DRIVER,
    trip_state: "cancelled",
    status: "cancelled",
  };
  const verdict = evaluateActivePointerDecision({
    driverId: DRIVER,
    tripId: "ride1",
    ride,
  });
  assert.equal(verdict.blocks, false);
});

test("active_trips assigned to another driver clears pointer", () => {
  const ride = {
    rider_id: "r1",
    matched_driver_id: OTHER,
    trip_state: "driver_assigned",
    status: "accepted",
    accepted_at: Date.now(),
  };
  const verdict = evaluateActivePointerDecision({
    driverId: DRIVER,
    tripId: "ride1",
    ride,
    activeTrip: { driver_id: OTHER, trip_state: "driver_assigned" },
  });
  assert.equal(verdict.blocks, false);
  assert.equal(verdict.reason, "ride_other_driver");
});

test("active_trips exists but ride missing clears", () => {
  const verdict = evaluateActivePointerDecision({
    driverId: DRIVER,
    tripId: "ride1",
    ride: null,
    activeTrip: { driver_id: DRIVER, trip_state: "driver_assigned" },
  });
  assert.equal(verdict.blocks, false);
  assert.equal(verdict.reason, "missing");
});

test("assigned not started stale TTL is 3 minutes", () => {
  const now = Date.now();
  const ts = now - ASSIGNED_NOT_STARTED_STALE_MS - 1;
  const freshness = evaluateActiveTripFreshness({
    ride: { accepted_at: ts, trip_state: "driver_assigned" },
    activeTrip: { updated_at: ts },
    tripState: "driver_assigned",
    nowMs: now,
  });
  assert.equal(freshness.isFresh, false);
});

test("canonicalAssignedRideDriverId ignores waiting placeholder", () => {
  const ride = { driver_id: "waiting", matched_driver_id: DRIVER };
  assert.equal(canonicalAssignedRideDriverId(ride), DRIVER);
});

test("tripIdBlocksDriverOffers returns missing for absent trip", async () => {
  const db = {
    ref: (path) => ({
      get: async () => ({ exists: () => false, val: () => null }),
    }),
  };
  const verdict = await tripIdBlocksDriverOffers(db, DRIVER, "missing_trip");
  assert.equal(verdict.blocks, false);
  assert.equal(verdict.reason, "missing");
});

const assert = require("node:assert/strict");
const { test } = require("node:test");
const {
  repairDriverDispatchBlockers,
  evaluateDriverBlocker,
} = require("../repair_driver_dispatch_blockers");
const {
  evaluateActivePointerDecision,
  ASSIGNED_NOT_STARTED_STALE_MS,
} = require("../driver_active_pointer_guard");

const DRIVER = "driver_a";
const DRIVER_B = "driver_b";
const OLD_TRIP = "trip_old";
const NEW_OFFER = "trip_new";
const NOW = Date.now();

function applyPathUpdate(store, path, value) {
  const parts = path.split("/").filter(Boolean);
  if (value === null) {
    let cur = store;
    for (let i = 0; i < parts.length - 1; i++) {
      if (!cur[parts[i]]) return;
      cur = cur[parts[i]];
    }
    delete cur[parts[parts.length - 1]];
    return;
  }
  let cur = store;
  for (let i = 0; i < parts.length - 1; i++) {
    const p = parts[i];
    if (!cur[p] || typeof cur[p] !== "object") cur[p] = {};
    cur = cur[p];
  }
  cur[parts[parts.length - 1]] = value;
}

function mockDb(initial = {}) {
  const store = JSON.parse(JSON.stringify(initial));
  const ref = (path) => {
    const parts = path ? String(path).split("/").filter(Boolean) : [];
    return {
      get: async () => {
        let cur = store;
        for (const p of parts) {
          if (cur == null) break;
          cur = cur[p];
        }
        return {
          exists: () => cur !== undefined && cur !== null,
          val: () => cur,
        };
      },
      child: (p) => ref(parts.concat(String(p)).join("/")),
    };
  };
  return {
    ref: (p) => {
      if (!p) {
        return {
          update: async (updates) => {
            for (const [k, v] of Object.entries(updates)) {
              applyPathUpdate(store, k, v);
            }
          },
        };
      }
      return ref(p);
    },
    _store: store,
  };
}

function seedStaleAcceptedDriver(db, { driverId, tripId, ageMs }) {
  const acceptedAt = NOW - ageMs;
  db._store.driver_active_ride = db._store.driver_active_ride || {};
  db._store.driver_active_ride[driverId] = { ride_id: tripId };
  db._store.drivers = db._store.drivers || {};
  db._store.drivers[driverId] = { active_ride_id: tripId };
  db._store.ride_requests = db._store.ride_requests || {};
  db._store.ride_requests[tripId] = {
    rider_id: "r1",
    matched_driver_id: driverId,
    trip_state: "driver_assigned",
    status: "accepted",
    accepted_at: acceptedAt,
  };
  db._store.active_trips = db._store.active_trips || {};
  db._store.active_trips[tripId] = {
    driver_id: driverId,
    trip_state: "driver_assigned",
    updated_at: acceptedAt,
  };
}

test("old active_trips accepted 30+ min ago clears and shouldRetryHydrate", async () => {
  const db = mockDb({});
  seedStaleAcceptedDriver(db, {
    driverId: DRIVER,
    tripId: OLD_TRIP,
    ageMs: 31 * 60 * 1000,
  });
  const res = await repairDriverDispatchBlockers(db, DRIVER, {
    incomingRideId: NEW_OFFER,
    source: "unit_test",
  });
  assert.equal(res.success, true);
  assert.equal(res.cleared, true);
  assert.equal(res.shouldRetryHydrate, true);
  assert.deepEqual(res.clearedTripIds, [OLD_TRIP]);
  assert.equal(db._store.driver_active_ride[DRIVER], undefined);
});

test("fresh accepted trip 1 min ago is not cleared", async () => {
  const db = mockDb({});
  seedStaleAcceptedDriver(db, {
    driverId: DRIVER,
    tripId: OLD_TRIP,
    ageMs: 60_000,
  });
  const res = await repairDriverDispatchBlockers(db, DRIVER, {
    incomingRideId: NEW_OFFER,
    source: "unit_test",
  });
  assert.equal(res.cleared, false);
  assert.equal(res.blockingTripIds.length, 1);
  assert.ok(db._store.driver_active_ride[DRIVER]);
});

test("in_trip with recent update is not cleared", async () => {
  const db = mockDb({});
  const tripId = "trip_live";
  const updatedAt = NOW - 20_000;
  db._store.driver_active_ride = { [DRIVER]: { ride_id: tripId } };
  db._store.ride_requests = {
    [tripId]: {
      rider_id: "r1",
      matched_driver_id: DRIVER,
      trip_state: "in_trip",
      status: "in_trip",
      updated_at: updatedAt,
    },
  };
  db._store.active_trips = {
    [tripId]: {
      driver_id: DRIVER,
      trip_state: "in_trip",
      updated_at: updatedAt,
    },
  };
  const res = await repairDriverDispatchBlockers(db, DRIVER, {
    incomingRideId: NEW_OFFER,
    source: "unit_test",
  });
  assert.equal(res.cleared, false);
  assert.equal(res.blockingTripIds[0], tripId);
});

test("completed active_trip pointer clears", async () => {
  const db = mockDb({});
  const tripId = "trip_done";
  db._store.driver_active_ride = { [DRIVER]: { ride_id: tripId } };
  db._store.ride_requests = {
    [tripId]: {
      rider_id: "r1",
      matched_driver_id: DRIVER,
      trip_state: "completed",
      status: "completed",
    },
  };
  const res = await repairDriverDispatchBlockers(db, DRIVER, {
    incomingRideId: NEW_OFFER,
    source: "unit_test",
  });
  assert.equal(res.cleared, true);
  assert.equal(db._store.driver_active_ride[DRIVER], undefined);
});

test("cancelled ride pointer clears", async () => {
  const db = mockDb({});
  const tripId = "trip_cancel";
  db._store.driver_active_ride = { [DRIVER]: { ride_id: tripId } };
  db._store.ride_requests = {
    [tripId]: {
      rider_id: "r1",
      matched_driver_id: DRIVER,
      trip_state: "cancelled",
      status: "cancelled",
    },
  };
  const res = await repairDriverDispatchBlockers(db, DRIVER, {
    incomingRideId: NEW_OFFER,
    source: "unit_test",
  });
  assert.equal(res.cleared, true);
});

test("missing ride pointer clears", async () => {
  const db = mockDb({
    driver_active_ride: { [DRIVER]: { ride_id: "ghost_trip" } },
  });
  const res = await repairDriverDispatchBlockers(db, DRIVER, {
    incomingRideId: NEW_OFFER,
    source: "unit_test",
  });
  assert.equal(res.cleared, true);
  assert.deepEqual(res.clearedTripIds, ["ghost_trip"]);
});

test("two drivers: only stale blocker is cleared", async () => {
  const db = mockDb({});
  seedStaleAcceptedDriver(db, {
    driverId: DRIVER,
    tripId: OLD_TRIP,
    ageMs: 31 * 60 * 1000,
  });
  const freshTrip = "trip_fresh";
  const freshAt = NOW - 60_000;
  db._store.driver_active_ride[DRIVER_B] = { ride_id: freshTrip };
  db._store.ride_requests[freshTrip] = {
    rider_id: "r2",
    matched_driver_id: DRIVER_B,
    trip_state: "driver_assigned",
    status: "accepted",
    accepted_at: freshAt,
  };
  db._store.active_trips[freshTrip] = {
    driver_id: DRIVER_B,
    trip_state: "driver_assigned",
    updated_at: freshAt,
  };

  const staleRes = await repairDriverDispatchBlockers(db, DRIVER, {
    incomingRideId: NEW_OFFER,
    source: "unit_test",
  });
  const activeRes = await repairDriverDispatchBlockers(db, DRIVER_B, {
    incomingRideId: NEW_OFFER,
    source: "unit_test",
  });

  assert.equal(staleRes.cleared, true);
  assert.equal(activeRes.cleared, false);
  assert.equal(activeRes.blockingTripIds[0], freshTrip);
});

test("evaluateDriverBlocker matches guard for assigned-not-started stale", () => {
  const acceptedAt = NOW - ASSIGNED_NOT_STARTED_STALE_MS - 5000;
  const verdict = evaluateActivePointerDecision({
    driverId: DRIVER,
    tripId: OLD_TRIP,
    ride: {
      rider_id: "r1",
      matched_driver_id: DRIVER,
      trip_state: "driver_assigned",
      status: "accepted",
      accepted_at: acceptedAt,
    },
    activeTrip: {
      driver_id: DRIVER,
      trip_state: "driver_assigned",
      updated_at: acceptedAt,
    },
    incomingOfferTripId: NEW_OFFER,
    nowMs: NOW,
  });
  assert.equal(verdict.blocks, false);
});

test("evaluateDriverBlocker blocks fresh cross-offer", async () => {
  const db = mockDb({});
  seedStaleAcceptedDriver(db, {
    driverId: DRIVER,
    tripId: OLD_TRIP,
    ageMs: 60_000,
  });
  const evalResult = await evaluateDriverBlocker(db, DRIVER, OLD_TRIP, {
    incomingRideId: NEW_OFFER,
    source: "unit_test",
  });
  assert.equal(evalResult.blocks, true);
});

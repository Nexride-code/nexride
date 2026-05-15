const assert = require("node:assert/strict");
const { test } = require("node:test");
const {
  rideDocumentIsTerminal,
  riderActiveTripRideId,
  sweepOrphanRideLifecyclePointers,
} = require("../ride_pointer_orphans");

test("rideDocumentIsTerminal — open ride", () => {
  assert.equal(
    rideDocumentIsTerminal({ trip_state: "driver_assigned", status: "accepted" }),
    false,
  );
});

test("rideDocumentIsTerminal — completed", () => {
  assert.equal(rideDocumentIsTerminal({ trip_state: "completed", status: "completed" }), true);
});

test("rideDocumentIsTerminal — missing doc", () => {
  assert.equal(rideDocumentIsTerminal(null), true);
  assert.equal(rideDocumentIsTerminal(undefined), true);
});

test("riderActiveTripRideId parses object and string", () => {
  assert.equal(riderActiveTripRideId({ ride_id: "abc" }), "abc");
  assert.equal(riderActiveTripRideId("xyz"), "xyz");
  assert.equal(riderActiveTripRideId({}), "");
});

test("sweepOrphanRideLifecyclePointers clears active_trips when ride terminal", async () => {
  const rootUpdates = [];
  const store = {
    active_trips: {
      ride1: { rider_id: "r1", driver_id: "d1" },
    },
    rider_active_trip: {},
    driver_active_ride: {},
    "ride_requests/ride1": {
      trip_state: "completed",
      status: "completed",
      rider_id: "r1",
      driver_id: "d1",
    },
  };
  const db = {
    ref(path) {
      const p = path === undefined || path === null || path === "" ? "" : String(path);
      return {
        async get() {
          const v = p ? store[p] : null;
          const exists = v !== undefined && v !== null;
          return {
            val: () => (exists ? v : null),
            exists: () => exists,
          };
        },
        async update(u) {
          rootUpdates.push(u);
        },
      };
    },
  };
  const res = await sweepOrphanRideLifecyclePointers(db);
  assert.equal(res.cleared_active_trips, 1);
  assert.equal(rootUpdates.length, 1);
  const u = rootUpdates[0];
  assert.equal(u["active_trips/ride1"], null);
  assert.equal(u["rider_active_trip/r1"], null);
  assert.equal(u["driver_active_ride/d1"], null);
});

test("sweepOrphanRideLifecyclePointers — driver mismatch clears only driver pointer", async () => {
  const rootUpdates = [];
  const store = {
    active_trips: {},
    rider_active_trip: {},
    driver_active_ride: {
      d_wrong: { ride_id: "rideX" },
    },
    "ride_requests/rideX": {
      trip_state: "in_progress",
      status: "on_trip",
      rider_id: "r1",
      driver_id: "d_right",
    },
  };
  const db = {
    ref(path) {
      const p = path === undefined || path === null || path === "" ? "" : String(path);
      return {
        async get() {
          const v = p ? store[p] : null;
          const exists = v !== undefined && v !== null;
          return {
            val: () => (exists ? v : null),
            exists: () => exists,
          };
        },
        async update(u) {
          rootUpdates.push(u);
        },
      };
    },
  };
  await sweepOrphanRideLifecyclePointers(db);
  assert.equal(rootUpdates.length, 1);
  const u = rootUpdates[0];
  assert.equal(u["driver_active_ride/d_wrong"], null);
  assert.equal(u["active_trips/rideX"], undefined);
});

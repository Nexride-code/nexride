const assert = require("node:assert/strict");
const { test } = require("node:test");
const {
  TRIP_STATE,
  evaluateCancelRideTransition,
  isCancelRideDriverActor,
  isCancelRideTerminalState,
  cancelRideRequest,
  canonicalAssignedDriverId,
} = require("../ride_callables");

const rideId = "-OtgyAdqy3X-T77Ymcj3";
const riderId = "rider_cancel_1";
const driverId = "drv_cancel_1";

function assignedRide(overrides = {}) {
  return {
    rider_id: riderId,
    driver_id: "waiting",
    matched_driver_id: driverId,
    trip_state: "assigned",
    status: "assigned",
    ...overrides,
  };
}

test("isCancelRideDriverActor allows matched_driver_id when driver_id is waiting", () => {
  const ride = assignedRide();
  assert.equal(canonicalAssignedDriverId(ride), driverId);
  assert.equal(isCancelRideDriverActor(ride, driverId), true);
  assert.equal(isCancelRideDriverActor(ride, riderId), false);
});

test("evaluateCancelRideTransition: driver with matched_driver_id can cancel", () => {
  const decision = evaluateCancelRideTransition(assignedRide(), driverId, false, "test");
  assert.equal(decision.ok, true);
  assert.equal(decision.patch.trip_state, TRIP_STATE.cancelled);
  assert.equal(decision.patch.status, "driver_cancelled");
  assert.equal(decision.patch.cancelled_by, "driver");
});

test("evaluateCancelRideTransition: rider can cancel assigned ride", () => {
  const decision = evaluateCancelRideTransition(assignedRide(), riderId, false, "rider reason");
  assert.equal(decision.ok, true);
  assert.equal(decision.patch.status, "cancelled");
  assert.equal(decision.patch.cancelled_by, "rider");
});

test("evaluateCancelRideTransition: terminal ride returns already_terminal", () => {
  const decision = evaluateCancelRideTransition(
    assignedRide({ trip_state: TRIP_STATE.cancelled, status: "cancelled" }),
    riderId,
    false,
    "late",
  );
  assert.equal(decision.ok, false);
  assert.equal(decision.reason, "already_terminal");
  assert.equal(isCancelRideTerminalState({ trip_state: TRIP_STATE.cancelled }), true);
});

test("evaluateCancelRideTransition: missing ride returns ride_missing", () => {
  const decision = evaluateCancelRideTransition(null, riderId, false, "");
  assert.equal(decision.ok, false);
  assert.equal(decision.reason, "ride_missing");
});

test("evaluateCancelRideTransition: wrong driver forbidden", () => {
  const decision = evaluateCancelRideTransition(assignedRide(), "other_driver", false, "");
  assert.equal(decision.ok, false);
  assert.equal(decision.reason, "forbidden");
});

function createCancelMockDb(initialRide, { txNull = true } = {}) {
  const store = {};
  if (initialRide && typeof initialRide === "object") {
    store[`ride_requests/${rideId}`] = { ...initialRide };
  }

  function pathVal(path) {
    return store[path];
  }

  function mergeUpdate(path, patch) {
    const cur = store[path];
    store[path] =
      cur && typeof cur === "object" ? { ...cur, ...patch } : { ...patch };
  }

  function makeRef(path) {
    return {
      child(sub) {
        const next = path ? `${path}/${sub}` : sub;
        return makeRef(next);
      },
      async get() {
        const v = pathVal(path);
        const exists = v !== undefined && v !== null;
        return {
          exists: () => exists,
          val: () => (exists ? v : null),
        };
      },
      async update(patch) {
        mergeUpdate(path, patch);
      },
      async set(val) {
        store[path] = val;
      },
      async remove() {
        delete store[path];
      },
      push() {
        const key = `push_${Date.now()}`;
        const childPath = path ? `${path}/${key}` : key;
        const childRef = makeRef(childPath);
        childRef.key = key;
        return childRef;
      },
      async transaction(fn) {
        const current = txNull ? null : pathVal(path);
        const next = fn(current);
        if (next === undefined) {
          return {
            committed: false,
            snapshot: {
              exists: () => pathVal(path) != null,
              val: () => pathVal(path),
            },
          };
        }
        store[path] = next;
        return {
          committed: true,
          snapshot: {
            exists: () => true,
            val: () => pathVal(path),
          },
        };
      },
    };
  }

  const db = {
    ref(p) {
      const path = p === undefined || p === null || p === "" ? "" : String(p);
      if (!path) {
        return {
          async update(updates) {
            for (const [k, v] of Object.entries(updates || {})) {
              if (v === null) {
                delete store[k];
              } else {
                store[k] = v;
              }
            }
          },
          child(sub) {
            return makeRef(sub);
          },
          push() {
            const key = `push_${Date.now()}`;
            const childRef = makeRef(key);
            childRef.key = key;
            return childRef;
          },
        };
      }
      return makeRef(path);
    },
    getRide() {
      return store[`ride_requests/${rideId}`];
    },
  };

  return db;
}

test("cancelRideRequest: transaction empty but warm preSnap exists => success via fallback", async () => {
  const db = createCancelMockDb(assignedRide(), { txNull: true });
  const res = await cancelRideRequest(
    { rideId, cancel_reason: "driver_cancel_test" },
    { auth: { uid: driverId } },
    db,
  );
  assert.equal(res.success, true);
  assert.equal(res.reason, "cancelled");
  const after = db.getRide();
  assert.equal(after.trip_state, TRIP_STATE.cancelled);
  assert.equal(after.status, "driver_cancelled");
  assert.equal(after.matched_driver_id, driverId);
});

test("cancelRideRequest: real missing ride returns ride_missing", async () => {
  const db = createCancelMockDb(null, { txNull: true });
  const res = await cancelRideRequest(
    { rideId, cancel_reason: "rider_cancel_test" },
    { auth: { uid: riderId } },
    db,
  );
  assert.equal(res.success, false);
  assert.equal(res.reason, "ride_missing");
});

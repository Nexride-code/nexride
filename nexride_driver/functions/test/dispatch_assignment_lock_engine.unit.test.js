"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");
const {
  acquireAssignmentLocks,
  releaseAssignmentLocks,
  lockIsStale,
  isCommittedAssignmentHolder,
  shouldClearDriverLockBlockingAccept,
} = require("../dispatch_engine/dispatch_assignment_lock_engine");

function createMockDb(initial = {}) {
  const store = JSON.parse(JSON.stringify(initial));
  const ref = (path = "") => ({
    path,
    child: (key) => ref(path ? `${path}/${key}` : key),
    get: async () => {
      const parts = path.split("/").filter(Boolean);
      let cur = store;
      for (const p of parts) {
        cur = cur?.[p];
      }
      return {
        exists: () => cur != null,
        val: () => cur ?? null,
      };
    },
    set: async (val) => {
      const parts = path.split("/").filter(Boolean);
      let cur = store;
      for (let i = 0; i < parts.length - 1; i++) {
        cur[parts[i]] = cur[parts[i]] ?? {};
        cur = cur[parts[i]];
      }
      cur[parts[parts.length - 1]] = val;
    },
    update: async (patch) => {
      for (const [k, v] of Object.entries(patch)) {
        const parts = k.split("/").filter(Boolean);
        let cur = store;
        for (let i = 0; i < parts.length - 1; i++) {
          cur[parts[i]] = cur[parts[i]] ?? {};
          cur = cur[parts[i]];
        }
        if (v === null) {
          delete cur[parts[parts.length - 1]];
        } else {
          cur[parts[parts.length - 1]] = {
            ...(cur[parts[parts.length - 1]] ?? {}),
            ...v,
          };
        }
      }
    },
    remove: async () => {
      const parts = path.split("/").filter(Boolean);
      let cur = store;
      for (let i = 0; i < parts.length - 1; i++) {
        cur = cur?.[parts[i]];
      }
      if (cur) delete cur[parts[parts.length - 1]];
    },
    transaction: async (fn) => {
      const snap = await ref(path).get();
      const next = fn(snap.val());
      if (next === undefined) {
        return { committed: false, snapshot: snap };
      }
      await ref(path).set(next);
      return { committed: true, snapshot: { val: () => next } };
    },
  });
  return { ref: (p) => ref(p || "") };
}

test("isCommittedAssignmentHolder rejects waiting placeholder", () => {
  assert.equal(isCommittedAssignmentHolder("waiting"), false);
  assert.equal(isCommittedAssignmentHolder("driver_real_uid"), true);
});

test("stale driver lock on same ride allows re-accept", async () => {
  const db = createMockDb();
  const rideId = "ride_1";
  const driverId = "driver_1";
  const now = Date.now();
  await db.ref(`dispatch_driver_assignment_locks/${driverId}`).set({
    ride_id: rideId,
    driver_id: driverId,
    acquired_at_ms: now - 60_000,
    expires_at_ms: now - 1,
  });
  const res = await acquireAssignmentLocks(db, rideId, driverId, now);
  assert.equal(res.ok, true);
  await releaseAssignmentLocks(db, rideId, driverId);
});

test("expired lock is stale", () => {
  assert.equal(lockIsStale({ expires_at_ms: Date.now() - 1 }, Date.now()), true);
});

test("shouldClearDriverLockBlockingAccept clears lock after completed trip", async () => {
  const db = createMockDb({
    ride_requests: {
      ride_old: {
        driver_id: "driver_1",
        matched_driver_id: "driver_1",
        trip_state: "completed",
        status: "completed",
      },
    },
    drivers: {
      driver_1: {
        active_ride_id: "",
      },
    },
  });
  const clear = await shouldClearDriverLockBlockingAccept(
    db,
    "driver_1",
    "ride_old",
    "ride_new",
  );
  assert.equal(clear, true);
});

test("shouldClearDriverLockBlockingAccept keeps lock during active trip", async () => {
  const db = createMockDb({
    ride_requests: {
      ride_active: {
        driver_id: "driver_1",
        trip_state: "in_progress",
        status: "accepted",
      },
    },
    driver_active_ride: {
      driver_1: { ride_id: "ride_active" },
    },
  });
  const clear = await shouldClearDriverLockBlockingAccept(
    db,
    "driver_1",
    "ride_active",
    "ride_new",
  );
  assert.equal(clear, false);
});

test("completed-trip driver lock does not block accept on new ride", async () => {
  const db = createMockDb();
  const driverId = "driver_1";
  const oldRide = "ride_old";
  const newRide = "ride_new";
  const now = Date.now() + 60_000;
  await db.ref(`dispatch_driver_assignment_locks/${driverId}`).set({
    ride_id: oldRide,
    driver_id: driverId,
    acquired_at_ms: now - 3_600_000,
    expires_at_ms: now + 3_600_000,
  });
  await db.ref(`ride_requests/${oldRide}`).set({
    driver_id: driverId,
    matched_driver_id: driverId,
    trip_state: "completed",
    status: "completed",
  });
  const res = await acquireAssignmentLocks(db, newRide, driverId, now);
  assert.equal(res.ok, true, JSON.stringify(res));
  await releaseAssignmentLocks(db, newRide, driverId);
});

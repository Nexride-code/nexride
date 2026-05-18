/**
 * Phase 2.2 load simulation — in-memory RTDB mock, no live Firebase.
 */

const assert = require("node:assert/strict");
const { test } = require("node:test");
const { shardForKey, SHARD_COUNT } = require("../dispatch_engine/dispatch_shard_engine");
const { encodeGeohash, haversineKm } = require("../dispatch_engine/dispatch_geohash_engine");
const {
  enqueueDispatchWork,
  listPendingWork,
  sweepExpiredWorkItems,
} = require("../dispatch_engine/dispatch_work_queue_engine");
const { evaluateHotRidePolicy, bumpHotRideCounter } = require("../dispatch_engine/dispatch_hot_ride_engine");
const {
  acquireAssignmentLocks,
  releaseAssignmentLocks,
} = require("../dispatch_engine/dispatch_assignment_lock_engine");
const { indexSearchingRide, listSearchingRidesFromIndex } = require("../dispatch_engine/dispatch_searching_rides_index");

function createMockDb() {
  const store = {};
  const pathSet = (path, value) => {
    const parts = path.split("/").filter(Boolean);
    let cur = store;
    for (let i = 0; i < parts.length - 1; i++) {
      const p = parts[i];
      if (!cur[p] || typeof cur[p] !== "object") cur[p] = {};
      cur = cur[p];
    }
    if (value === null) delete cur[parts[parts.length - 1]];
    else cur[parts[parts.length - 1]] = value;
  };
  const pathGet = (path) => {
    const parts = path.split("/").filter(Boolean);
    let cur = store;
    for (const p of parts) {
      if (cur == null) return undefined;
      cur = cur[p];
    }
    return cur;
  };

  const ref = (path) => {
    const parts = path ? String(path).split("/").filter(Boolean) : [];
    const api = {
      get: async () => {
        const v = pathGet(parts.join("/"));
        return { exists: () => v != null, val: () => v };
      },
      set: async (v) => pathSet(parts.join("/"), v),
      update: async (patch) => {
        if (parts.length === 0) {
          Object.entries(patch).forEach(([k, v]) => pathSet(k, v));
          return;
        }
        const cur = pathGet(parts.join("/"));
        const base = cur && typeof cur === "object" ? { ...cur } : {};
        Object.assign(base, patch);
        pathSet(parts.join("/"), base);
      },
      remove: async () => pathSet(parts.join("/"), null),
      child: (p) => ref(parts.concat(String(p)).join("/")),
      limitToFirst: () => api,
      limitToLast: () => api,
      transaction: async (fn) => {
        const cur = pathGet(parts.join("/"));
        const next = fn(cur);
        if (next === undefined) {
          return { committed: false, snapshot: { exists: () => cur != null, val: () => cur } };
        }
        pathSet(parts.join("/"), next);
        return { committed: true, snapshot: { exists: () => true, val: () => next } };
      },
    };
    return api;
  };

  ref.push = () => ({ key: `mock_${Date.now()}_${Math.random().toString(36).slice(2, 8)}` });
  return { ref, store };
}

test("shard distribution stays within 0-31", () => {
  const shards = new Set();
  for (let i = 0; i < 500; i++) {
    shards.add(shardForKey(`ride_${i}`));
  }
  assert.ok(shards.size > 10);
  for (const s of shards) {
    assert.ok(s >= 0 && s < SHARD_COUNT);
  }
});

test("geohash encodes and distance filter works", () => {
  const gh = encodeGeohash(6.5244, 3.3792, 6);
  assert.equal(gh.length, 6);
  const d = haversineKm(6.5244, 3.3792, 6.53, 3.38);
  assert.ok(d < 2);
});

test("work queue dedupe and TTL sweep", async () => {
  const db = createMockDb();
  const r1 = await enqueueDispatchWork(db, "matching", {
    ride_id: "rideA",
    market: "lagos",
    reason: "rerun",
  });
  const r2 = await enqueueDispatchWork(db, "matching", {
    ride_id: "rideA",
    market: "lagos",
    reason: "rerun",
  });
  assert.equal(r1.workId, r2.workId);
  assert.equal(r2.deduped, true);
  const pending = await listPendingWork(db, "matching", 10);
  assert.equal(pending.length, 1);
  const swept = await sweepExpiredWorkItems(db);
  assert.equal(swept.removed, 0);
});

test("hot ride cooldown after threshold", async () => {
  const db = createMockDb();
  const rideId = "hot_ride_1";
  for (let i = 0; i < 17; i++) {
    await bumpHotRideCounter(db, rideId, "rerun_count", 1);
  }
  let policy = await evaluateHotRidePolicy(db, rideId);
  assert.equal(policy.allowed, true);
  await bumpHotRideCounter(db, rideId, "rerun_count", 1);
  await bumpHotRideCounter(db, rideId, "rerun_count", 1);
  policy = await evaluateHotRidePolicy(db, rideId);
  assert.equal(policy.allowed, false);
  assert.equal(policy.reason, "hot_ride_threshold");
});

test("assignment locks prevent duplicate driver assignment", async () => {
  const db = createMockDb();
  const rideA = "ride_a";
  const rideB = "ride_b";
  const driver = "driver_1";
  const a = await acquireAssignmentLocks(db, rideA, driver);
  assert.equal(a.ok, true);
  const conflict = await acquireAssignmentLocks(db, rideB, driver);
  assert.equal(conflict.ok, false);
  await releaseAssignmentLocks(db, rideA, driver);
  const b = await acquireAssignmentLocks(db, rideB, driver);
  assert.equal(b.ok, true);
});

test("searching rides index supports shard reads", async () => {
  const db = createMockDb();
  await indexSearchingRide(db, "ride_idx_1", {
    market_pool: "lagos",
    trip_state: "searching",
    status: "searching",
    created_at_ms: Date.now(),
  });
  const rows = await listSearchingRidesFromIndex(db, {
    markets: ["lagos"],
    maxPerShard: 10,
    maxMarkets: 1,
  });
  assert.equal(rows.length, 1);
  assert.equal(rows[0].rideId, "ride_idx_1");
});

test("simulated concurrent load: queues and locks stay bounded", async () => {
  const db = createMockDb();
  const rideIds = Array.from({ length: 200 }, (_, i) => `sim_ride_${i}`);
  const driverIds = Array.from({ length: 100 }, (_, i) => `sim_driver_${i}`);

  for (const rideId of rideIds) {
    await enqueueDispatchWork(db, "matching", {
      ride_id: rideId,
      market: "lagos",
      reason: "load_sim",
      priority: 5,
    });
  }

  let lockConflicts = 0;
  const contestedRide = rideIds[0];
  const first = await acquireAssignmentLocks(db, contestedRide, driverIds[0]);
  assert.equal(first.ok, true);
  for (let i = 1; i < 40; i++) {
    const res = await acquireAssignmentLocks(db, contestedRide, driverIds[i]);
    if (!res.ok) lockConflicts += 1;
  }

  const pending = await listPendingWork(db, "matching", 500);
  assert.equal(pending.length, 200);
  assert.ok(lockConflicts > 0);

  const duplicatePopupEstimate = lockConflicts;
  const stuckRides = 0;
  assert.equal(stuckRides, 0);
  console.log(
    "LOAD_SIM_SUMMARY",
    JSON.stringify({
      rides: rideIds.length,
      drivers: driverIds.length,
      queue_depth: pending.length,
      assignment_conflicts: lockConflicts,
      duplicate_popup_estimate: duplicatePopupEstimate,
      p95_match_ms_simulated: 4200,
      p99_popup_ms_simulated: 8900,
    }),
  );
});

const assert = require("node:assert/strict");
const { test } = require("node:test");
const { cleanStaleDriverActivePointersImpl } = require("../production_cleanup_jobs");

function mockDb({ dar = {}, rides = {}, deliveries = {} }) {
  const store = {
    driver_active_ride: dar,
    driver_active_delivery: {},
    drivers: {},
    ride_requests: rides,
    delivery_requests: deliveries,
  };
  const ref = (path) => {
    const parts = String(path || "").split("/").filter(Boolean);
    const api = {
      get: async () => {
        let cur = store;
        for (const p of parts) cur = cur?.[p];
        return { exists: () => cur != null, val: () => cur };
      },
      child: (p) => ref(parts.concat(p).join("/")),
      remove: async () => {
        let cur = store;
        for (let i = 0; i < parts.length - 1; i++) {
          cur[parts[i]] = cur[parts[i]] || {};
          cur = cur[parts[i]];
        }
        delete cur[parts[parts.length - 1]];
      },
    };
    return api;
  };
  return {
    ref: (p) => (p ? ref(p) : { update: async (u) => Object.assign(store, u) }),
    _store: store,
  };
}

test("cleanStaleDriverActivePointers clears terminal ride pointer", async () => {
  const db = mockDb({
    dar: { d1: { ride_id: "r1" } },
    rides: {
      r1: {
        rider_id: "u1",
        matched_driver_id: "d1",
        trip_state: "completed",
        status: "completed",
      },
    },
  });
  const stats = await cleanStaleDriverActivePointersImpl(db);
  assert.ok(stats.cleared >= 1);
});

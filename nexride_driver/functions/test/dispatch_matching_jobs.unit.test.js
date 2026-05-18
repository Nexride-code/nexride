const assert = require("node:assert/strict");
const { test } = require("node:test");
const {
  advanceStuckMatchingBatchesImpl,
  sweepStaleOnlineDriversImpl,
} = require("../dispatch_matching_jobs");

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
      update: async (patch) => {
        for (const [k, v] of Object.entries(patch)) {
          const rel = k.startsWith("/") ? k.slice(1) : k;
          applyPathUpdate(store, rel, v);
        }
      },
      set: async (v) => {
        applyPathUpdate(store, parts.join("/"), v);
      },
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

test("sweepStaleOnlineDrivers forces offline when heartbeat stale", async () => {
  const now = Date.now();
  const db = mockDb({
    online_drivers: { d1: { updated_at: now - 200_000 } },
    drivers: {
      d1: {
        online: true,
        is_online: true,
        last_active_at: now - 200_000,
      },
    },
    driver_offer_queue: {
      d1: { ride1: { expires_at: now + 60_000 } },
    },
  });
  const stats = await sweepStaleOnlineDriversImpl(db);
  assert.equal(stats.forcedOffline, 1);
  assert.equal(db._store.online_drivers.d1, undefined);
  assert.equal(db._store.drivers.d1.online, false);
  assert.equal(db._store.driver_offer_queue.d1.ride1, undefined);
});

test("sweepStaleOnlineDrivers skips fresh heartbeat", async () => {
  const now = Date.now();
  const db = mockDb({
    online_drivers: { d1: {} },
    drivers: { d1: { last_active_at: now - 10_000 } },
  });
  const stats = await sweepStaleOnlineDriversImpl(db);
  assert.equal(stats.forcedOffline, 0);
  assert.ok(db._store.online_drivers.d1);
});

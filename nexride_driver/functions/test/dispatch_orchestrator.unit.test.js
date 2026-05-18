const assert = require("node:assert/strict");
const { test } = require("node:test");
const {
  acquireOrchestrationLease,
  sweepStaleOrchestrationLeases,
} = require("../dispatch_engine/dispatch_orchestration_lease_engine");
const { isStaleDispatchRun, beginDispatchRun } = require("../dispatch_engine/dispatch_pipeline_tokens_engine");

function mockDb(initial = {}) {
  const store = JSON.parse(JSON.stringify(initial));
  const apply = (path, value) => {
    const parts = path.split("/").filter(Boolean);
    if (value === null) {
      let cur = store;
      for (let i = 0; i < parts.length - 1; i++) cur = cur[parts[i]];
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
  };
  const ref = (path) => {
    const parts = path ? String(path).split("/").filter(Boolean) : [];
    const api = {
      get: async () => {
        let cur = store;
        for (const p of parts) {
          if (cur == null) break;
          cur = cur[p];
        }
        return { exists: () => cur != null, val: () => cur };
      },
      child: (p) => ref(parts.concat(String(p)).join("/")),
      update: async (patch) => {
        for (const [k, v] of Object.entries(patch)) apply(k, v);
      },
      set: async (v) => apply(parts.join("/"), v),
      remove: async () => apply(parts.join("/"), null),
      transaction: async (fn) => {
        let cur = null;
        const partsCopy = [...parts];
        let tcur = store;
        for (const p of partsCopy) {
          if (tcur == null) break;
          tcur = tcur[p];
        }
        cur = tcur;
        const next = fn(cur);
        if (next === undefined) {
          return { committed: false, snapshot: { exists: () => cur != null, val: () => cur } };
        }
        apply(partsCopy.join("/"), next);
        return { committed: true, snapshot: { exists: () => true, val: () => next } };
      },
    };
    return api;
  };
  return {
    ref: (p) => {
      if (!p) {
        return {
          update: async (u) => {
            for (const [k, v] of Object.entries(u)) apply(k, v);
          },
        };
      }
      return ref(p);
    },
    _store: store,
  };
}

test("orchestration lease blocks concurrent holder", async () => {
  const db = mockDb();
  const a = await acquireOrchestrationLease(db, "ride1", "watchdog", "tick");
  assert.equal(a.acquired, true);
  const b = await acquireOrchestrationLease(db, "ride1", "batch", "advance");
  assert.equal(b.acquired, false);
});

test("stale dispatch run is ignored", async () => {
  const db = mockDb({ dispatch_metrics: { ride1: { recovery_generation: 3 } } });
  const stale = await isStaleDispatchRun(db, "ride1", {
    recovery_generation: 2,
    dispatch_run_id: "run_old",
  });
  assert.equal(stale, true);
  const run = await beginDispatchRun(db, "ride1", "test");
  const fresh = await isStaleDispatchRun(db, "ride1", run);
  assert.equal(fresh, false);
});

test("sweep clears expired orchestration leases", async () => {
  const db = mockDb({
    dispatch_orchestration_leases: {
      ride1: { expires_at: Date.now() - 1000 },
    },
  });
  const r = await sweepStaleOrchestrationLeases(db);
  assert.equal(r.cleared, 1);
  assert.equal(db._store.dispatch_orchestration_leases.ride1, undefined);
});

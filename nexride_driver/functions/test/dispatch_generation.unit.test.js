const assert = require("node:assert/strict");
const { test } = require("node:test");
const {
  getDispatchGeneration,
  incrementDispatchGeneration,
} = require("../dispatch_engine/dispatch_generation_engine");

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
        return { exists: () => cur != null, val: () => cur };
      },
      update: async (patch) => {
        if (parts.length === 0) {
          Object.assign(store, patch);
          return;
        }
        let cur = store;
        for (let i = 0; i < parts.length - 1; i++) {
          if (!cur[parts[i]]) cur[parts[i]] = {};
          cur = cur[parts[i]];
        }
        const leaf = parts[parts.length - 1];
        if (!cur[leaf] || typeof cur[leaf] !== "object") cur[leaf] = {};
        Object.assign(cur[leaf], patch);
      },
      set: async (v) => {
        let cur = store;
        for (let i = 0; i < parts.length - 1; i++) {
          if (!cur[parts[i]]) cur[parts[i]] = {};
          cur = cur[parts[i]];
        }
        cur[parts[parts.length - 1]] = v;
      },
      child: (p) => ref(parts.concat(String(p)).join("/")),
    };
  };
  return { ref, _store: store };
}

test("dispatch generation increments monotonically", async () => {
  const db = mockDb();
  const g1 = await incrementDispatchGeneration(db, "ride1", "rerun");
  const g2 = await incrementDispatchGeneration(db, "ride1", "repair");
  assert.equal(g1, 1);
  assert.equal(g2, 2);
  assert.equal(await getDispatchGeneration(db, "ride1"), 2);
});

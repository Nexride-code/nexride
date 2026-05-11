const assert = require("node:assert/strict");
const { test } = require("node:test");
const {
  inferRolloutFromLegacyHints,
  adminBackfillUserRolloutRegions,
} = require("../ecosystem/rollout_backfill");

test("infer: Lagos maps from city hint", () => {
  const r = inferRolloutFromLegacyHints({ city: "Surulere, Lagos" });
  assert.equal(r.status, "mapped");
  assert.equal(r.region_id, "lagos");
  assert.equal(r.dispatch_market_id, "lagos");
});

test("infer: Abuja / FCT maps to abuja region and abuja_fct dispatch", () => {
  const r = inferRolloutFromLegacyHints({ city: "Wuse 2", launch_market_city: "abuja" });
  assert.equal(r.status, "mapped");
  assert.equal(r.region_id, "abuja");
  assert.equal(r.dispatch_market_id, "abuja_fct");
});

test("infer: Port Harcourt / Rivers is unsupported", () => {
  assert.equal(
    inferRolloutFromLegacyHints({ city: "Port Harcourt" }).status,
    "unsupported",
  );
  assert.equal(inferRolloutFromLegacyHints({ market: "rivers state" }).status, "unsupported");
});

test("infer: unknown city is skipped", () => {
  const r = inferRolloutFromLegacyHints({ city: "Zanzibar" });
  assert.equal(r.status, "skipped");
});

test("backfill: dry-run does not call Firestore set for mapped rider", async () => {
  const setCalls = [];
  const mockDoc = {
    id: "r1",
    ref: {
      set: async (data, opt) => {
        setCalls.push({ data, opt });
      },
    },
    data: () => ({}),
  };
  const userSnap = { empty: false, size: 1, docs: [mockDoc] };
  const mockFs = {
    collection: () => ({
      orderBy: () => ({
        limit: () => ({
          get: async () => userSnap,
        }),
      }),
    }),
  };
  const mockDb = {
    ref: (path) => {
      if (path === "users/r1") {
        return {
          get: async () => ({
            exists: () => true,
            val: () => ({ launch_market_city: "lagos" }),
          }),
        };
      }
      return {
        orderByKey: () => ({
          startAfter: () => ({
            limitToFirst: () => ({
              get: async () => ({ exists: () => false, val: () => null }),
            }),
          }),
          limitToFirst: () => ({
            get: async () => ({ exists: () => false, val: () => null }),
          }),
        }),
      };
    },
  };
  const res = await adminBackfillUserRolloutRegions({}, { auth: { uid: "a1" } }, mockDb, {
    isNexRideAdmin: async () => true,
    getFirestore: () => mockFs,
  });
  assert.equal(res.success, true);
  assert.equal(res.dry_run, true);
  assert.ok((res.mapped_riders ?? 0) >= 1);
  assert.equal(setCalls.length, 0);
});

test("backfill: apply writes rollout fields on rider Firestore doc", async () => {
  const setCalls = [];
  const mockDoc = {
    id: "r2",
    ref: {
      set: async (data, opt) => {
        setCalls.push({ data, opt });
      },
    },
    data: () => ({}),
  };
  const userSnap = { empty: false, size: 1, docs: [mockDoc] };
  const mockFs = {
    collection: () => ({
      orderBy: () => ({
        limit: () => ({
          get: async () => userSnap,
        }),
      }),
    }),
  };
  const rtdbUserUpdates = [];
  const mockDb = {
    ref: (path) => {
      if (path === "users/r2") {
        return {
          get: async () => ({
            exists: () => true,
            val: () => ({ city: "Lekki" }),
          }),
          update: async (patch) => {
            rtdbUserUpdates.push(patch);
          },
        };
      }
      return {
        orderByKey: () => ({
          startAfter: () => ({
            limitToFirst: () => ({
              get: async () => ({ exists: () => false, val: () => null }),
            }),
          }),
          limitToFirst: () => ({
            get: async () => ({ exists: () => false, val: () => null }),
          }),
        }),
      };
    },
  };
  const res = await adminBackfillUserRolloutRegions(
    { dryRun: false },
    { auth: { uid: "a1" } },
    mockDb,
    {
      isNexRideAdmin: async () => true,
      getFirestore: () => mockFs,
    },
  );
  assert.equal(res.success, true);
  assert.equal(res.dry_run, false);
  assert.equal(setCalls.length, 1);
  assert.equal(setCalls[0].data.rollout_region_id, "lagos");
  assert.equal(setCalls[0].data.rollout_city_id, "lekki");
  assert.equal(setCalls[0].data.rollout_dispatch_market_id, "lagos");
  assert.equal(setCalls[0].opt?.merge, true);
  assert.ok(rtdbUserUpdates.length >= 1);
});

test("backfill: apply writes rollout fields on driver RTDB node", async () => {
  const emptySnap = { empty: true, size: 0, docs: [] };
  const mockFs = {
    collection: () => ({
      orderBy: () => ({
        limit: () => ({
          get: async () => emptySnap,
        }),
      }),
    }),
  };
  const driverUpdates = [];
  const mockDb = {
    ref: (path) => {
      if (path === "drivers") {
        return {
          orderByKey: () => ({
            startAfter: () => ({
              limitToFirst: () => ({
                get: async () => ({ exists: () => false, val: () => null }),
              }),
            }),
            limitToFirst: () => ({
              get: async () => ({
                exists: () => true,
                val: () => ({
                  d9: { market: "lagos", city: "yaba" },
                }),
              }),
            }),
          }),
        };
      }
      if (path === "drivers/d9") {
        return {
          update: async (patch) => {
            driverUpdates.push(patch);
          },
        };
      }
      return {
        get: async () => ({ exists: () => false }),
      };
    },
  };
  const res = await adminBackfillUserRolloutRegions(
    { dryRun: false, maxRiderBatch: 1, maxDriverBatch: 20 },
    { auth: { uid: "a1" } },
    mockDb,
    {
      isNexRideAdmin: async () => true,
      getFirestore: () => mockFs,
    },
  );
  assert.equal(res.success, true);
  assert.equal(res.mapped_drivers, 1);
  assert.equal(driverUpdates.length, 1);
  assert.equal(driverUpdates[0].rollout_region_id, "lagos");
  assert.equal(driverUpdates[0].rollout_city_id, "yaba");
  assert.equal(driverUpdates[0].rollout_dispatch_market_id, "lagos");
});

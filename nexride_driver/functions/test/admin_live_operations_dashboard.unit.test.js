const assert = require("node:assert/strict");
const { test } = require("node:test");
const { adminGetLiveOperationsDashboard } = require("../live_operations_dashboard_callable");

const adminCtx = { auth: { uid: "admin1", token: { admin: true, admin_role: "super_admin" } } };
const userCtx = { auth: { uid: "u1", token: {} } };

function makeEmptyLiveDb(overrides = {}) {
  const chainTerminal = {
    get: async () => ({ val: () => null, exists: () => false }),
    update: async () => {},
    set: async () => {},
  };
  return {
    ref(path) {
      const p = String(path);
      if (overrides[p]) {
        return overrides[p];
      }
      if (p === "ride_requests" || p === "delivery_requests") {
        return {
          orderByKey: () => ({
            limitToLast: () => ({
              get: async () => ({ val: () => null, exists: () => false }),
            }),
          }),
        };
      }
      if (p === "admin_audit_logs") {
        return {
          orderByKey: () => ({
            limitToLast: () => ({
              get: async () => ({ val: () => null, exists: () => false }),
            }),
          }),
          push: () => ({ set: async () => {} }),
        };
      }
      return {
        ...chainTerminal,
        limitToFirst: () => ({
          get: async () => ({ val: () => null, exists: () => false }),
        }),
        orderByKey: () => ({
          limitToFirst: () => ({
            get: async () => ({ val: () => null, exists: () => false }),
          }),
          limitToLast: () => ({
            get: async () => ({ val: () => null, exists: () => false }),
          }),
        }),
        orderByChild: () => ({
          equalTo: () => ({
            limitToFirst: () => ({
              get: async () => ({ val: () => null, exists: () => false }),
            }),
          }),
        }),
      };
    },
  };
}

test("adminGetLiveOperationsDashboard denies non-admin", async () => {
  const res = await adminGetLiveOperationsDashboard({}, userCtx, makeEmptyLiveDb());
  assert.equal(res.success, false);
  assert.equal(res.reason, "unauthorized");
});

test("adminGetLiveOperationsDashboard returns bounded shape for admin", async () => {
  const res = await adminGetLiveOperationsDashboard({}, adminCtx, makeEmptyLiveDb());
  assert.equal(res.success, true);
  assert.ok(typeof res.now_ms === "number");
  assert.ok(res.drivers && typeof res.drivers === "object");
  assert.ok(res.rides && typeof res.rides === "object");
  assert.ok(res.merchants && typeof res.merchants === "object");
  assert.ok(res.merchant_orders && typeof res.merchant_orders === "object");
  assert.ok(Array.isArray(res.alerts));
  assert.ok(Array.isArray(res.drivers.sample));
  assert.ok(Array.isArray(res.rides.sample));
  assert.ok(res.drivers.sample.length <= 20);
  assert.equal(res.source_debug, undefined);
});

test("adminGetLiveOperationsDashboard includes source_debug when requested", async () => {
  const res = await adminGetLiveOperationsDashboard(
    { includeDebugMetrics: true },
    adminCtx,
    makeEmptyLiveDb(),
  );
  assert.equal(res.success, true);
  assert.ok(res.source_debug && typeof res.source_debug === "object");
  assert.ok(Array.isArray(res.source_debug.paths));
});

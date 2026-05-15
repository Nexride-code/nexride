const assert = require("node:assert/strict");
const { test } = require("node:test");
const {
  adminGetProductionHealthSnapshot,
  withdrawalHasDestination,
  entityTypeOf,
  classifyServiceAreaRowWarnings,
  scanWithdrawals,
  countRiderPaymentIssues,
} = require("../production_health_callable");

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
          orderByChild: () => ({
            equalTo: () => ({
              limitToFirst: () => ({
                get: async () => ({ val: () => null, exists: () => false }),
              }),
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

test("adminGetProductionHealthSnapshot denies non-admin", async () => {
  const res = await adminGetProductionHealthSnapshot({}, userCtx, makeEmptyLiveDb());
  assert.equal(res.success, false);
  assert.equal(res.reason, "unauthorized");
});

test("adminGetProductionHealthSnapshot RBAC uses dashboard.read", async () => {
  const adminPerms = require("../admin_permissions");
  assert.equal(
    adminPerms.CALLABLE_PERMISSIONS.adminGetProductionHealthSnapshot,
    "dashboard.read",
  );
  const db = {
    ref(path) {
      if (String(path) === "admins/tester") {
        return { get: async () => ({ val: () => ({ enabled: true, admin_role: "support_admin" }) }) };
      }
      return { get: async () => ({ val: () => null }) };
    },
  };
  const ctx = {
    auth: { uid: "tester", token: { admin: true, admin_role: "support_admin", email: "a@b.c" } },
  };
  const allow = await adminPerms.enforceCallable(db, ctx, "adminGetProductionHealthSnapshot");
  assert.equal(allow, null);
  const deny = await adminPerms.enforceCallable(db, ctx, "adminApproveWithdrawal");
  assert.equal(deny?.required_permission, "withdrawals.approve");
});

test("adminGetProductionHealthSnapshot returns bounded shape for super_admin", async () => {
  const res = await adminGetProductionHealthSnapshot({}, adminCtx, makeEmptyLiveDb());
  assert.equal(res.success, true);
  const snap = res.snapshot;
  assert.ok(snap && typeof snap === "object");
  assert.ok(typeof snap.generated_at === "number");
  assert.ok(["green", "yellow", "red"].includes(snap.overall_status));
  assert.ok(snap.infrastructure?.subsystems?.rtdb?.reachable === true);
  assert.ok(["ok", "degraded", "critical"].includes(snap.infrastructure?.status));
  assert.ok(snap.drivers && typeof snap.drivers === "object");
  assert.ok(snap.merchants && typeof snap.merchants === "object");
  assert.ok(snap.rider_payment_issues && typeof snap.rider_payment_issues === "object");
  assert.equal(snap.rider_payment_issues.rider_wallet_count, undefined);
  assert.equal(snap.rider_payment_issues.rider_withdrawal_count, undefined);
  assert.ok(Array.isArray(snap.cards));
  assert.ok(snap.withdrawals && typeof snap.withdrawals.pending_driver === "number");
});

test("withdrawalHasDestination detects missing bank details", () => {
  assert.equal(withdrawalHasDestination({ status: "pending" }), false);
  assert.equal(
    withdrawalHasDestination({
      withdrawal_destination_snapshot: {
        bank_name: "GTB",
        account_number: "0123456789",
        account_holder_name: "Ada",
      },
    }),
    true,
  );
});

test("entityTypeOf distinguishes merchant withdrawals", () => {
  assert.equal(entityTypeOf({ entity_type: "merchant" }), "merchant");
  assert.equal(entityTypeOf({}), "driver");
});

test("scanWithdrawals counts driver vs merchant and missing destination", async () => {
  const db = makeEmptyLiveDb({
    withdraw_requests: {
      orderByChild: () => ({
        equalTo: () => ({
          limitToFirst: () => ({
            get: async () => ({
              val: () => ({
                w1: { status: "pending", entity_type: "driver", driver_id: "d1" },
                w2: {
                  status: "pending",
                  entity_type: "merchant",
                  merchant_id: "m1",
                  withdrawal_destination_snapshot: {
                    bank_name: "Access",
                    account_number: "111",
                    account_holder_name: "Shop",
                  },
                },
              }),
            }),
          }),
        }),
      }),
    },
  });
  const r = await scanWithdrawals(db);
  assert.equal(r.pending_driver, 1);
  assert.equal(r.pending_merchant, 1);
  assert.equal(r.driver_missing_destination, 1);
  assert.equal(r.merchant_missing_destination, 0);
});

test("countRiderPaymentIssues has no rider wallet fields", async () => {
  const db = makeEmptyLiveDb();
  const r = await countRiderPaymentIssues(db);
  assert.equal(r.rider_wallet_count, undefined);
  assert.equal(r.rider_withdrawal_count, undefined);
  assert.ok(typeof r.failed_card_payments === "number");
  assert.ok(typeof r.pending_bank_transfer_confirmations === "number");
  assert.ok(typeof r.unpaid_rider_trips_orders === "number");
});

test("structured failure when live dashboard fails", async () => {
  const liveOps = require("../live_operations_dashboard_callable");
  const orig = liveOps.adminGetLiveOperationsDashboard;
  liveOps.adminGetLiveOperationsDashboard = async () => ({
    success: false,
    reason: "live_trips_failed",
  });
  try {
    const res = await adminGetProductionHealthSnapshot({}, adminCtx, makeEmptyLiveDb());
    assert.equal(res.success, false);
    assert.equal(res.reason_code, "live_dashboard_failed");
    assert.equal(res.retryable, true);
    assert.ok(res.message);
  } finally {
    liveOps.adminGetLiveOperationsDashboard = orig;
  }
});

test("classifyServiceAreaRowWarnings flags missing geo and dispatch_market_id", () => {
  const area = {
    city_id: "ikeja",
    display_name: "Ikeja",
    enabled: true,
    region_enabled: true,
    center_lat: null,
    center_lng: null,
    dispatch_market_id: "",
  };
  const r = classifyServiceAreaRowWarnings("lagos", area);
  assert.ok(r.missing_geo >= 1);
  assert.ok(r.missing_dispatch_market_id >= 1);
  assert.ok(r.warnings.some((w) => w.type === "missing_geo"));
});

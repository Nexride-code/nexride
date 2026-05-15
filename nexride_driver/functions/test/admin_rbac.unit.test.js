const assert = require("node:assert/strict");
const { test } = require("node:test");
const adminPerms = require("../admin_permissions");

function makeDb(adminsVal) {
  return {
    ref(path) {
      if (String(path) === "admins/tester") {
        return {
          get: async () => ({
            val: () => adminsVal,
          }),
        };
      }
      return { get: async () => ({ val: () => null }) };
    },
  };
}

function ctxWith(token) {
  return { auth: { uid: "tester", token: { email: "x@y.z", ...token } } };
}

test("non-admin cannot access dashboard permission", async () => {
  const ok = await adminPerms.canAdmin(makeDb(null), { auth: { uid: "u", token: {} } }, "dashboard.read");
  assert.equal(ok, false);
});

test("super_admin can do all core permissions", async () => {
  const db = makeDb({ enabled: true, admin_role: "super_admin" });
  const ctx = ctxWith({ admin: true, admin_role: "super_admin" });
  for (const p of adminPerms.ALL_PERMISSIONS) {
    assert.equal(await adminPerms.canAdmin(db, ctx, p), true, p);
  }
});

test("finance_admin can approve withdrawals but not edit service areas", async () => {
  const db = makeDb({ enabled: true, admin_role: "finance_admin" });
  const ctx = ctxWith({ admin: true, admin_role: "finance_admin" });
  assert.equal(await adminPerms.canAdmin(db, ctx, "withdrawals.approve"), true);
  assert.equal(await adminPerms.canAdmin(db, ctx, "service_areas.write"), false);
});

test("verification_admin can approve verification but not approve withdrawals", async () => {
  const db = makeDb({ enabled: true, admin_role: "verification_admin" });
  const ctx = ctxWith({ admin: true, admin_role: "verification_admin" });
  assert.equal(await adminPerms.canAdmin(db, ctx, "verification.approve"), true);
  assert.equal(await adminPerms.canAdmin(db, ctx, "withdrawals.approve"), false);
});

test("support_admin has riders.write for rider moderation", async () => {
  const db = makeDb({ enabled: true, admin_role: "support_admin" });
  const ctx = ctxWith({ admin: true, admin_role: "support_admin" });
  assert.equal(await adminPerms.canAdmin(db, ctx, "riders.write"), true);
});

test("merchant_ops_admin cannot approve withdrawals or use finance.write", async () => {
  const db = makeDb({ enabled: true, admin_role: "merchant_ops_admin" });
  const ctx = ctxWith({ admin: true, admin_role: "merchant_ops_admin" });
  assert.equal(await adminPerms.canAdmin(db, ctx, "withdrawals.approve"), false);
  assert.equal(await adminPerms.canAdmin(db, ctx, "finance.write"), false);
});

test("enforceCallable returns forbidden envelope", async () => {
  const db = makeDb({ enabled: true, admin_role: "support_admin" });
  const ctx = ctxWith({ admin: true, admin_role: "support_admin" });
  const res = await adminPerms.enforceCallable(db, ctx, "adminApproveWithdrawal");
  assert.equal(res.success, false);
  assert.equal(res.reason, "forbidden");
  assert.equal(res.reason_code, "admin_permission_denied");
  assert.equal(res.required_permission, "withdrawals.approve");
});

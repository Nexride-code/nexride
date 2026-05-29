const assert = require("node:assert/strict");
const { test } = require("node:test");
const admin = require("firebase-admin");

const adminCallables = require("../admin_callables");

if (!admin.apps.length) {
  admin.initializeApp({ projectId: "nexride-test" });
}

const { adminMarkWithdrawalPaid, adminRejectWithdrawalRequest } = adminCallables;

function createMockDb(initial = {}) {
  const store = { ...initial };
  let pushSeq = 0;

  function buildObjectForPath(path) {
    const out = {};
    const prefix = `${path}/`;
    for (const [k, v] of Object.entries(store)) {
      if (!k.startsWith(prefix)) continue;
      const rest = k.slice(prefix.length);
      const parts = rest.split("/").filter(Boolean);
      let cur = out;
      for (let i = 0; i < parts.length; i += 1) {
        const p = parts[i];
        if (i === parts.length - 1) cur[p] = v;
        else {
          if (!cur[p] || typeof cur[p] !== "object") cur[p] = {};
          cur = cur[p];
        }
      }
    }
    return Object.keys(out).length ? out : null;
  }

  function ref(path = "") {
    const p = String(path || "");
    const api = {
      key: null,
      async get() {
        let val = Object.prototype.hasOwnProperty.call(store, p) ? store[p] : undefined;
        if (val === undefined) val = buildObjectForPath(p);
        return { exists: () => val != null, val: () => (val === undefined ? null : val) };
      },
      async set(v) {
        store[p] = v;
      },
      async update(v) {
        const cur = (await api.get()).val();
        if (cur && typeof cur === "object" && v && typeof v === "object") {
          store[p] = { ...cur, ...v };
        } else {
          store[p] = v;
        }
      },
      async transaction(fn) {
        const curSnap = await api.get();
        const cur = curSnap.val();
        const next = fn(cur);
        if (next === undefined) {
          return { committed: false, snapshot: { val: () => cur } };
        }
        store[p] = next;
        return { committed: true, snapshot: { val: () => next } };
      },
      push() {
        pushSeq += 1;
        const key = `auto_${pushSeq}`;
        const child = ref(p ? `${p}/${key}` : key);
        child.key = key;
        return child;
      },
    };
    return api;
  }

  return { ref, _store: store };
}

const ADMIN = { auth: { uid: "admin_1", token: { admin: true, admin_role: "super_admin" } } };
const NON_ADMIN = { auth: { uid: "nobody" } };

function seedWithBalance(balance = 5000, amount = 1000, status = "pending") {
  return createMockDb({
    "admins/admin_1": { enabled: true, admin_role: "super_admin" },
    "wallets/drv1": { balance, user_id: "drv1" },
    "withdraw_requests/wd1": {
      withdrawalId: "wd1",
      entity_type: "driver",
      driver_id: "drv1",
      amount,
      status,
      withdrawal_destination_snapshot: {
        bank_name: "GTBank",
        account_number: "0123456789",
        account_holder_name: "Driver One",
        bank_code: "058",
      },
    },
  });
}

test("adminMarkWithdrawalPaid happy path debits wallet once and marks paid", async () => {
  const db = seedWithBalance();
  const res = await adminMarkWithdrawalPaid(
    { withdrawal_id: "wd1", idempotency_key: "k1", admin_note: "paid via bank" },
    ADMIN,
    db,
  );
  assert.equal(res.success, true);
  assert.equal(db._store["withdraw_requests/wd1"].status, "paid");
  assert.equal(db._store["wallets/drv1"].balance, 4000);
  assert.ok(db._store["wallets/drv1"].transactions.withdraw_paid_wd1);
});

test("adminMarkWithdrawalPaid requires idempotency_key", async () => {
  const db = seedWithBalance();
  const res = await adminMarkWithdrawalPaid({ withdrawal_id: "wd1" }, ADMIN, db);
  assert.equal(res.success, false);
  assert.equal(res.reason, "idempotency_key_required");
  // No debit happened.
  assert.equal(db._store["wallets/drv1"].balance, 5000);
  assert.equal(db._store["withdraw_requests/wd1"].status, "pending");
});

test("adminMarkWithdrawalPaid requires withdrawal_id", async () => {
  const db = seedWithBalance();
  const res = await adminMarkWithdrawalPaid({ idempotency_key: "k1" }, ADMIN, db);
  assert.equal(res.success, false);
  assert.equal(res.reason, "withdrawal_id_required");
});

test("adminMarkWithdrawalPaid second call is already_finalized and does not double debit", async () => {
  const db = seedWithBalance();
  const first = await adminMarkWithdrawalPaid(
    { withdrawal_id: "wd1", idempotency_key: "k1" },
    ADMIN,
    db,
  );
  assert.equal(first.success, true);
  assert.equal(db._store["wallets/drv1"].balance, 4000);

  const second = await adminMarkWithdrawalPaid(
    { withdrawal_id: "wd1", idempotency_key: "k1" },
    ADMIN,
    db,
  );
  assert.equal(second.success, false);
  assert.equal(second.reason, "already_finalized");
  // Balance unchanged — no second debit.
  assert.equal(db._store["wallets/drv1"].balance, 4000);
});

test("adminRejectWithdrawalRequest requires a reason of >= 3 chars", async () => {
  const db = seedWithBalance();
  const noReason = await adminRejectWithdrawalRequest({ withdrawal_id: "wd1" }, ADMIN, db);
  assert.equal(noReason.success, false);
  assert.equal(noReason.reason, "reason_required");

  const tooShort = await adminRejectWithdrawalRequest(
    { withdrawal_id: "wd1", reason: "no" },
    ADMIN,
    db,
  );
  assert.equal(tooShort.success, false);
  assert.equal(tooShort.reason, "reason_required");
  // Still pending, no debit.
  assert.equal(db._store["withdraw_requests/wd1"].status, "pending");
  assert.equal(db._store["wallets/drv1"].balance, 5000);
});

test("adminRejectWithdrawalRequest happy path marks rejected without debiting", async () => {
  const db = seedWithBalance();
  const res = await adminRejectWithdrawalRequest(
    { withdrawal_id: "wd1", reason: "duplicate request" },
    ADMIN,
    db,
  );
  assert.equal(res.success, true);
  assert.equal(db._store["withdraw_requests/wd1"].status, "rejected");
  // Wallet untouched; no withdrawal_paid transaction created.
  assert.equal(db._store["wallets/drv1"].balance, 5000);
  assert.ok(
    !db._store["wallets/drv1"].transactions ||
      !db._store["wallets/drv1"].transactions.withdraw_paid_wd1,
  );
});

test("non-admin is denied for both actions", async () => {
  const db1 = seedWithBalance();
  const paid = await adminMarkWithdrawalPaid(
    { withdrawal_id: "wd1", idempotency_key: "k1" },
    NON_ADMIN,
    db1,
  );
  assert.notEqual(paid.success, true);
  assert.equal(db1._store["wallets/drv1"].balance, 5000);

  const db2 = seedWithBalance();
  const rejected = await adminRejectWithdrawalRequest(
    { withdrawal_id: "wd1", reason: "should not run" },
    NON_ADMIN,
    db2,
  );
  assert.notEqual(rejected.success, true);
  assert.equal(db2._store["withdraw_requests/wd1"].status, "pending");
});

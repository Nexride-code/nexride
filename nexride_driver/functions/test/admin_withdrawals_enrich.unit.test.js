const assert = require("node:assert/strict");
const { test } = require("node:test");
const admin = require("firebase-admin");

const adminCallables = require("../admin_callables");

if (!admin.apps.length) {
  admin.initializeApp({ projectId: "nexride-test" });
}

const { buildWithdrawalRowEnrichment, adminListWithdrawalsPage } = adminCallables;

// ---- Pure classifier tests ----

test("car_ride driver -> car_driver / driver_wallet", () => {
  const v = buildWithdrawalRowEnrichment("driver", {
    ownership_mode: "individual",
    service_type: "car_ride",
  });
  assert.equal(v.user_type, "car_driver");
  assert.equal(v.wallet_source, "driver_wallet");
  assert.equal(v.ownership_mode, "individual");
  assert.equal(v.service_type, "car_ride");
  assert.equal(v.business_id, null);
});

test("independent bike_dispatch driver -> independent_dispatch", () => {
  const v = buildWithdrawalRowEnrichment("driver", {
    ownership_mode: "individual",
    service_type: "bike_dispatch",
    dispatch_vehicle_type: "bike",
  });
  assert.equal(v.user_type, "independent_dispatch");
  assert.equal(v.wallet_source, "driver_wallet");
  assert.equal(v.dispatch_vehicle_type, "bike");
});

test("business_managed bike driver -> business_managed_biker (with business_id)", () => {
  const v = buildWithdrawalRowEnrichment("driver", {
    ownership_mode: "business_managed",
    service_type: "bike_dispatch",
    dispatch_vehicle_type: "bike",
    business_id: "biz_7",
  });
  assert.equal(v.user_type, "business_managed_biker");
  assert.equal(v.business_id, "biz_7");
  assert.equal(v.wallet_source, "driver_wallet");
});

test("merchant row -> merchant / merchant_wallet", () => {
  const v = buildWithdrawalRowEnrichment("merchant", null);
  assert.equal(v.user_type, "merchant");
  assert.equal(v.wallet_source, "merchant_wallet");
  assert.equal(v.service_type, null);
  assert.equal(v.ownership_mode, null);
});

test("driver with no profile -> unknown_driver", () => {
  const v = buildWithdrawalRowEnrichment("driver", null);
  assert.equal(v.user_type, "unknown_driver");
  assert.equal(v.wallet_source, "driver_wallet");
});

test("legacy dispatch profile with no vehicle -> independent_dispatch via unknown_dispatch", () => {
  const v = buildWithdrawalRowEnrichment("driver", {
    ownership_mode: "individual",
    driver_service_types: ["dispatch_driver"],
  });
  assert.equal(v.service_type, "unknown_dispatch");
  assert.equal(v.user_type, "independent_dispatch");
});

// ---- End-to-end list enrichment + pagination ----

function createMockDb(initial = {}) {
  const store = { ...initial };
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
    const qs = { orderByKey: false, startAfter: null, limit: null };
    const api = {
      orderByKey() {
        qs.orderByKey = true;
        return api;
      },
      startAfter(key) {
        qs.startAfter = String(key || "");
        return api;
      },
      limitToFirst(n) {
        qs.limit = Math.max(0, Number(n) || 0);
        return api;
      },
      async get() {
        if (qs.orderByKey && qs.limit != null) {
          const obj = buildObjectForPath(p) || {};
          let keys = Object.keys(obj).sort();
          if (qs.startAfter) keys = keys.filter((k) => k > qs.startAfter);
          const slice = keys.slice(0, qs.limit);
          if (!slice.length) return { exists: () => false, val: () => null };
          const out = {};
          for (const k of slice) out[k] = obj[k];
          return { exists: () => true, val: () => out };
        }
        let val = Object.prototype.hasOwnProperty.call(store, p) ? store[p] : undefined;
        if (val === undefined) val = buildObjectForPath(p);
        return { exists: () => val != null, val: () => (val === undefined ? null : val) };
      },
    };
    return api;
  }
  return { ref };
}

function adminContext() {
  return { auth: { uid: "admin_1", token: { admin: true, admin_role: "super_admin" } } };
}

test("adminListWithdrawalsPage enriches rows and paginates", async () => {
  const db = createMockDb({
    "admins/admin_1": { enabled: true, admin_role: "super_admin" },
    // three withdrawal rows (keys sort lexicographically wd1<wd2<wd3)
    "withdraw_requests/wd1": {
      withdrawalId: "wd1",
      entity_type: "driver",
      driver_id: "drv_car",
      amount: 1000,
      status: "pending",
      requestedAt: 30,
      withdrawal_destination_snapshot: {
        bank_name: "GTBank",
        account_number: "0123456789",
        account_holder_name: "Car Driver",
        bank_code: "058",
      },
    },
    "withdraw_requests/wd2": {
      withdrawalId: "wd2",
      entity_type: "driver",
      driver_id: "drv_biz",
      amount: 2000,
      status: "pending",
      requestedAt: 20,
      withdrawal_destination_snapshot: {
        bank_name: "Access",
        account_number: "1112223334",
        account_holder_name: "Biz Biker",
      },
    },
    "withdraw_requests/wd3": {
      withdrawalId: "wd3",
      entity_type: "merchant",
      merchant_id: "mer_1",
      amount: 3000,
      status: "pending",
      requestedAt: 10,
    },
    "drivers/drv_car": { ownership_mode: "individual", service_type: "car_ride" },
    "drivers/drv_biz": {
      ownership_mode: "business_managed",
      service_type: "bike_dispatch",
      dispatch_vehicle_type: "bike",
      business_id: "biz_9",
    },
  });

  // Full page: all three rows returned and enriched per type.
  const all = await adminListWithdrawalsPage({ limit: 10 }, adminContext(), db);
  assert.equal(all.success, true);
  assert.equal(all.count, 3);
  assert.equal(all.hasMore, false);

  const car = all.withdrawals.wd1;
  assert.equal(car.user_type, "car_driver");
  assert.equal(car.wallet_source, "driver_wallet");
  assert.equal(car.bank_code, "058");
  assert.equal(car.service_type, "car_ride");

  const biz = all.withdrawals.wd2;
  assert.equal(biz.user_type, "business_managed_biker");
  assert.equal(biz.business_id, "biz_9");
  assert.equal(biz.bank_code, null);

  const merchantRow = all.withdrawals.wd3;
  assert.equal(merchantRow.user_type, "merchant");
  assert.equal(merchantRow.wallet_source, "merchant_wallet");
  assert.equal(merchantRow.service_type, null);

  // Pagination mechanics still work: a small limit caps the page and sets a cursor.
  const page1 = await adminListWithdrawalsPage({ limit: 2 }, adminContext(), db);
  assert.equal(page1.success, true);
  assert.equal(page1.count, 2);
  assert.equal(page1.hasMore, true);
  assert.ok(page1.nextCursor, "nextCursor set when more rows exist");
});

test("adminListWithdrawalsPage denies non-admin", async () => {
  const db = createMockDb({ "withdraw_requests/wd1": { entity_type: "driver", status: "pending" } });
  const res = await adminListWithdrawalsPage({ limit: 10 }, { auth: { uid: "nobody" } }, db);
  assert.notEqual(res.success, true);
});

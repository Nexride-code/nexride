/**
 * Production settlement policy tests — exercises the same code paths as
 * completeTrip / recordTripCompletion / subscription settlement.
 */
const assert = require("node:assert/strict");
const { test } = require("node:test");
const rideFinance = require("../ride_finance_settlement");

function deepGet(store, parts) {
  let cur = store;
  for (const p of parts) {
    if (cur == null) return undefined;
    cur = cur[p];
  }
  return cur;
}

function deepSet(store, parts, value) {
  let cur = store;
  for (let i = 0; i < parts.length - 1; i++) {
    if (!cur[parts[i]] || typeof cur[parts[i]] !== "object") {
      cur[parts[i]] = {};
    }
    cur = cur[parts[i]];
  }
  cur[parts[parts.length - 1]] = value;
}

/**
 * In-memory RTDB mock matching production ledger paths used by settleCompletedRideOnce.
 */
function makeProductionFinanceTestDb(initial = {}) {
  const store = {
    ride_requests: { ...(initial.ride_requests || {}) },
    drivers: { ...(initial.drivers || {}) },
    platform_ledger: { ...(initial.platform_ledger || {}) },
    driver_wallet_ledger: { ...(initial.driver_wallet_ledger || {}) },
    wallets: {
      nexride_platform: { balance: 0, transactions: {} },
      ...(initial.wallets || {}),
    },
    driver_earnings: { ...(initial.driver_earnings || {}) },
    withdraw_requests: { ...(initial.withdraw_requests || {}) },
  };

  function ref(path) {
    const parts = String(path).split("/").filter(Boolean);

    return {
      async get() {
        const val = deepGet(store, parts);
        return {
          exists: () => val !== undefined && val !== null,
          val: () => val,
        };
      },
      async update(patch) {
        const parentParts = parts.slice(0, -1);
        const key = parts[parts.length - 1];
        const parent =
          parentParts.length === 0 ? store : deepGet(store, parentParts) || {};
        if (parentParts.length > 0) {
          deepSet(store, parentParts, parent);
        }
        const cur = parent[key] && typeof parent[key] === "object" ? parent[key] : {};
        parent[key] = { ...cur, ...patch };
        if (parentParts.length > 0) {
          deepSet(store, parentParts, parent);
        } else {
          store[key] = parent[key];
        }
      },
      async set(value) {
        deepSet(store, parts, value);
      },
      async remove() {
        const parentParts = parts.slice(0, -1);
        const key = parts[parts.length - 1];
        if (parentParts.length === 0) {
          delete store[key];
          return;
        }
        const parent = deepGet(store, parentParts);
        if (parent && typeof parent === "object") {
          delete parent[key];
        }
      },
      async transaction(updateFn) {
        const cur = deepGet(store, parts);
        const next = updateFn(cur);
        if (next === undefined) {
          return { committed: false };
        }
        deepSet(store, parts, next);
        return { committed: true };
      },
      orderByKey() {
        return this;
      },
      startAfter(key) {
        this._startAfter = key;
        return this;
      },
      limitToFirst(n) {
        this._limit = n;
        return this;
      },
    };
  }

  // orderByKey batch reads for summarizePlatformRevenueBuckets
  const origRef = ref.bind(null);
  const db = {
    ref(path) {
      const r = origRef(path);
      const p = String(path);
      if (
        p === "platform_ledger" ||
        p === "driver_wallet_ledger" ||
        p === "withdraw_requests"
      ) {
        return {
          orderByKey() {
            return {
              startAfter(key) {
                return {
                  limitToFirst(limit) {
                    const root = store[p] || {};
                    let keys = Object.keys(root).sort();
                    if (key) {
                      keys = keys.filter((k) => k > key);
                    }
                    keys = keys.slice(0, limit);
                    const val = {};
                    for (const k of keys) {
                      val[k] = root[k];
                    }
                    return {
                      async get() {
                        return {
                          val: () => val,
                          exists: () => keys.length > 0,
                        };
                      },
                    };
                  },
                };
              },
              limitToFirst(limit) {
                return this.startAfter("").limitToFirst(limit);
              },
            };
          },
        };
      }
      return r;
    },
    _store: store,
  };

  return db;
}

function walletBalance(store, userId) {
  return Number(store.wallets[userId]?.balance ?? 0);
}

function walletTxCount(store, userId) {
  const tx = store.wallets[userId]?.transactions;
  return tx && typeof tx === "object" ? Object.keys(tx).length : 0;
}

function countDriverNetLedgerEntries(store, driverId) {
  const perDriver = store.driver_wallet_ledger[driverId];
  if (!perDriver || typeof perDriver !== "object") return 0;
  return Object.keys(perDriver).filter((k) => k.endsWith("_driver_net") && perDriver[k]?.completed)
    .length;
}

// --- Policy A: commission driver ---
test("PRODUCTION A: commission driver trip_fare=1000 booking=30 commission=100 driver_net=900", async () => {
  const db = makeProductionFinanceTestDb({
    ride_requests: {
      rideA: {
        fare: 1000,
        total_ngn: 1030,
        platform_fee_ngn: 30,
        driver_id: "drv_comm",
        rider_id: "rider1",
      },
    },
    drivers: {
      drv_comm: { commission_exempt: false },
    },
    wallets: {
      drv_comm: { balance: 0, transactions: {} },
    },
  });

  const r = await rideFinance.settleCompletedRideOnce(db, {
    rideId: "rideA",
    driverId: "drv_comm",
    source: "complete_trip",
  });
  assert.equal(r.success, true);
  assert.equal(r.settlement.trip_fare_ngn, 1000);
  assert.equal(r.settlement.booking_fee_ngn, 30);
  assert.equal(r.settlement.commission_ngn, 100);
  assert.equal(r.settlement.driver_net_ngn, 900);
  assert.equal(r.settlement.rider_total_ngn, 1030);

  const s = db._store;
  assert.equal(s.platform_ledger.rideA_booking_fee.revenue_type, "booking_fee_revenue");
  assert.equal(s.platform_ledger.rideA_booking_fee.amount_ngn, 30);
  assert.equal(s.platform_ledger.rideA_commission.revenue_type, "commission_revenue");
  assert.equal(s.platform_ledger.rideA_commission.amount_ngn, 100);
  assert.equal(walletBalance(s, "drv_comm"), 900);
  assert.equal(walletBalance(s, "nexride_platform"), 130);
  assert.equal(countDriverNetLedgerEntries(s, "drv_comm"), 1);

  const forbidden = Object.values(s.wallets.drv_comm.transactions).some(
    (t) =>
      t.type === "booking_fee_revenue" ||
      t.type === "commission_revenue" ||
      t.type === "subscription_revenue",
  );
  assert.equal(forbidden, false);
});

// --- Policy B: subscription driver ---
test("PRODUCTION B: subscription driver commission=0 driver_net=1000 booking_fee=30 only", async () => {
  const future = Date.now() + 7 * 24 * 60 * 60 * 1000;
  const db = makeProductionFinanceTestDb({
    ride_requests: {
      rideB: {
        fare: 1000,
        total_ngn: 1030,
        driver_id: "drv_sub",
        rider_id: "rider1",
      },
    },
    drivers: {
      drv_sub: { commission_exempt: true, subscription_expires_at: future },
    },
    wallets: {
      drv_sub: { balance: 0, transactions: {} },
    },
  });

  const r = await rideFinance.settleCompletedRideOnce(db, {
    rideId: "rideB",
    driverId: "drv_sub",
    source: "complete_trip",
  });
  assert.equal(r.success, true);
  assert.equal(r.settlement.commission_ngn, 0);
  assert.equal(r.settlement.driver_net_ngn, 1000);
  assert.equal(r.settlement.booking_fee_ngn, 30);

  const s = db._store;
  assert.equal(s.platform_ledger.rideB_booking_fee.amount_ngn, 30);
  assert.equal(s.platform_ledger.rideB_commission, undefined);
  assert.equal(walletBalance(s, "drv_sub"), 1000);
  assert.equal(walletBalance(s, "nexride_platform"), 30);
});

// --- Policy C: retry completeTrip — no duplicate credits ---
test("PRODUCTION C: retry settleCompletedRideOnce does not duplicate wallet or platform ledger", async () => {
  const db = makeProductionFinanceTestDb({
    ride_requests: {
      rideC: { fare: 1000, driver_id: "drvC", rider_id: "r1" },
    },
    drivers: { drvC: { commission_exempt: false } },
    wallets: { drvC: { balance: 0, transactions: {} } },
  });

  const first = await rideFinance.settleCompletedRideOnce(db, {
    rideId: "rideC",
    driverId: "drvC",
    source: "complete_trip",
  });
  assert.equal(first.success, true);

  const platformBf = db._store.platform_ledger.rideC_booking_fee;
  const platformComm = db._store.platform_ledger.rideC_commission;
  const driverBal = walletBalance(db._store, "drvC");
  const platformBal = walletBalance(db._store, "nexride_platform");
  const driverTxCount = walletTxCount(db._store, "drvC");
  const platformTxCount = walletTxCount(db._store, "nexride_platform");

  const second = await rideFinance.settleCompletedRideOnce(db, {
    rideId: "rideC",
    driverId: "drvC",
    source: "complete_trip",
  });
  assert.equal(second.success, true);
  assert.equal(second.reason, "already_settled");
  assert.equal(second.idempotent, true);

  assert.deepEqual(db._store.platform_ledger.rideC_booking_fee, platformBf);
  assert.deepEqual(db._store.platform_ledger.rideC_commission, platformComm);
  assert.equal(walletBalance(db._store, "drvC"), driverBal);
  assert.equal(walletBalance(db._store, "nexride_platform"), platformBal);
  assert.equal(walletTxCount(db._store, "drvC"), driverTxCount);
  assert.equal(walletTxCount(db._store, "nexride_platform"), platformTxCount);
});

// --- Policy D: subscription payment — subscription_revenue only ---
test("PRODUCTION D: subscription payment records subscription_revenue only, no driver_net ledger", async () => {
  const db = makeProductionFinanceTestDb({
    wallets: { nexride_platform: { balance: 0, transactions: {} } },
    driver_wallet_ledger: {},
  });

  const r = await rideFinance.recordSubscriptionRevenueOnce(db, {
    txRef: "sub_prod_tx",
    amountNgn: 7000,
    driverId: "drv_sub",
    ownerUid: "drv_sub",
    planType: "monthly",
  });
  assert.equal(r.success, true);

  const s = db._store;
  assert.equal(s.platform_ledger.sub_prod_tx_subscription.revenue_type, "subscription_revenue");
  assert.equal(s.platform_ledger.sub_prod_tx_subscription.amount_ngn, 7000);
  assert.equal(countDriverNetLedgerEntries(s, "drv_sub"), 0);
  assert.equal(s.driver_wallet_ledger.drv_sub, undefined);
  assert.equal(walletBalance(s, "nexride_platform"), 7000);
  assert.equal(
    Object.values(s.wallets.nexride_platform.transactions).some(
      (t) => t.type === "subscription_revenue",
    ),
    true,
  );
});

test("tripFareFromRide never uses total_ngn or total_delivery_fee", () => {
  assert.equal(
    rideFinance.tripFareFromRide({
      fare: 1000,
      total_ngn: 5000,
      total_delivery_fee: 4000,
    }),
    1000,
  );
  assert.equal(rideFinance.computeRiderTotalNgn({ fare: 1000, total_ngn: 1030 }), 1030);
});

test("computeRideFinanceBreakdown matches production policy constants", () => {
  const ride = { fare: 1000, total_ngn: 1030, platform_fee_ngn: 30 };
  const b = rideFinance.computeRideFinanceBreakdown(ride, { commissionExempt: false });
  assert.equal(b.trip_fare_ngn, 1000);
  assert.equal(b.booking_fee_ngn, 30);
  assert.equal(b.commission_ngn, 100);
  assert.equal(b.driver_net_ngn, 900);
  assert.equal(b.rider_total_ngn, 1030);
});

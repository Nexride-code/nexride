const assert = require("node:assert/strict");
const { test } = require("node:test");

const appPricing = require("../app_config_pricing");
const { computeRiderPricing } = require("../pricing_calculator");
const platformWallet = require("../platform_wallet");
const {
  computeDeliveryDriverNetNgn,
  settleFleetLinkedDeliveryEarningOnce,
} = require("../fleet_delivery_settlement");

const GLOBAL_PRICING = {
  commissionRate: 0.1,
  fleetOwnerCommissionRate: 0.08,
  bookingFeeNgn: 30,
  dispatch: {
    bookingFeeMode: "max_fixed_or_percentage",
    bookingFeeNgn: 150,
    bookingFeePercent: 5,
    bookingFeeMinNgn: 150,
  },
};

function makePricingDb(pricing = GLOBAL_PRICING) {
  return {
    ref(path) {
      const p = String(path);
      return {
        async get() {
          if (p === "app_config/pricing") {
            return { val: () => pricing };
          }
          return { val: () => null };
        },
      };
    },
  };
}

function makeFirestore(merchantOverrides = {}) {
  const fleets = {};
  const ledgerExists = new Set();
  const defaultMerchant = {
    account_kind: "dispatch_fleet",
    payment_model: "subscription",
    commission_rate: 0,
    commission_exempt: true,
  };
  return {
    collection(name) {
      assert.equal(name, "merchants");
      return {
        doc(fid) {
          return {
            path: `merchants/${fid}`,
            async get() {
              return {
                exists: true,
                data: () => ({ ...defaultMerchant, ...(merchantOverrides[fid] || {}) }),
              };
            },
            collection(sub) {
              assert.equal(sub, "fleet_wallet_ledger");
              return {
                doc(ledgerId) {
                  return { path: `merchants/${fid}/fleet_wallet_ledger/${ledgerId}` };
                },
              };
            },
          };
        },
      };
    },
    async runTransaction(fn) {
      const tx = {
        async get(ref) {
          const { path } = ref;
          if (path.includes("/fleet_wallet_ledger/")) {
            return { exists: ledgerExists.has(path), data: () => ({}) };
          }
          const fid = path.split("/")[1];
          if (!fleets[fid]) fleets[fid] = { fleet_wallet_balance_ngn: 0 };
          return { exists: true, data: () => fleets[fid] };
        },
        set(ref, data) {
          const { path } = ref;
          if (path.includes("/fleet_wallet_ledger/")) {
            ledgerExists.add(path);
            return;
          }
          const fid = path.split("/")[1];
          fleets[fid] = { ...(fleets[fid] || {}), ...data };
        },
      };
      await fn(tx);
    },
    _peek(fid) {
      return fleets[fid];
    },
  };
}

function makeDb(store) {
  const data = {
    "app_config/pricing": GLOBAL_PRICING,
    ...store,
  };
  return {
    ref(path) {
      const p = String(path);
      return {
        async get() {
          return {
            exists: () => Object.prototype.hasOwnProperty.call(data, p),
            val: () => (Object.prototype.hasOwnProperty.call(data, p) ? data[p] : null),
          };
        },
        async transaction(fn) {
          const cur = data[p];
          const next = fn(cur);
          if (next === undefined) {
            return { committed: false };
          }
          data[p] = next;
          return { committed: true };
        },
        async update(patch) {
          const cur = data[p] && typeof data[p] === "object" ? data[p] : {};
          data[p] = { ...cur, ...patch };
        },
        async remove() {
          delete data[p];
        },
      };
    },
    _store: data,
  };
}

function paidDeliveryRow(overrides = {}) {
  return {
    fare: 2000,
    delivery_fee_ngn: 2000,
    booking_fee_ngn: 150,
    platform_fee_ngn: 150,
    total_ngn: 2150,
    payment_status: "paid_verified",
    payment_verified: true,
    payment_transaction_id: "flw_del_1",
    ...overrides,
  };
}

test("resolveFleetOwnerCommissionRate uses global rate for subscription fleet with commission_exempt", async () => {
  const db = makePricingDb();
  const fs = makeFirestore({
    fleet_sub: { payment_model: "subscription", commission_exempt: true, commission_rate: 0 },
  });
  const rate = await appPricing.resolveFleetOwnerCommissionRate(db, "fleet_sub", fs);
  assert.equal(rate, 0.08);
});

test("resolveFleetOwnerCommissionRate ignores legacy merchant commission_rate override", async () => {
  const db = makePricingDb();
  const fs = makeFirestore({
    fleet_legacy: { commission_rate: 0.15, commission_exempt: false, payment_model: "commission" },
  });
  const rate = await appPricing.resolveFleetOwnerCommissionRate(db, "fleet_legacy", fs);
  assert.equal(rate, 0.08);
});

test("dispatch rider payable includes booking fee", () => {
  const pricing = computeRiderPricing(
    { flow: "dispatch_request", trip_fare_ngn: 2000 },
    GLOBAL_PRICING,
  );
  assert.equal(pricing.platform_fee_ngn, 150);
  assert.equal(pricing.total_ngn, 2150);
});

test("fleet delivery settlement example: 8% commission on trip fare", async () => {
  const fs = makeFirestore({ fleet_1: {} });
  const db = makeDb({
    "drivers/drv_fleet": {
      ownership_mode: "business_managed",
      business_id: "fleet_1",
    },
  });
  const row = paidDeliveryRow();

  assert.equal(computeDeliveryDriverNetNgn(row, false, 0.08), 1840);

  const fleetRes = await settleFleetLinkedDeliveryEarningOnce(db, {
    deliveryId: "del_global",
    deliveryRow: row,
    driverId: "drv_fleet",
    source: "test",
    fs,
  });
  assert.equal(fleetRes.success, true);
  assert.equal(fleetRes.amount_ngn, 1840);
  assert.equal(fs._peek("fleet_1").fleet_wallet_balance_ngn, 1840);

  const platformDb = {
    ref(path) {
      const parts = String(path).split("/").filter(Boolean);
      const store = db._store;
      if (parts[0] === "platform_wallet") {
        if (!store.platform_wallet) {
          store.platform_wallet = { balance: 0, total_revenue: 0, ledger: {} };
        }
      }
      return {
        async get() {
          let val;
          if (parts.length === 1) {
            val = store[parts[0]];
          } else if (parts[0] === "drivers") {
            val = store[`drivers/${parts[1]}`];
          } else if (parts[0] === "app_config") {
            val = store["app_config/pricing"];
          } else {
            val = store[parts.join("/")];
          }
          return { exists: () => val != null, val: () => val ?? null };
        },
        async set(value) {
          if (parts[0] === "platform_wallet" && parts.length === 1) {
            store.platform_wallet = value;
          }
        },
        async update(patch) {
          const cur = store.platform_wallet || {};
          store.platform_wallet = { ...cur, ...patch };
        },
        async transaction(fn) {
          const cur = store[parts.join("/")];
          const next = fn(cur);
          if (next === undefined) return { committed: false };
          store[parts.join("/")] = next;
          return { committed: true, snapshot: { val: () => store[parts.join("/")] } };
        },
      };
    },
    _store: db._store,
  };
  if (!platformDb._store.platform_wallet) {
    platformDb._store.platform_wallet = {
      balance: 0,
      total_revenue: 0,
      total_commission_revenue: 0,
      total_booking_fee_revenue: 0,
      ledger: {},
    };
  }

  const breakdown = await platformWallet.computeDeliveryPlatformBreakdownForSettlement(
    platformDb,
    row,
    "drv_fleet",
  );
  assert.equal(breakdown.commission_amount, 160);
  assert.equal(breakdown.booking_fee_amount, 150);
  assert.equal(breakdown.platform_total, 310);
  assert.equal(breakdown.driver_payout, 1840);

  const platformRes = await platformWallet.settleDeliveryPlatformRevenueOnce(platformDb, {
    deliveryId: "del_global",
    deliveryRow: row,
    driverId: "drv_fleet",
    source: "test",
  });
  assert.equal(platformRes.success, true);
  assert.equal(platformDb._store.platform_wallet.balance, 310);
});

test("resolveFleetOwnerCommissionRate uses global rate for newly created fleet merchant", async () => {
  const db = makePricingDb();
  const fs = makeFirestore({
    fleet_new: {
      payment_model: "commission",
      commission_rate: 0.25,
      commission_exempt: false,
    },
  });
  const rate = await appPricing.resolveFleetOwnerCommissionRate(db, "fleet_new", fs);
  assert.equal(rate, 0.08);
});

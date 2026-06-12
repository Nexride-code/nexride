const assert = require("node:assert/strict");
const { test } = require("node:test");

const appPricing = require("../app_config_pricing");
const { computeRiderPricing } = require("../pricing_calculator");
const { pricingSnapshotFromConfig } = require("../pricing_snapshot");
const platformWallet = require("../platform_wallet");
const {
  settleFleetLinkedDeliveryEarningOnce,
  settleIndependentDeliveryDriverEarningOnce,
} = require("../fleet_delivery_settlement");

const DISPATCH_PRICING = {
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

function makePricingDb(pricing = DISPATCH_PRICING) {
  return {
    ref(path) {
      if (String(path) === "app_config/pricing") {
        return { async get() { return { val: () => pricing }; } };
      }
      return { async get() { return { val: () => null }; } };
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
    "app_config/pricing": DISPATCH_PRICING,
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
        async set(value) {
          data[p] = value;
        },
        async remove() {
          delete data[p];
        },
      };
    },
    _store: data,
  };
}

function verifiedDeliveryRow(overrides = {}) {
  const fare = overrides.fare ?? overrides.delivery_fee_ngn ?? 5000;
  const bookingFee = overrides.booking_fee_ngn ?? 250;
  return {
    fare,
    delivery_fee_ngn: fare,
    booking_fee_ngn: bookingFee,
    platform_fee_ngn: bookingFee,
    total_ngn: fare + bookingFee,
    payment_status: "paid_verified",
    payment_verified: true,
    payment_transaction_id: "flw_dispatch_1",
    pricing_snapshot: {
      commission_rate: 0.1,
      booking_fee_ngn: bookingFee,
      booking_fee_mode: "max_fixed_or_percentage",
      booking_fee_percent: 5,
      booking_fee_min_ngn: 150,
      delivery_fee_ngn: fare,
      total_ngn: fare + bookingFee,
      trip_fare_ngn: fare,
      frozen: true,
    },
    ...overrides,
  };
}

function ensurePlatformWallet(store) {
  if (!store.platform_wallet) {
    store.platform_wallet = {
      balance: 0,
      total_revenue: 0,
      total_commission_revenue: 0,
      total_booking_fee_revenue: 0,
      ledger: {},
    };
  }
}

test("customer total includes delivery fee plus dispatch booking fee", () => {
  const pricing = computeRiderPricing(
    { flow: "dispatch_request", trip_fare_ngn: 5000 },
    DISPATCH_PRICING,
  );
  assert.equal(pricing.delivery_fee_ngn, 5000);
  assert.equal(pricing.platform_fee_ngn, 250);
  assert.equal(pricing.total_ngn, 5250);
});

test("dispatch booking fee percentage examples", () => {
  const cfg = appPricing.normalizePricingConfig({ cities: {} });
  assert.equal(appPricing.computeBookingFeeNgn(cfg, 1000, "dispatch_request"), 150);
  assert.equal(appPricing.computeBookingFeeNgn(cfg, 5000, "dispatch_request"), 250);
  assert.equal(appPricing.computeBookingFeeNgn(cfg, 10000, "dispatch_request"), 500);
  assert.equal(appPricing.computeBookingFeeNgn(cfg, 20000, "dispatch_request"), 1000);
});

test("pricing snapshot freezes dispatch booking fee and total", () => {
  const cfg = appPricing.normalizePricingConfig(DISPATCH_PRICING);
  const pricing = computeRiderPricing({ flow: "dispatch_request", trip_fare_ngn: 5000 }, cfg);
  const snapshot = pricingSnapshotFromConfig(
    cfg,
    5000,
    pricing.total_ngn,
    "lagos",
    "delivery",
  );
  assert.equal(snapshot.booking_fee_ngn, 250);
  assert.equal(snapshot.booking_fee_scope, "dispatch");
  assert.equal(snapshot.delivery_fee_ngn, 5000);
  assert.equal(snapshot.total_ngn, 5250);

  const updatedCfg = appPricing.normalizePricingConfig({
    ...DISPATCH_PRICING,
    dispatch: {
      bookingFeeMode: "fixed",
      bookingFeeNgn: 999,
      bookingFeePercent: 20,
      bookingFeeMinNgn: 999,
    },
  });
  assert.equal(snapshot.booking_fee_ngn, 250);
  assert.equal(snapshot.total_ngn, 5250);
  const fresh = pricingSnapshotFromConfig(updatedCfg, 5000, 5999, "lagos", "delivery");
  assert.equal(fresh.booking_fee_ngn, 999);
  assert.notEqual(snapshot.booking_fee_ngn, fresh.booking_fee_ngn);
});

test("independent delivery credits driver net and platform booking fee plus commission", async () => {
  const db = makeDb({
    "drivers/drv_ind": { ownership_mode: "independent" },
    "wallets/drv_ind": { balance: 0 },
  });
  const row = verifiedDeliveryRow();

  const driverRes = await settleIndependentDeliveryDriverEarningOnce(db, {
    deliveryId: "del_ind",
    deliveryRow: row,
    driverId: "drv_ind",
    source: "test",
  });
  assert.equal(driverRes.success, true);
  assert.equal(driverRes.amount_ngn, 4500);

  ensurePlatformWallet(db._store);
  const breakdown = platformWallet.computeDeliveryPlatformBreakdown(row);
  assert.equal(breakdown.commission_amount, 500);
  assert.equal(breakdown.booking_fee_amount, 250);
  assert.equal(breakdown.platform_total, 750);
  assert.equal(breakdown.driver_payout, 4500);

  const platformRes = await platformWallet.settleDeliveryPlatformRevenueOnce(db, {
    deliveryId: "del_ind",
    deliveryRow: row,
    driverId: "drv_ind",
    source: "test",
  });
  assert.equal(platformRes.success, true);
  assert.equal(db._store.platform_wallet.balance, 750);
});

test("fleet delivery credits fleet wallet with delivery fee minus global commission", async () => {
  const fs = makeFirestore({
    fleet_1: { commission_rate: 0.2, commission_exempt: false },
  });
  const db = makeDb({
    "drivers/drv_fleet": {
      ownership_mode: "business_managed",
      business_id: "fleet_1",
      commission_exempt: true,
    },
  });
  const row = verifiedDeliveryRow();

  const fleetRes = await settleFleetLinkedDeliveryEarningOnce(db, {
    deliveryId: "del_fleet",
    deliveryRow: row,
    driverId: "drv_fleet",
    source: "test",
    fs,
  });
  assert.equal(fleetRes.success, true);
  assert.equal(fleetRes.amount_ngn, 4600);
  assert.equal(fs._peek("fleet_1").fleet_wallet_balance_ngn, 4600);

  const indRes = await settleIndependentDeliveryDriverEarningOnce(db, {
    deliveryId: "del_fleet",
    deliveryRow: row,
    driverId: "drv_fleet",
    source: "test",
  });
  assert.equal(indRes.reason, "fleet_managed_skipped");

  ensurePlatformWallet(db._store);
  const breakdown = await platformWallet.computeDeliveryPlatformBreakdownForSettlement(
    db,
    row,
    "drv_fleet",
    fs,
  );
  assert.equal(breakdown.commission_amount, 400);
  assert.equal(breakdown.booking_fee_amount, 250);
  assert.equal(breakdown.platform_total, 650);
  assert.equal(breakdown.driver_payout, 4600);
});

test("existing and new fleets use global fleet commission rate only", async () => {
  const db = makePricingDb();
  const fs = makeFirestore({
    fleet_existing: { commission_rate: 0.15, commission_exempt: false },
    fleet_new: { commission_rate: 0.25, commission_exempt: true },
  });
  assert.equal(
    await appPricing.resolveFleetOwnerCommissionRate(db, "fleet_existing", fs),
    0.08,
  );
  assert.equal(await appPricing.resolveFleetOwnerCommissionRate(db, "fleet_new", fs), 0.08);
});

test("dispatch settlement blocked until Flutterwave payment is verified", async () => {
  const fs = makeFirestore({ fleet_1: {} });
  const db = makeDb({
    "drivers/drv_fleet": { ownership_mode: "business_managed", business_id: "fleet_1" },
    "drivers/drv_ind": { ownership_mode: "independent" },
  });
  const unpaid = {
    fare: 5000,
    booking_fee_ngn: 250,
    payment_status: "pending",
    payment_verified: false,
  };

  const fleetRes = await settleFleetLinkedDeliveryEarningOnce(db, {
    deliveryId: "del_unpaid",
    deliveryRow: unpaid,
    driverId: "drv_fleet",
    source: "test",
    fs,
  });
  assert.equal(fleetRes.success, false);
  assert.equal(fleetRes.reason, "payment_not_verified");

  const indRes = await settleIndependentDeliveryDriverEarningOnce(db, {
    deliveryId: "del_unpaid",
    deliveryRow: unpaid,
    driverId: "drv_ind",
    source: "test",
  });
  assert.equal(indRes.success, false);
  assert.equal(indRes.reason, "payment_not_verified");

  ensurePlatformWallet(db._store);
  const platformRes = await platformWallet.settleDeliveryPlatformRevenueOnce(db, {
    deliveryId: "del_unpaid",
    deliveryRow: unpaid,
    driverId: "drv_ind",
    source: "test",
  });
  assert.equal(platformRes.reason, "payment_not_verified");
  assert.equal(db._store.platform_wallet.balance, 0);
});

const assert = require("node:assert/strict");
const { test } = require("node:test");
const {
  computeDeliveryDriverNetNgn,
  fleetBusinessIdFromDriverProfile,
  settleFleetLinkedDeliveryEarningOnce,
  settleIndependentDeliveryDriverEarningOnce,
} = require("../fleet_delivery_settlement");

function makeFirestore(merchantOverrides = {}) {
  const fleets = {};
  const merchantMeta = {};
  const ledgerExists = new Set();
  return {
    collection(name) {
      assert.equal(name, "merchants");
      return {
        doc(fid) {
          return {
            path: `merchants/${fid}`,
            async get() {
              const meta = merchantMeta[fid] || merchantOverrides[fid] || {
                account_kind: "dispatch_fleet",
                business_type: "dispatch_fleet",
                merchant_status: "approved",
                payment_model: "commission",
                commission_rate: 0.1,
                commission_exempt: false,
              };
              return { exists: true, data: () => meta };
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

const GLOBAL_FLEET_PRICING = {
  commissionRate: 0.1,
  fleetOwnerCommissionRate: 0.08,
  bookingFeeNgn: 30,
};

function makeDb(store) {
  const data = {
    "app_config/pricing": GLOBAL_FLEET_PRICING,
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

test("fleetBusinessIdFromDriverProfile only for business_managed", () => {
  assert.equal(
    fleetBusinessIdFromDriverProfile({ ownership_mode: "business_managed", business_id: "biz1" }),
    "biz1",
  );
  assert.equal(
    fleetBusinessIdFromDriverProfile({ ownership_mode: "individual", business_id: "biz1" }),
    "",
  );
});

test("computeDeliveryDriverNetNgn applies fleet merchant commission rate", () => {
  assert.equal(computeDeliveryDriverNetNgn({ fare: 1000 }, false, 0.15), 850);
  assert.equal(computeDeliveryDriverNetNgn({ fare: 1000 }, false, 0.1), 900);
  assert.equal(computeDeliveryDriverNetNgn({ fare: 1000 }, true, 0.1), 1000);
});

test("settleFleetLinkedDeliveryEarningOnce credits fleet wallet for linked driver", async () => {
  const fs = makeFirestore();

  const db = makeDb({
    "drivers/drv_fleet": {
      ownership_mode: "business_managed",
      business_id: "fleet_1",
      commission_exempt: false,
    },
    "drivers/drv_fleet/businessModel": { effectiveModel: "commission" },
  });

  const r = await settleFleetLinkedDeliveryEarningOnce(db, {
    deliveryId: "del_1",
    deliveryRow: {
      fare: 2000,
      payment_status: "paid_verified",
      payment_verified: true,
      payment_transaction_id: "flw_settle_1",
    },
    driverId: "drv_fleet",
    source: "test",
    fs,
  });
  assert.equal(r.success, true);
  assert.equal(r.amount_ngn, 1840);
  assert.equal(fs._peek("fleet_1").fleet_wallet_balance_ngn, 1840);
  assert.ok(db._store["fleet_delivery_earnings_ledger/fleet_1/del_1"].completed);

  const r2 = await settleFleetLinkedDeliveryEarningOnce(db, {
    deliveryId: "del_1",
    deliveryRow: {
      fare: 2000,
      payment_status: "paid_verified",
      payment_verified: true,
      payment_transaction_id: "flw_settle_1",
    },
    driverId: "drv_fleet",
    source: "test",
    fs,
  });
  assert.equal(r2.success, true);
  assert.equal(r2.idempotent, true);
  assert.equal(fs._peek("fleet_1").fleet_wallet_balance_ngn, 1840);
});

test("settleFleetLinkedDeliveryEarningOnce uses global rate for subscription merchant", async () => {
  const fs = makeFirestore({
    fleet_1: {
      payment_model: "subscription",
      commission_exempt: true,
      commission_rate: 0,
    },
  });

  const db = makeDb({
    "drivers/drv_fleet": {
      ownership_mode: "business_managed",
      business_id: "fleet_1",
    },
  });

  const r = await settleFleetLinkedDeliveryEarningOnce(db, {
    deliveryId: "del_sub",
    deliveryRow: {
      fare: 2000,
      payment_status: "paid_verified",
      payment_verified: true,
      payment_transaction_id: "flw_sub_1",
    },
    driverId: "drv_fleet",
    source: "test",
    fs,
  });
  assert.equal(r.success, true);
  assert.equal(r.amount_ngn, 1840);
});

test("settleFleetLinkedDeliveryEarningOnce skips individual drivers", async () => {
  const fs = makeFirestore();

  const db = makeDb({
    "drivers/drv_ind": { ownership_mode: "individual" },
  });

  const r = await settleFleetLinkedDeliveryEarningOnce(db, {
    deliveryId: "del_2",
    deliveryRow: { fare: 1000 },
    driverId: "drv_ind",
    source: "test",
    fs,
  });
  assert.equal(r.reason, "not_fleet_managed");
  assert.equal(fs._peek("fleet_1"), undefined);
});

test("settleFleetLinkedDeliveryEarningOnce ignores biker commission_exempt", async () => {
  const fs = makeFirestore();

  const db = makeDb({
    "drivers/drv_fleet": {
      ownership_mode: "business_managed",
      business_id: "fleet_1",
      commission_exempt: true,
    },
  });

  const r = await settleFleetLinkedDeliveryEarningOnce(db, {
    deliveryId: "del_3",
    deliveryRow: {
      fare: 2000,
      payment_status: "paid_verified",
      payment_verified: true,
      payment_transaction_id: "flw_settle_3",
    },
    driverId: "drv_fleet",
    source: "test",
    fs,
  });
  assert.equal(r.success, true);
  assert.equal(r.amount_ngn, 1840);
});

test("settleIndependentDeliveryDriverEarningOnce skips fleet-managed drivers", async () => {
  const db = makeDb({
    "drivers/drv_fleet": {
      ownership_mode: "business_managed",
      business_id: "fleet_1",
    },
  });

  const r = await settleIndependentDeliveryDriverEarningOnce(db, {
    deliveryId: "del_4",
    deliveryRow: {
      fare: 1000,
      payment_status: "paid_verified",
      payment_verified: true,
      payment_transaction_id: "flw_settle_4",
    },
    driverId: "drv_fleet",
    source: "test",
  });
  assert.equal(r.reason, "fleet_managed_skipped");
});

const assert = require("node:assert/strict");
const { test } = require("node:test");

function makePtDb(ptByPath) {
  const store = { ...ptByPath };
  return {
    ref(path) {
      const p = String(path);
      return {
        async get() {
          return {
            exists: () => Object.prototype.hasOwnProperty.call(store, p),
            val: () => store[p],
          };
        },
        async update(patch) {
          const cur = store[p] && typeof store[p] === "object" ? store[p] : {};
          store[p] = { ...cur, ...patch };
        },
        async remove() {
          delete store[p];
        },
        child() {
          return this;
        },
      };
    },
    _store: store,
  };
}

function makeRootUpdateDb(ptRow, { ledger = {} } = {}) {
  const flat = {};
  return {
    ref(path) {
      const p = String(path);
      if (!p || p === "/") {
        return {
          async update(updates) {
            Object.assign(flat, updates);
          },
        };
      }
      if (p.startsWith("payment_transactions/")) {
        return {
          async get() {
            return {
              exists: () => true,
              val: () => ptRow,
            };
          },
          async update(patch) {
            Object.assign(ptRow, patch);
          },
        };
      }
      if (p.startsWith("driver_wallet_ledger/")) {
        const rest = p.slice("driver_wallet_ledger/".length);
        return {
          transaction(fn) {
            const cur = ledger[rest];
            const next = fn(cur);
            if (next === undefined) {
              return { committed: false };
            }
            ledger[rest] = next;
            return { committed: true };
          },
        };
      }
      if (p.startsWith("payments/")) {
        return {
          async update(patch) {
            flat[`_payments_${p}`] = patch;
          },
        };
      }
      if (p.startsWith("wallets/")) {
        let walletData = null;
        return {
          async get() {
            return { exists: () => walletData != null, val: () => walletData };
          },
          async transaction(fn) {
            const next = fn(walletData);
            if (next === undefined) {
              return { committed: false };
            }
            walletData = next;
            return { committed: true, snapshot: { val: () => walletData } };
          },
        };
      }
      if (p.startsWith("drivers/")) {
        return {
          async get() {
            return { exists: () => true, val: () => ({}) };
          },
          async update() {},
        };
      }
      return {
        async get() {
          return { exists: () => false, val: () => null };
        },
        async update() {},
      };
    },
    flat,
    ledger,
  };
}

function makeMinimalFs() {
  return {
    collection() {
      return {
        doc() {
          return {
            async set() {},
            collection() {
              return {
                async add() {},
              };
            },
          };
        },
      };
    },
  };
}

test("getResolvedDriverSubscriptionPricesNgn uses ₦7000/₦25000 when app_config/pricing missing", async () => {
  const driverFlutterwave = require("../driver_flutterwave_payments");
  const db = {
    ref(p) {
      if (String(p) === "app_config/pricing") {
        return {
          async get() {
            return { exists: () => false, val: () => null };
          },
        };
      }
      return {
        async get() {
          return { exists: () => false, val: () => null };
        },
      };
    },
  };
  const r = await driverFlutterwave.getResolvedDriverSubscriptionPricesNgn(db);
  assert.equal(r.weekly_subscription_ngn, 7000);
  assert.equal(r.monthly_subscription_ngn, 25000);
  assert.equal(r.weekly_from_rtdb, false);
  assert.equal(r.monthly_from_rtdb, false);
});

test("finalizeDriverSubscriptionPaymentVerified rejects wrong purpose", async () => {
  const driverFlutterwave = require("../driver_flutterwave_payments");
  const db = makePtDb({
    "payment_transactions/tx1": { purpose: "other", driver_id: "d1", owner_uid: "d1", amount: 100 },
  });
  const fs = {};
  const r = await driverFlutterwave.finalizeDriverSubscriptionPaymentVerified(db, fs, {
    payTid: "9",
    txRef: "tx1",
    verifiedAmount: 100,
    currency: "NGN",
    webhookBody: {},
  });
  assert.equal(r.success, false);
  assert.equal(r.reason, "not_driver_subscription");
});

test("finalizeDriverSubscriptionPaymentVerified is idempotent when already verified", async () => {
  const driverFlutterwave = require("../driver_flutterwave_payments");
  const db = makePtDb({
    "payment_transactions/tx2": {
      purpose: "driver_subscription_payment",
      driver_id: "d1",
      owner_uid: "d1",
      amount: 200,
      verified: true,
    },
  });
  const fs = {};
  const r = await driverFlutterwave.finalizeDriverSubscriptionPaymentVerified(db, fs, {
    payTid: "1",
    txRef: "tx2",
    verifiedAmount: 200,
    currency: "NGN",
    webhookBody: {},
  });
  assert.equal(r.success, true);
  assert.equal(r.idempotent, true);
});

test("finalizeDriverWalletTopUpVerified rejects amount below expected", async () => {
  const driverFlutterwave = require("../driver_flutterwave_payments");
  const ptRow = {
    purpose: "driver_wallet_topup",
    driver_id: "d1",
    owner_uid: "d1",
    amount: 500,
    currency: "NGN",
    provider: "flutterwave",
  };
  const db = makeRootUpdateDb(ptRow);
  const fs = makeMinimalFs();
  const r = await driverFlutterwave.finalizeDriverWalletTopUpVerified(db, fs, {
    payTid: "88",
    txRef: "txw",
    verifiedAmount: 100,
    currency: "NGN",
    webhookBody: {},
  });
  assert.equal(r.success, false);
  assert.equal(r.reason, "amount_mismatch");
});

test("finalizeDriverWalletTopUpVerified idempotent when payment row already verified", async () => {
  const driverFlutterwave = require("../driver_flutterwave_payments");
  const ptRow = {
    purpose: "driver_wallet_topup",
    driver_id: "d1",
    owner_uid: "d1",
    amount: 400,
    verified: true,
    currency: "NGN",
  };
  const db = makeRootUpdateDb(ptRow);
  const fs = makeMinimalFs();
  const r = await driverFlutterwave.finalizeDriverWalletTopUpVerified(db, fs, {
    payTid: "77",
    txRef: "txw2",
    verifiedAmount: 400,
    currency: "NGN",
    webhookBody: {},
  });
  assert.equal(r.success, true);
  assert.equal(r.idempotent, true);
});

test("finalizeDriverWalletTopUpVerified rejects non-NGN currency", async () => {
  const driverFlutterwave = require("../driver_flutterwave_payments");
  const ptRow = {
    purpose: "driver_wallet_topup",
    driver_id: "d1",
    owner_uid: "d1",
    amount: 100,
    currency: "NGN",
  };
  const db = makeRootUpdateDb(ptRow);
  const fs = makeMinimalFs();
  const r = await driverFlutterwave.finalizeDriverWalletTopUpVerified(db, fs, {
    payTid: "66",
    txRef: "txw3",
    verifiedAmount: 100,
    currency: "USD",
    webhookBody: {},
  });
  assert.equal(r.success, false);
  assert.equal(r.reason, "currency_mismatch");
});

test("finalizeDriverSubscriptionPaymentVerified rejects driver_wallet provider rows", async () => {
  const driverFlutterwave = require("../driver_flutterwave_payments");
  const db = makePtDb({
    "payment_transactions/txwsub": {
      purpose: "driver_subscription_payment",
      provider: "driver_wallet",
      driver_id: "d1",
      owner_uid: "d1",
      amount: 100,
      verified: false,
      currency: "NGN",
    },
  });
  const fs = {};
  const r = await driverFlutterwave.finalizeDriverSubscriptionPaymentVerified(db, fs, {
    payTid: "9",
    txRef: "txwsub",
    verifiedAmount: 100,
    currency: "NGN",
    webhookBody: {},
  });
  assert.equal(r.success, false);
  assert.equal(r.reason, "subscription_settled_via_wallet");
});

function makeWalletSettleDb() {
  const ptRow = {
    purpose: "driver_subscription_payment",
    provider: "driver_wallet",
    driver_id: "d1",
    owner_uid: "d1",
    amount: 200,
    subscription_plan_type: "monthly",
    verified: false,
    currency: "NGN",
  };
  const ledger = {};
  const flat = {};
  const walletTx = {
    transactionId: "sub_wallet_txwallet1",
    type: "driver_wallet_subscription_debit",
    amount: 200,
    direction: "debit",
  };
  return {
    ref(path) {
      const p = String(path);
      if (!p || p === "/") {
        return {
          async update(updates) {
            Object.assign(flat, updates);
          },
        };
      }
      if (p.startsWith("payment_transactions/")) {
        return {
          async get() {
            return { exists: () => true, val: () => ptRow };
          },
          async update(patch) {
            Object.assign(ptRow, patch);
          },
          async set(v) {
            Object.assign(ptRow, v);
          },
        };
      }
      if (p.startsWith("driver_wallet_ledger/")) {
        const rest = p.slice("driver_wallet_ledger/".length);
        return {
          transaction(fn) {
            const cur = ledger[rest];
            const next = fn(cur);
            if (next === undefined) {
              return { committed: false };
            }
            ledger[rest] = next;
            return { committed: true };
          },
        };
      }
      if (p.startsWith("payments/")) {
        return {
          async update(patch) {
            flat[`_payments_${p}`] = patch;
          },
        };
      }
      if (p === "wallets/d1/transactions/sub_wallet_txwallet1") {
        return {
          async get() {
            return { exists: () => true, val: () => walletTx };
          },
        };
      }
      if (p.startsWith("drivers/d1/pending_wallet_subscription_tx_ref")) {
        return {
          async remove() {
            flat.pending_cleared = true;
          },
          async set() {},
          async get() {
            return { exists: () => false, val: () => null };
          },
        };
      }
      if (p.startsWith("drivers/")) {
        return {
          async get() {
            return { exists: () => true, val: () => ({}) };
          },
          async update() {},
          async remove() {},
        };
      }
      return {
        async get() {
          return { exists: () => false, val: () => null };
        },
        async update() {},
      };
    },
    flat,
    ledger,
    ptRow,
  };
}

test("settleDriverSubscriptionFromWalletDebit activates once when wallet debit exists", async () => {
  const driverFlutterwave = require("../driver_flutterwave_payments");
  const db = makeWalletSettleDb();
  const fs = makeMinimalFs();
  const r1 = await driverFlutterwave.settleDriverSubscriptionFromWalletDebit(db, fs, {
    driverId: "d1",
    ownerUid: "d1",
    planType: "monthly",
    amount: 200,
    tx_ref: "txwallet1",
  });
  assert.equal(r1.success, true);
  const r2 = await driverFlutterwave.settleDriverSubscriptionFromWalletDebit(db, fs, {
    driverId: "d1",
    ownerUid: "d1",
    planType: "monthly",
    amount: 200,
    tx_ref: "txwallet1",
  });
  assert.equal(r2.success, true);
  assert.equal(r2.idempotent, true);
});

test("settleDriverSubscriptionFromWalletDebit rejects missing wallet debit", async () => {
  const driverFlutterwave = require("../driver_flutterwave_payments");
  const ptRow = {
    purpose: "driver_subscription_payment",
    provider: "driver_wallet",
    driver_id: "d1",
    owner_uid: "d1",
    amount: 50,
    verified: false,
    currency: "NGN",
  };
  const db = makeRootUpdateDb(ptRow, { ledger: {} });
  const fs = makeMinimalFs();
  const r = await driverFlutterwave.settleDriverSubscriptionFromWalletDebit(db, fs, {
    driverId: "d1",
    ownerUid: "d1",
    planType: "monthly",
    amount: 50,
    tx_ref: "txmissing",
  });
  assert.equal(r.success, false);
  assert.equal(r.reason, "wallet_debit_missing");
});

test("finalizeDriverWalletTopUpVerified second call is idempotent after first success", async () => {
  const driverFlutterwave = require("../driver_flutterwave_payments");
  const ptRow = {
    purpose: "driver_wallet_topup",
    driver_id: "d1",
    owner_uid: "d1",
    amount: 150,
    currency: "NGN",
    provider: "flutterwave",
  };
  const db = makeRootUpdateDb(ptRow, { ledger: {} });
  const fs = makeMinimalFs();
  const r1 = await driverFlutterwave.finalizeDriverWalletTopUpVerified(db, fs, {
    payTid: "42",
    txRef: "txdup",
    verifiedAmount: 150,
    currency: "NGN",
    webhookBody: {},
  });
  assert.equal(r1.success, true);
  const r2 = await driverFlutterwave.finalizeDriverWalletTopUpVerified(db, fs, {
    payTid: "42",
    txRef: "txdup",
    verifiedAmount: 150,
    currency: "NGN",
    webhookBody: {},
  });
  assert.equal(r2.success, true);
  assert.equal(r2.idempotent, true);
});

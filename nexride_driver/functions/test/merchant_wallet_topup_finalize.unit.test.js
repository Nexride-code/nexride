const assert = require("node:assert/strict");
const { test } = require("node:test");
const { finalizeMerchantFlutterwaveTopUpVerified } = require("../merchant/merchant_wallet");

function makeRtdb(ptByRef) {
  const store = { ...ptByRef };
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
      };
    },
  };
}

function makeFirestore() {
  const merchants = { m1: { wallet_balance_ngn: 0 } };
  const ledgerExists = new Set();
  return {
    collection(name) {
      assert.equal(name, "merchants");
      return {
        doc(mid) {
          const merchantRef = { path: `merchants/${mid}` };
          return {
            ...merchantRef,
            collection(sub) {
              assert.equal(sub, "wallet_ledger");
              return {
                doc(ledgerId) {
                  return { path: `merchants/${mid}/wallet_ledger/${ledgerId}` };
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
          if (path.includes("/wallet_ledger/")) {
            return { exists: ledgerExists.has(path), data: () => ({}) };
          }
          const mid = path.split("/")[1];
          const m = merchants[mid];
          return { exists: !!m, data: () => m || {} };
        },
        set(ref, data) {
          const { path } = ref;
          if (path.includes("/wallet_ledger/")) {
            ledgerExists.add(path);
            return;
          }
          const mid = path.split("/")[1];
          merchants[mid] = { ...merchants[mid], ...data };
        },
      };
      await fn(tx);
    },
    _peekBalance(mid) {
      return merchants[mid]?.wallet_balance_ngn;
    },
    _creditCount(mid) {
      return [...ledgerExists].filter((p) =>
        p.startsWith(`merchants/${mid}/wallet_ledger/`),
      ).length;
    },
  };
}

test("finalizeMerchantFlutterwaveTopUpVerified is idempotent when payment_transactions already verified", async () => {
  const db = makeRtdb({
    "payment_transactions/tx_already": {
      purpose: "merchant_wallet_topup",
      merchant_id: "m1",
      amount: 100,
      verified: true,
    },
  });
  const fs = makeFirestore();
  const r = await finalizeMerchantFlutterwaveTopUpVerified(db, fs, {
    payTid: "999",
    txRef: "tx_already",
    verifiedAmount: 100,
    currency: "NGN",
    webhookBody: {},
  });
  assert.equal(r.success, true);
  assert.equal(r.idempotent, true);
  assert.equal(fs._creditCount("m1"), 0);
});

test("finalizeMerchantFlutterwaveTopUpVerified rejects merchant paid amount below recorded expectation", async () => {
  const db = makeRtdb({
    "payment_transactions/tx_low": {
      purpose: "merchant_wallet_topup",
      merchant_id: "m1",
      amount: 500,
    },
  });
  const fs = makeFirestore();
  const r = await finalizeMerchantFlutterwaveTopUpVerified(db, fs, {
    payTid: "777",
    txRef: "tx_low",
    verifiedAmount: 100,
    currency: "NGN",
    webhookBody: {},
  });
  assert.equal(r.success, false);
  assert.equal(r.reason, "amount_mismatch");
  assert.equal(fs._creditCount("m1"), 0);
});

test("finalizeMerchantFlutterwaveTopUpVerified credits wallet once on success", async () => {
  const db = makeRtdb({
    "payment_transactions/tx_ok": {
      purpose: "merchant_wallet_topup",
      merchant_id: "m1",
      amount: 250,
    },
  });
  const fs = makeFirestore();
  const r1 = await finalizeMerchantFlutterwaveTopUpVerified(db, fs, {
    payTid: "4411",
    txRef: "tx_ok",
    verifiedAmount: 250,
    currency: "NGN",
    webhookBody: {},
  });
  assert.equal(r1.success, true);
  assert.equal(fs._peekBalance("m1"), 250);
  assert.equal(fs._creditCount("m1"), 1);

  const r2 = await finalizeMerchantFlutterwaveTopUpVerified(db, fs, {
    payTid: "4411",
    txRef: "tx_ok",
    verifiedAmount: 250,
    currency: "NGN",
    webhookBody: {},
  });
  assert.equal(r2.success, true);
  assert.equal(fs._peekBalance("m1"), 250);
});

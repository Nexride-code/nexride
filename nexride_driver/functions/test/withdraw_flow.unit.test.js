const assert = require("node:assert/strict");
const { test } = require("node:test");
const withdrawFlow = require("../withdraw_flow");

test("computeAvailableWithdrawalBalanceNgn subtracts reserved withdrawals", () => {
  assert.equal(withdrawFlow.computeAvailableWithdrawalBalanceNgn(10000, 7000), 3000);
  assert.equal(withdrawFlow.computeAvailableWithdrawalBalanceNgn(5000, 6000), 0);
});

test("withdrawalStatusReservesBalance includes pending and processing only", () => {
  assert.equal(withdrawFlow.withdrawalStatusReservesBalance("pending"), true);
  assert.equal(withdrawFlow.withdrawalStatusReservesBalance("processing"), true);
  assert.equal(withdrawFlow.withdrawalStatusReservesBalance("reviewing"), true);
  assert.equal(withdrawFlow.withdrawalStatusReservesBalance("paid"), false);
  assert.equal(withdrawFlow.withdrawalStatusReservesBalance("rejected"), false);
});

test("requestWithdrawal rejects when amount exceeds available balance", async () => {
  const store = {
    drivers: {
      drv1: {
        withdrawal_destination: {
          bank_name: "GTBank",
          account_number: "0123456789",
          account_holder_name: "Test Driver",
        },
      },
    },
    wallets: { drv1: { balance: 10000, transactions: {} } },
    withdraw_requests: {
      w1: {
        driver_id: "drv1",
        entity_type: "driver",
        amount: 7000,
        status: "pending",
      },
    },
  };
  const db = {
    ref(path) {
      const parts = String(path).split("/").filter(Boolean);
      return {
        async get() {
          let cur = store;
          for (const p of parts) {
            cur = cur?.[p];
          }
          return { exists: () => cur != null, val: () => cur };
        },
        push() {
          return { key: "w_new" };
        },
        async set() {},
        async update() {},
      };
    },
  };

  const r = await withdrawFlow.requestWithdrawal(
    { amount: 4000 },
    { auth: { uid: "drv1" } },
    db,
  );
  assert.equal(r.success, false);
  assert.equal(r.reason, "insufficient_available_balance");
  assert.equal(r.available_balance, 3000);
});

test("requestWithdrawal allows when amount within available balance", async () => {
  const store = {
    drivers: {
      drv1: {
        withdrawal_destination: {
          bank_name: "GTBank",
          account_number: "0123456789",
          account_holder_name: "Test Driver",
        },
      },
    },
    wallets: { drv1: { balance: 10000, transactions: {} } },
    withdraw_requests: {
      w1: {
        driver_id: "drv1",
        entity_type: "driver",
        amount: 7000,
        status: "pending",
      },
    },
  };
  let wrote = false;
  const db = {
    ref(path) {
      const parts = String(path).split("/").filter(Boolean);
      return {
        async get() {
          let cur = store;
          for (const p of parts) {
            cur = cur?.[p];
          }
          return { exists: () => cur != null, val: () => cur };
        },
        push() {
          return { key: "w_new" };
        },
        async set() {
          wrote = true;
        },
        async update() {},
      };
    },
  };

  const r = await withdrawFlow.requestWithdrawal(
    { amount: 3000 },
    { auth: { uid: "drv1" } },
    db,
  );
  assert.equal(r.success, true);
  assert.equal(wrote, true);
  assert.equal(store.wallets.drv1.balance, 10000);
});

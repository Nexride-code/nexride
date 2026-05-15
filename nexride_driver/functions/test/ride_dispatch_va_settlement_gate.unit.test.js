const assert = require("node:assert/strict");
const { test, after } = require("node:test");

const {
  buildRideDispatchWebhookFwStrictExpect,
  nextFlutterwavePayTidSettlementPayload,
  rideDispatchFlutterwaveVaPtAlreadySettled,
} = require("../payment_flow");

const originalFetch = global.fetch;

after(() => {
  global.fetch = originalFetch;
  delete process.env.FLUTTERWAVE_SECRET_KEY;
});

function makeFirestoreIntentMock(docData, opts = {}) {
  const audits = [];
  return {
    collection() {
      return {
        doc() {
          return {
            async get() {
              if (opts.noDoc) {
                return { exists: false, data: () => null };
              }
              return { exists: !!docData, data: () => docData };
            },
            async set() {},
            collection() {
              return {
                async add(row) {
                  audits.push(row);
                },
              };
            },
          };
        },
      };
    },
    audits,
  };
}

function mockVerifyByIdResponse({ tx_ref, currency, amount }) {
  return {
    ok: true,
    status: 200,
    json: async () => ({
      status: "success",
      data: {
        status: "successful",
        id: "990011",
        tx_ref,
        currency,
        amount,
      },
    }),
  };
}

const EXPECT_TX = "nexride_va_ride_gate_1";
const RIDE_TOTAL = 5000;

const sampleRide = {
  rider_id: "rider_a",
  customer_transaction_reference: EXPECT_TX,
  total_ngn: RIDE_TOTAL,
  currency: "NGN",
};

const samplePtVa = {
  provider: "flutterwave_va",
  ride_id: "ride_1",
  rider_id: "rider_a",
  amount: RIDE_TOTAL,
  currency: "NGN",
};

test("buildRideDispatchWebhookFwStrictExpect prefers total_ngn and entity tx ref for ride VA", () => {
  const g = buildRideDispatchWebhookFwStrictExpect({
    ride: sampleRide,
    pt: samplePtVa,
    webhookTxRef: "unused_when_ride_has_customer_transaction_reference",
    hookCurrency: "NGN",
    hookAmount: 1,
  });
  assert.equal(g.expectedTxRef, EXPECT_TX);
  assert.equal(g.expectedCurrency, "NGN");
  assert.equal(g.minAmount, RIDE_TOTAL);
});

test("buildRideDispatchWebhookFwStrictExpect uses webhook tx_ref when entity reference empty", () => {
  const g = buildRideDispatchWebhookFwStrictExpect({
    ride: { ...sampleRide, customer_transaction_reference: "", payment_reference: "" },
    deliveryRecord: null,
    pt: samplePtVa,
    webhookTxRef: "fallback_ref",
    hookCurrency: "ngn",
    hookAmount: 0,
  });
  assert.equal(g.expectedTxRef, "fallback_ref");
});

test("ride/dispatch VA: strict verify rejects tx_ref mismatch vs entity expectation", async () => {
  process.env.FLUTTERWAVE_SECRET_KEY = "sk_test";
  global.fetch = async () =>
    mockVerifyByIdResponse({
      tx_ref: "wrong_ref",
      currency: "NGN",
      amount: RIDE_TOTAL,
    });
  delete require.cache[require.resolve("../flutterwave_api")];
  const { verifyFlutterwavePaymentStrict } = require("../flutterwave_api");
  const fw = buildRideDispatchWebhookFwStrictExpect({
    ride: sampleRide,
    pt: samplePtVa,
    webhookTxRef: EXPECT_TX,
    hookCurrency: "NGN",
    hookAmount: RIDE_TOTAL,
  });
  const v = await verifyFlutterwavePaymentStrict({
    transactionId: "990011",
    txRef: EXPECT_TX,
    expect: {
      expectedTxRef: fw.expectedTxRef,
      expectedCurrency: fw.expectedCurrency,
      minAmount: fw.minAmount,
    },
  });
  assert.equal(v.ok, false);
  assert.equal(v.reason, "tx_ref_mismatch");
});

test("ride/dispatch VA: strict verify rejects amount below min from total_ngn", async () => {
  process.env.FLUTTERWAVE_SECRET_KEY = "sk_test";
  global.fetch = async () =>
    mockVerifyByIdResponse({
      tx_ref: EXPECT_TX,
      currency: "NGN",
      amount: 100,
    });
  delete require.cache[require.resolve("../flutterwave_api")];
  const { verifyFlutterwavePaymentStrict } = require("../flutterwave_api");
  const fw = buildRideDispatchWebhookFwStrictExpect({
    ride: sampleRide,
    pt: samplePtVa,
    webhookTxRef: EXPECT_TX,
    hookCurrency: "NGN",
    hookAmount: RIDE_TOTAL,
  });
  const v = await verifyFlutterwavePaymentStrict({
    transactionId: "990011",
    txRef: EXPECT_TX,
    expect: {
      expectedTxRef: fw.expectedTxRef,
      expectedCurrency: fw.expectedCurrency,
      minAmount: fw.minAmount,
    },
  });
  assert.equal(v.ok, false);
  assert.equal(v.reason, "amount_below_expected");
});

test("ride/dispatch VA: strict verify rejects currency mismatch", async () => {
  process.env.FLUTTERWAVE_SECRET_KEY = "sk_test";
  global.fetch = async () =>
    mockVerifyByIdResponse({
      tx_ref: EXPECT_TX,
      currency: "USD",
      amount: RIDE_TOTAL,
    });
  delete require.cache[require.resolve("../flutterwave_api")];
  const { verifyFlutterwavePaymentStrict } = require("../flutterwave_api");
  const fw = buildRideDispatchWebhookFwStrictExpect({
    ride: sampleRide,
    pt: samplePtVa,
    webhookTxRef: EXPECT_TX,
    hookCurrency: "NGN",
    hookAmount: RIDE_TOTAL,
  });
  const v = await verifyFlutterwavePaymentStrict({
    transactionId: "990011",
    txRef: EXPECT_TX,
    expect: {
      expectedTxRef: fw.expectedTxRef,
      expectedCurrency: fw.expectedCurrency,
      minAmount: fw.minAmount,
    },
  });
  assert.equal(v.ok, false);
  assert.equal(v.reason, "currency_mismatch");
});

test("ride/dispatch VA: expired Firestore intent blocks auto-settlement (pending_review)", async () => {
  const { evaluateVaIntentExpiryForSettlement } = require("../bank_transfer_va");
  const fs = makeFirestoreIntentMock({
    expires_at_ms: Date.now() - 30_000,
    legacy_manual_bank: false,
  });
  const r = await evaluateVaIntentExpiryForSettlement({
    fs,
    txRef: EXPECT_TX,
    webhookLabel: "charge.completed",
  });
  assert.equal(r.mode, "pending_review");
  assert.equal(r.reason, "late_transfer_after_expiry");
});

test("ride/dispatch VA: golden path — strict ok, intent not expired, payTid claim allowed once", async () => {
  process.env.FLUTTERWAVE_SECRET_KEY = "sk_test";
  global.fetch = async () =>
    mockVerifyByIdResponse({
      tx_ref: EXPECT_TX,
      currency: "NGN",
      amount: RIDE_TOTAL,
    });
  delete require.cache[require.resolve("../flutterwave_api")];
  const { verifyFlutterwavePaymentStrict } = require("../flutterwave_api");
  const { evaluateVaIntentExpiryForSettlement } = require("../bank_transfer_va");

  const fw = buildRideDispatchWebhookFwStrictExpect({
    ride: sampleRide,
    pt: samplePtVa,
    webhookTxRef: EXPECT_TX,
    hookCurrency: "NGN",
    hookAmount: RIDE_TOTAL,
  });
  const v = await verifyFlutterwavePaymentStrict({
    transactionId: "990011",
    txRef: EXPECT_TX,
    expect: {
      expectedTxRef: fw.expectedTxRef,
      expectedCurrency: fw.expectedCurrency,
      minAmount: fw.minAmount,
    },
  });
  assert.equal(v.ok, true);

  const fsFuture = makeFirestoreIntentMock({
    expires_at_ms: Date.now() + 3_600_000,
    legacy_manual_bank: false,
  });
  const late = await evaluateVaIntentExpiryForSettlement({
    fs: fsFuture,
    txRef: EXPECT_TX,
    webhookLabel: "charge.completed",
  });
  assert.equal(late.mode, "ok");

  const payload = { applied_at: Date.now(), ride_id: "ride_1" };
  assert.deepEqual(nextFlutterwavePayTidSettlementPayload(null, payload), payload);
  assert.equal(nextFlutterwavePayTidSettlementPayload(undefined, payload), payload);
  assert.equal(nextFlutterwavePayTidSettlementPayload({ x: 1 }, payload), undefined);
});

test("rideDispatchFlutterwaveVaPtAlreadySettled matches verified flutterwave_va payment_transactions", () => {
  assert.equal(
    rideDispatchFlutterwaveVaPtAlreadySettled({
      provider: "flutterwave_va",
      verified: true,
    }),
    true,
  );
  assert.equal(
    rideDispatchFlutterwaveVaPtAlreadySettled({
      provider: "flutterwave_va",
      verified: false,
    }),
    false,
  );
  assert.equal(rideDispatchFlutterwaveVaPtAlreadySettled({ provider: "card", verified: true }), false);
});

test("dispatch record: minAmount from delivery total_ngn", () => {
  const g = buildRideDispatchWebhookFwStrictExpect({
    ride: null,
    deliveryRecord: {
      customer_transaction_reference: "nexride_del_x",
      total_ngn: 3200,
      fare: 100,
      currency: "NGN",
    },
    pt: { provider: "flutterwave_va", delivery_id: "d1", currency: "NGN" },
    webhookTxRef: "nexride_del_x",
    hookCurrency: "NGN",
    hookAmount: 0,
  });
  assert.equal(g.minAmount, 3200);
  assert.equal(g.expectedTxRef, "nexride_del_x");
});

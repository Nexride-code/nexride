const assert = require("node:assert/strict");
const { test, after } = require("node:test");

const originalFetch = global.fetch;

after(() => {
  global.fetch = originalFetch;
  delete process.env.FLUTTERWAVE_SECRET_KEY;
});

function mockVerifyPayload({ tx_ref = "tx_a", currency = "NGN", amount = 1000 } = {}) {
  return {
    ok: true,
    status: "success",
    json: async () => ({
      status: "success",
      data: {
        status: "successful",
        id: "887766",
        tx_ref,
        currency,
        amount,
      },
    }),
  };
}

test("verifyFlutterwavePaymentStrict (by numeric id path) rejects amount below minAmount", async () => {
  process.env.FLUTTERWAVE_SECRET_KEY = "test_sk";
  global.fetch = async (url, opts) => {
    assert.match(String(url), /\/transactions\/554433\/verify$/);
    return mockVerifyPayload({ amount: 500 });
  };
  delete require.cache[require.resolve("../flutterwave_api")];
  const { verifyFlutterwavePaymentStrict } = require("../flutterwave_api");
  const r = await verifyFlutterwavePaymentStrict({
    transactionId: "554433",
    txRef: "",
    expect: { expectedTxRef: "tx_a", expectedCurrency: "NGN", minAmount: 1000 },
  });
  assert.equal(r.ok, false);
  assert.equal(r.reason, "amount_below_expected");
});

test("verifyFlutterwavePaymentStrict (by numeric id path) rejects tx_ref mismatch", async () => {
  process.env.FLUTTERWAVE_SECRET_KEY = "test_sk";
  global.fetch = async () => mockVerifyPayload({ tx_ref: "wrong" });
  delete require.cache[require.resolve("../flutterwave_api")];
  const { verifyFlutterwavePaymentStrict } = require("../flutterwave_api");
  const r = await verifyFlutterwavePaymentStrict({
    transactionId: "554433",
    txRef: "",
    expect: { expectedTxRef: "expected_only", expectedCurrency: "NGN" },
  });
  assert.equal(r.ok, false);
  assert.equal(r.reason, "tx_ref_mismatch");
});

test("verifyFlutterwavePaymentStrict (by numeric id path) rejects currency mismatch", async () => {
  process.env.FLUTTERWAVE_SECRET_KEY = "test_sk";
  global.fetch = async () => mockVerifyPayload({ currency: "USD" });
  delete require.cache[require.resolve("../flutterwave_api")];
  const { verifyFlutterwavePaymentStrict } = require("../flutterwave_api");
  const r = await verifyFlutterwavePaymentStrict({
    transactionId: "554433",
    txRef: "",
    expect: { expectedTxRef: "tx_a", expectedCurrency: "NGN" },
  });
  assert.equal(r.ok, false);
  assert.equal(r.reason, "currency_mismatch");
});

test("verifyFlutterwavePaymentStrict (by numeric id path) accepts matching strict fields", async () => {
  process.env.FLUTTERWAVE_SECRET_KEY = "test_sk";
  global.fetch = async () => mockVerifyPayload({ tx_ref: "match_ref", amount: 2000 });
  delete require.cache[require.resolve("../flutterwave_api")];
  const { verifyFlutterwavePaymentStrict } = require("../flutterwave_api");
  const r = await verifyFlutterwavePaymentStrict({
    transactionId: "554433",
    txRef: "",
    expect: { expectedTxRef: "match_ref", expectedCurrency: "NGN", minAmount: 2000 },
  });
  assert.equal(r.ok, true);
  assert.equal(r.amount, 2000);
  assert.equal(r.tx_ref, "match_ref");
});

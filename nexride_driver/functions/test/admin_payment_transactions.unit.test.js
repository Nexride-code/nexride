const assert = require("node:assert/strict");
const { test } = require("node:test");
const adminPaymentTx = require("../admin_payment_transactions");

test("projectSafePaymentTransaction strips card fields and returns refs only", () => {
  const row = {
    tx_ref: "nexride_tx_1",
    ride_id: "ride1",
    rider_id: "rider1",
    amount: 1500,
    currency: "NGN",
    card_authorization: true,
    status: "card_authorized",
    flw_ref: "FLW-REF",
    authorization_ref: "AUTH-REF",
    transaction_id: "12345",
    token: "secret-token",
    card: { number: "4111" },
    pan: "4111111111111111",
    cvv: "123",
    created_at: 1000,
    updated_at: 2000,
  };
  const safe = adminPaymentTx.projectSafePaymentTransaction("nexride_tx_1", row);
  assert.equal(safe.tx_ref, "nexride_tx_1");
  assert.equal(safe.payment_method, "card");
  assert.equal(safe.payment_status, "authorized");
  assert.equal(safe.flw_ref, "FLW-REF");
  assert.equal(safe.authorization_ref, "AUTH-REF");
  assert.equal(safe.transaction_id, "12345");
  assert.equal(safe.token, undefined);
  assert.equal(safe.card, undefined);
});

test("paymentTransactionRowMatches method and status filters", () => {
  const row = {
    card_authorization: true,
    status: "card_captured",
    ride_id: "rideA",
    rider_id: "riderA",
    amount: 500,
    created_at: 5000,
    updated_at: 6000,
  };
  assert.equal(
    adminPaymentTx.paymentTransactionRowMatches("tx1", row, {
      method: "card",
      status: "captured",
      rideId: "rideA",
      riderId: "riderA",
      driverId: "",
      createdFrom: 0,
      createdTo: 0,
      search: "",
    }),
    true,
  );
  assert.equal(
    adminPaymentTx.paymentTransactionRowMatches("tx1", row, {
      method: "bank_transfer",
      status: "all",
      rideId: "",
      riderId: "",
      driverId: "",
      createdFrom: 0,
      createdTo: 0,
      search: "",
    }),
    false,
  );
});

test("isDeniedFieldKey blocks sensitive card keys", () => {
  assert.equal(adminPaymentTx.isDeniedFieldKey("cvv"), true);
  assert.equal(adminPaymentTx.isDeniedFieldKey("flw_ref"), false);
});

test("driver_wallet_topup purpose maps to wallet_topup method and flow", () => {
  const row = {
    purpose: "driver_wallet_topup",
    flow: "driver_wallet_topup",
    provider: "flutterwave",
    status: "verified",
    amount: 5000,
    token: "secret",
    card: { pan: "4111" },
  };
  const safe = adminPaymentTx.projectSafePaymentTransaction("topup_tx", row);
  assert.equal(safe.purpose, "driver_wallet_topup");
  assert.equal(safe.flow, "wallet_topup");
  assert.equal(safe.payment_method, "wallet_topup");
  assert.equal(safe.token, undefined);
  assert.equal(safe.card, undefined);
});

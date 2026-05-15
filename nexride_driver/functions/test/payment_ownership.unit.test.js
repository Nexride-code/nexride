const test = require("node:test");
const assert = require("node:assert/strict");
const {
  assertPaymentOwnership,
  inferAppContextFromPaymentRow,
} = require("../payment_ownership");

test("inferAppContextFromPaymentRow detects merchant top-up", () => {
  assert.equal(
    inferAppContextFromPaymentRow({ purpose: "merchant_wallet_topup", merchant_id: "m1" }),
    "merchant",
  );
});

test("assertPaymentOwnership rejects uid mismatch", () => {
  const r = assertPaymentOwnership(
    { owner_uid: "u1", app_context: "merchant", merchant_id: "m1" },
    { callerUid: "u2", expectedAppContext: "merchant", expectedMerchantId: "m1" },
  );
  assert.equal(r.ok, false);
  assert.equal(r.reason, "payment_owner_mismatch");
});

test("assertPaymentOwnership rejects context mismatch", () => {
  const r = assertPaymentOwnership(
    { owner_uid: "u1", app_context: "rider", rider_id: "u1" },
    { callerUid: "u1", expectedAppContext: "merchant" },
  );
  assert.equal(r.ok, false);
  assert.equal(r.reason, "payment_context_mismatch");
});

test("assertPaymentOwnership accepts matching merchant row", () => {
  const r = assertPaymentOwnership(
    { owner_uid: "u1", app_context: "merchant", merchant_id: "m1" },
    { callerUid: "u1", expectedAppContext: "merchant", expectedMerchantId: "m1" },
  );
  assert.equal(r.ok, true);
});
